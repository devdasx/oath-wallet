import Foundation
import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

/// Public testnet responses captured separately from signing/vault code. These
/// tests exercise the same decoders, commits and receipt projection as the app.
private func publicReceipts(_ chain: String) throws -> [SolanaJSON] {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("OathAnkr/Tests/OathAnkrTests/Fixtures/Receipts/\(chain)-testnet.json")
    return try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self, from: Data(contentsOf: file)).array)
}

extension AptosLedgerTests {
    func testUpgradeReplenishesLegacyReceiptParticipantsOnceWithoutErasingHistory() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-upgrade-" + UUID().uuidString).appendingPathComponent("wallet.sqlite")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var configuration = Configuration()
        configuration.prepareDatabase { sql in
            sql.add(function: HistorySearch.function)
            sql.add(function: HistoryFilter.amountFunction)
            sql.add(function: HistorySafety.metadataFunction)
        }
        let old = try DatabaseQueue(path: file.path, configuration: configuration)
        try Schema.migrator.migrate(old, upTo: "v61_notification_registration")
        let cached = Data("legacy public receipt".utf8)
        try await old.write { sql in
            try NetworkRecord(id: "aptos", name: "Aptos", family: "aptos", symbol: "APT", decimals: 8, derivationPath: "", logo: "", sortOrder: 0).insert(sql)
            // Populate the historical schema using its columns, not today's
            // WalletRecord (which includes fields introduced after v61).
            try sql.execute(sql: "INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES('w','Public fixture','watchOnly','none',1,0)")
            for id in ["cached", "empty"] {
                try AccountRecord(id: id, walletID: "w", networkID: "aptos", address: AptosIdentity.address(id == "cached" ? "0x1" : "0x2"), derivationPath: "").insert(sql)
                for lane in ["recent", "backfill"] {
                    try sql.execute(sql: "INSERT INTO aptosHistoryCursors(accountID,stream,lane,beforeVersion,stopVersion,headVersion,complete) VALUES(?,'account',?,50,90,100,1)", arguments: [id, lane])
                }
            }
            try sql.execute(sql: "INSERT INTO aptosTransactions(accountID,hash,version,detail) VALUES('cached','public-hash',100,?)", arguments: [cached])
        }
        try old.close()
        let db = try await OathDatabase.open(at: file)
        let rows = try await db.pool.read { try AptosHistoryCursor.fetchAll($0) }
        for row in rows where row.accountID == "cached" {
            XCTAssertFalse(row.complete); XCTAssertNil(row.beforeVersion); XCTAssertNil(row.stopVersion); XCTAssertNil(row.headVersion)
        }
        XCTAssertTrue(rows.filter { $0.accountID == "empty" }.allSatisfy { $0.complete && $0.headVersion == 100 })
        let preserved = try await db.pool.read { try Data.fetchOne($0, sql: "SELECT detail FROM aptosTransactions WHERE accountID='cached'") }
        XCTAssertEqual(preserved, cached)
        // Simulate a committed backfill page, then reopen. The migration must
        // not reset progress on every launch and refetch the same page forever.
        try await db.pool.write { try $0.execute(sql: "UPDATE aptosHistoryCursors SET beforeVersion=25,headVersion=100 WHERE accountID='cached'") }
        let reopened = try await OathDatabase.open(at: file)
        let resumed = try await reopened.pool.read { try AptosHistoryCursor.fetchAll($0, sql: "SELECT * FROM aptosHistoryCursors WHERE accountID='cached'") }
        XCTAssertTrue(resumed.allSatisfy { $0.beforeVersion == 25 && $0.headVersion == 100 })
    }
}

extension ActivityDetailsTests {
    func testLiveMonadReceiptPartiesThroughProductionHistory() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OATH_ACTIVITY_LIVE"] == "1", let config = env["OATH_ANKR_CONFIG"] else { throw XCTSkip("Opt-in public read-only history") }
        let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: config)), format: nil) as! [String: String]
        let ankr = try XCTUnwrap(values["AnkrAPIKey"]), alchemy = try XCTUnwrap(values["AlchemyAPIKey"])
        let sampleFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OathAnkr/Tests/OathAnkrTests/Fixtures/Receipts/monad-mainnet-public-sample.json")
        let sample = try JSONDecoder().decode(SolanaJSON.self, from: Data(contentsOf: sampleFile))
        let owner = try XCTUnwrap(sample["owner"].string)
        let client = try IndexedEVMClient(chain: .monad, apiKey: ankr, alchemyAPIKey: alchemy)
        let (db, file) = try await fixture("monad")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try await db.pool.write { try $0.execute(sql: "UPDATE accounts SET address=? WHERE id='a'", arguments: [owner]) }
        let ticket = try await db.beginIndexedEVMSync(accountID: "a"), work = try await db.indexedEVMHistoryWork(ticket)
        let cursor = try XCTUnwrap(work.first { $0.stream == "transactions" && $0.lane == "recent" })
        let page = try await client.history(owner: owner, stream: .transactions, from: cursor.startTime, through: cursor.endTime)
        XCTAssertFalse(page.events.isEmpty)
        try await db.commitIndexedEVMPage(page, cursor: cursor, ticket: ticket)
        let reopened = try await OathDatabase.open(at: file)
        for event in page.events {
            let details = try await reopened.transactionDetails(accountID: "a", transactionID: "monad:" + event.hash)
            XCTAssertTrue(try XCTUnwrap(details).fromAddresses.contains(event.from))
            XCTAssertTrue(details?.toAddresses.contains(event.to) == true)
        }
        print("LIVE_MONAD_RECEIPTS \(page.events.count) verified with production index, RPC, database and offline reopen")
    }

    /// Production history is mainnet-only. These public testnet RPC captures
    /// are replayed through each chain's production decoder and SQLite path in
    /// disposable databases. The test-only envelope adapter below is NOT proof
    /// of a testnet index provider, a broadcast, or an installed app UI run.
    func testCapturedEVMTestnetEndpointsSurviveProductionReceiptProjection() async throws {
        let captures = try publicReceipts("evm")
        XCTAssertEqual(captures.count, 19)
        for capture in captures {
            let network = try XCTUnwrap(capture["network"].string)
            let tx = capture["transaction"], receipt = capture["receipt"]
            let sender = try XCTUnwrap(tx["from"].string).lowercased(), recipient = try XCTUnwrap(tx["to"].string).lowercased()
            let hash = try XCTUnwrap(tx["hash"].string).lowercased()
            XCTAssertEqual(receipt["transactionHash"].string?.lowercased(), hash)
            XCTAssertEqual(receipt["from"].string?.lowercased(), sender)
            XCTAssertEqual(receipt["to"].string?.lowercased(), recipient)
            XCTAssertEqual(tx["blockHash"], receipt["blockHash"])
            let stamp = try XCTUnwrap(capture["timestamp"].string)
            let timestamp = try XCTUnwrap(Double(AnkrQuantity.decimal(stamp)))
            let height = try XCTUnwrap(Int64(AnkrQuantity.decimal(XCTUnwrap(tx["blockNumber"].string))))
            let fee = try AnkrQuantity.multiply(AnkrQuantity.decimal(XCTUnwrap(receipt["gasUsed"].string)), AnkrQuantity.decimal(XCTUnwrap(receipt["effectiveGasPrice"].string)))
            let (db, file) = try await fixture(network)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            try await db.pool.write { try $0.execute(sql: "UPDATE accounts SET address=? WHERE id='a'", arguments: [sender]) }
            if let chain = AnkrChain(networkID: network) {
                guard case .object(var row) = tx else { return XCTFail("Missing public transaction") }
                row["blockchain"] = .string(chain.rawValue); row["timestamp"] = .string(stamp)
                row["status"] = receipt["status"]; row["gasUsed"] = receipt["gasUsed"]; row["effectiveGasPrice"] = receipt["effectiveGasPrice"]
                let raw = try JSONEncoder().encode(SolanaJSON.object(["transactions": .array([.object(row)])]))
                let value = try JSONDecoder().decode(AnkrTransactionResult.self, from: raw)
                let ticket = try await db.beginAnkrSync(accountID: "a", stream: "transactions")
                try await db.commitAnkrTransactions(.init(value: value, raw: raw, fetchedAt: .now), ticket: ticket, cursor: nil)
            } else {
                let row: SolanaJSON = .object([
                    "hash": .string(hash), "block_number": .string(String(height)),
                    "timestamp": .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: timestamp))),
                    "from": .object(["hash": .string(sender)]), "to": .object(["hash": .string(recipient)]),
                    "status": .string(receipt["status"].string == "0x1" ? "ok" : "error"),
                    "value": tx["value"], "fee": .object(["value": .string(fee)])])
                let index = try JSONEncoder().encode(SolanaJSON.object(["items": .array([row]), "next_page_params": .null]))
                if let chain = IndexedEVMChain(rawValue: network) {
                    let page = try IndexedEVMClient.decodeHistory(index, chain: chain, owner: sender, stream: .transactions)
                    let ticket = try await db.beginIndexedEVMSync(accountID: "a"), work = try await db.indexedEVMHistoryWork(ticket)
                    try await db.commitIndexedEVMPage(page, cursor: XCTUnwrap(work.first { $0.stream == "transactions" && $0.startTime <= timestamp && $0.endTime >= timestamp }), ticket: ticket)
                } else if network == "hyperevm" {
                    let page = try HyperEVMClient.decodeHistory(index, owner: sender, stream: .transactions)
                    let ticket = try await db.beginHyperEVMSync(accountID: "a"), work = try await db.hyperevmHistoryWork(ticket)
                    try await db.commitHyperEVMPage(page, cursor: XCTUnwrap(work.first { $0.stream == "transactions" && $0.startTime <= timestamp && $0.endTime >= timestamp }), ticket: ticket)
                } else if network == "robinhood" {
                    let page = try RobinhoodClient.decodeHistory(index, owner: sender, stream: .transactions)
                    let ticket = try await db.beginRobinhoodSync(accountID: "a"), work = try await db.robinhoodHistoryWork(ticket)
                    try await db.commitRobinhoodPage(page, cursor: XCTUnwrap(work.first { $0.stream == "transactions" && $0.startTime <= timestamp && $0.endTime >= timestamp }), ticket: ticket)
                } else if network == "arc" {
                    // Exercise the external call receipt independently of its
                    // optional token/EIP-7708 event streams.
                    let raw = try JSONEncoder().encode(SolanaJSON.object(["next_block": .number(String(height + 1)), "data": .array([.object([
                        "blocks": .array([.object(["number": .number(String(height)), "hash": tx["blockHash"], "timestamp": .string(stamp)])]),
                        "transactions": .array([.object(["hash": .string(hash), "block_number": .number(String(height)), "block_hash": tx["blockHash"], "from": .string(sender), "to": .string(recipient), "status": receipt["status"], "gas_used": receipt["gasUsed"], "effective_gas_price": receipt["effectiveGasPrice"]])]), "logs": .array([])])])]))
                    let page = try ArcClient.decodeHistory(raw, owner: sender, from: height, through: height + 1, tokens: [:])
                    let ticket = try await db.beginArcSync(accountID: "a")
                    try await db.pool.write { try $0.execute(sql: "INSERT INTO arcHistoryCursors(accountID,lane,startBlock,endBlock,nextBlock) VALUES('a','backfill',?,?,?)", arguments: [height, height + 1, height]) }
                    let work = try await db.arcHistoryWork(ticket)
                    try await db.commitArcPage(page, cursor: XCTUnwrap(work.first), ticket: ticket)
                } else { return XCTFail("Untested decoder for \(network)") }
            }
            let reopened = try await OathDatabase.open(at: file)
            let details = try await reopened.transactionDetails(accountID: "a", transactionID: network + ":" + hash)
            XCTAssertEqual(try XCTUnwrap(details, network).fromAddresses, [sender], network)
            XCTAssertEqual(details?.toAddresses, [recipient], network)
            print("CAPTURED_TESTNET_RECEIPT \(network) both endpoints persisted and read offline")
        }
    }
}

extension XrplLedgerTests {
    func testCapturedTestnetPaymentsKeepBothAddressesThroughDatabase() async throws {
        for envelope in try publicReceipts("xrpl") {
            let value = envelope["result"]
            let sender = try XCTUnwrap(value["Account"].string), recipient = try XCTUnwrap(value["Destination"].string)
            let row: XrplJSON = .object(["tx_json": value, "hash": value["hash"], "meta": value["meta"], "ledger_index": value["ledger_index"], "validated": value["validated"]])
            var tokens: [String: XrplToken] = [:]
            if let reference = value["Amount"]["mpt_issuance_id"].string {
                // Capture the public issuance alongside the transaction, just
                // as the synchronizer resolves MPT metadata before projection.
                let issuance = envelope["issuance"]
                XCTAssertEqual(issuance["LedgerEntryType"].string, "MPTokenIssuance")
                let scale = try XCTUnwrap(issuance["AssetScale"].integer)
                tokens[reference] = XrplToken(reference: reference, name: "MPT", symbol: "MPT", decimals: Int(scale), logo: nil)
            }
            for owner in [sender, recipient] {
                let (db, folder) = try await fixture(address: owner)
                defer { try? FileManager.default.removeItem(at: folder) }
                var filter = PortfolioFilter(); filter.hidesUnverifiedTokens = false
                try await db.savePortfolioFilter(filter, walletID: "w1")
                let tx = try XrplDecoding.transaction(row, owner: owner, tokens: tokens)
                let ticket = try await db.beginXrplSync(accountID: "a1"), work = try await db.xrplHistoryWork(ticket)
                try await db.commitXrplPage(.init(transactions: [tx], next: nil, head: tx.hash, upperLedger: tx.checkpoint, raw: try JSONEncoder().encode(envelope)), cursor: XCTUnwrap(work.first), ticket: ticket)
                let result = try await db.transactionDetails(accountID: "a1", transactionID: "xrpl:" + tx.hash)
                XCTAssertEqual(try XCTUnwrap(result).fromAddresses, [sender]); XCTAssertEqual(result?.toAddresses, [recipient])
            }
        }
    }
}

extension SuiLedgerTests {
    func testCapturedTestnetTransfersResolveRecipientsFromEffectsWithoutGasPayerPollution() async throws {
        for envelope in try publicReceipts("sui") {
            let node = envelope["data"]["transaction"]
            let sender = try SuiIdentity.address(XCTUnwrap(node["sender"]["address"].string))
            // Independent expected destination: decode the signed PTB's pure
            // address input, while production resolves peers from balance effects.
            let ptb = node["transactionJson"]["kind"]["programmableTransaction"]
            let command = try XCTUnwrap(ptb["commands"].array?.first { !$0["transferObjects"].isNull })
            let index = try XCTUnwrap(command["transferObjects"]["address"]["input"].integer)
            let bytes = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(ptb["inputs"].array?[Int(index)]["pure"].string)))
            XCTAssertEqual(bytes.count, 32)
            let recipient = "0x" + bytes.map { String(format: "%02x", $0) }.joined()
            let (db, folder) = try await fixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            try await db.pool.write { try $0.execute(sql: "UPDATE accounts SET address=? WHERE id='a1'", arguments: [sender]) }
            let tx = try SuiDecoding.transaction(node, owner: sender, tokens: ["native": .native])
            let ticket = try await db.beginSuiSync(accountID: "a1"), work = try await db.suiHistoryWork(ticket)
            try await db.commitSuiPage(.init(transactions: [tx], next: nil, head: tx.hash, raw: try JSONEncoder().encode(envelope)), cursor: XCTUnwrap(work.first), ticket: ticket)
            let result = try await db.transactionDetails(accountID: "a1", transactionID: "sui:" + tx.hash)
            XCTAssertEqual(try XCTUnwrap(result).fromAddresses, [sender]); XCTAssertEqual(result?.toAddresses, [recipient])
        }
    }
}

extension TronLedgerTests {
    func testCapturedNileTransfersKeepNativeTRC10AndTRC20Parties() async throws {
        for envelope in try publicReceipts("tron") {
            let body = envelope["transaction"], receipt = envelope["receipt"]
            let tx = try TronDecoding.transaction(hash: XCTUnwrap(body["txID"].string), body: body, receipt: receipt)
            let contract = try XCTUnwrap(body["raw_data"]["contract"].array?.first), value = contract["parameter"]["value"]
            let sender = try TronIdentity.address(XCTUnwrap(value["owner_address"].string))
            let recipient: String
            if contract["type"].string == "TriggerSmartContract" {
                let call = try XCTUnwrap(value["data"].string)
                XCTAssertTrue(call.hasPrefix("a9059cbb")) // Standard transfer(address,uint256).
                recipient = try TronIdentity.address("41" + String(call.dropFirst(8 + 24).prefix(40)))
            } else { recipient = try TronIdentity.address(XCTUnwrap(value["to_address"].string)) }
            for owner in [sender, recipient] {
                let (db, folder) = try await fixture()
                defer { try? FileManager.default.removeItem(at: folder) }
                try await db.pool.write { try $0.execute(sql: "UPDATE accounts SET address=? WHERE id='a1'", arguments: [owner]) }
                var filter = PortfolioFilter(); filter.hidesUnverifiedTokens = false
                try await db.savePortfolioFilter(filter, walletID: "w1")
                // Display metadata does not affect endpoint validation. The
                // actual public contract IDs/amounts come from the node receipt.
                let tokens = Dictionary(uniqueKeysWithValues: Set(tx.events.map(\.reference)).map { ($0, TronToken(reference: $0, name: "Test asset", symbol: "TEST", decimals: 6)) })
                let ticket = try await db.beginTronSync(accountID: "a1"), work = try await db.tronHistoryWork(ticket)
                try await db.commitTronPage(.init(hashes: [tx.hash], cursor: nil, raw: try JSONEncoder().encode(envelope)), transactions: [tx], tokens: tokens, catalog: [:], cursor: XCTUnwrap(work.first), ticket: ticket)
                let result = try await db.transactionDetails(accountID: "a1", transactionID: "tron:" + tx.hash)
                XCTAssertEqual(try XCTUnwrap(result).fromAddresses, [sender]); XCTAssertEqual(result?.toAddresses, [recipient])
            }
        }
    }
}

extension ActivityDetailsTests {
    func testLiveAlchemyArcAndRobinhoodHistoryAndOfflineParties() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OATH_ALCHEMY_HISTORY_LIVE"] == "1" else { throw XCTSkip("Opt-in public Alchemy history/receipt verification") }
        let config = try XCTUnwrap(environment["OATH_ANKR_CONFIG"])
        let secrets = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: config)), format: nil) as! [String: String]
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OathAnkr/Tests/OathAnkrTests/Fixtures/Receipts/alchemy-mainnet-public-samples.json")
        var samples = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self, from: Data(contentsOf: fixtureURL)).array)
        for sample in samples {
            if let owner = sample["tokenOwner"].string {
                samples.append(.object(["network": .string("robinhood"), "owner": .string(owner), "stream": .string("transfers")]))
            }
        }
        for sample in samples {
            let network = try XCTUnwrap(sample["network"].string), owner = try XCTUnwrap(sample["owner"].string)
            let (db, file) = try await fixture(network)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            try await db.pool.write { try $0.execute(sql: "UPDATE accounts SET address=? WHERE id='a'", arguments: [owner]) }
            var filter = PortfolioFilter(); filter.hidesUnverifiedTokens = false
            try await db.savePortfolioFilter(filter, walletID: "w")
            if network == "arc" {
                let client = try ArcClient(alchemyAPIKey: XCTUnwrap(secrets["AlchemyAPIKey"]))
                let block = try XCTUnwrap(sample["block"].text.flatMap(Int64.init))
                let page = try await client.history(owner: owner, from: block, through: block + 1)
                XCTAssertFalse(page.transactions.isEmpty)
                XCTAssertFalse(page.events.isEmpty, "Arc native EIP-7708 receipt logs must survive discovery")
                let ticket = try await db.beginArcSync(accountID: "a")
                try await db.prepareArcHistory(ticket, through: block + 1)
                try await db.pool.write { try $0.execute(sql: "UPDATE arcHistoryCursors SET startBlock=?,nextBlock=?,endBlock=? WHERE accountID='a' AND lane='recent'", arguments: [block, block, block + 1]) }
                let work = try await db.arcHistoryWork(ticket)
                let cursor = try XCTUnwrap(work.first { $0.lane == "recent" })
                try await db.commitArcPage(page, cursor: cursor, ticket: ticket)
                let reopened = try await OathDatabase.open(at: file)
                for event in page.events where event.amount != "0" {
                    let detail = try await reopened.transactionDetails(accountID: "a", transactionID: "arc:" + event.hash)
                    XCTAssertTrue(try XCTUnwrap(detail).fromAddresses.contains(event.from))
                    XCTAssertTrue(detail?.toAddresses.contains(event.to) == true)
                }
                try await assertActivityDetails(reopened, walletID: "w")
                print("LIVE_ALCHEMY arc: \(page.events.count) receipt-verified events; offline From/To")
            } else {
                let client = try RobinhoodClient(apiKey: XCTUnwrap(secrets["AnkrAPIKey"]), alchemyAPIKey: XCTUnwrap(secrets["AlchemyAPIKey"]))
                XCTAssertEqual(client.historyStreams, [.transactions, .transfers])
                let stream: RobinhoodHistoryStream = sample["stream"].string == "transfers" ? .transfers : .transactions
                let ticket = try await db.beginRobinhoodSync(accountID: "a")
                let work = try await db.robinhoodHistoryWork(ticket)
                let cursor = try XCTUnwrap(work.first { $0.stream == stream.rawValue && $0.lane == "recent" })
                let page = try await client.history(owner: owner, stream: stream, from: cursor.startTime, through: cursor.endTime)
                XCTAssertFalse(page.events.isEmpty)
                try await db.commitRobinhoodPage(page, cursor: cursor, ticket: ticket)
                let reopened = try await OathDatabase.open(at: file)
                for event in page.events {
                    let detail = try await reopened.transactionDetails(accountID: "a", transactionID: "robinhood:" + event.hash)
                    XCTAssertTrue(try XCTUnwrap(detail).fromAddresses.contains(event.from))
                    XCTAssertTrue(detail?.toAddresses.contains(event.to) == true)
                }
                try await assertActivityDetails(reopened, walletID: "w")
                print("LIVE_ALCHEMY robinhood: \(page.events.count) \(stream.rawValue) receipt-verified events; offline From/To")
            }
        }
    }
}
