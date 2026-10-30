import Foundation
import XCTest
import GRDB
import OathBitcoin
@testable import OathAnkr
@testable import OathDatabase

func assertActivityDetails(_ db: OathDatabase, walletID: String, requireRows: Bool = true) async throws {
    let history = try await db.history(walletID: walletID, limit: 200)
    if requireRows { XCTAssertFalse(history.isEmpty) }
    var tokens = 0, bothParties = 0
    for row in history {
        XCTAssertGreaterThan(row.timestamp, 0)
        XCTAssertTrue(["incoming", "outgoing", "self"].contains(row.direction))
        let fetched = try await db.transactionDetails(accountID: row.accountID, transactionID: row.transactionID)
        let detail = try XCTUnwrap(fetched)
        XCTAssertEqual(detail.state, row.state)
        XCTAssertEqual(detail.transaction.hash, row.hash)
        XCTAssertEqual(detail.transaction.networkID, row.networkID)
        XCTAssertFalse(detail.fromAddresses.contains("")); XCTAssertFalse(detail.toAddresses.contains(""))
        XCTAssertEqual(Set(detail.fromAddresses).count, detail.fromAddresses.count)
        XCTAssertEqual(Set(detail.toAddresses).count, detail.toAddresses.count)
        for transfer in detail.transfers {
            if !transfer.fromAddress.isEmpty { XCTAssertTrue(detail.fromAddresses.contains(transfer.fromAddress)) }
            if !transfer.toAddress.isEmpty { XCTAssertTrue(detail.toAddresses.contains(transfer.toAddress)) }
        }
        if !detail.fromAddresses.isEmpty && !detail.toAddresses.isEmpty { bothParties += 1 }
        XCTAssertEqual(detail.feeAsset?.reference, "native")
        let asset = try await db.pool.read { try AssetRecord.fetchOne($0, key: row.assetID) }
        let quantity = try AtomicAmount(row.amountAtomic).units(decimals: XCTUnwrap(asset).decimals)
        XCTAssertNotNil(Decimal(string: quantity, locale: Locale(identifier: "en_US_POSIX")))
        if let fee = detail.transaction.feeAtomic { _ = try AtomicAmount(fee) }
        if asset?.reference != "native" { tokens += 1 }
    }
    print("ACTIVITY_DETAILS rows=\(history.count) tokens=\(tokens) bothParties=\(bothParties) networks=\(Set(history.map(\.networkID)).sorted().joined(separator: ","))")
}

extension AptosLedgerTests {
    func testCapturedTestnetReceiptsPersistBothPartiesForSenderAndRecipient() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OathAnkr/Tests/OathAnkrTests/Fixtures/Receipts/aptos-testnet.json")
        let pairs = try XCTUnwrap(JSONDecoder().decode(AptosJSON.self, from: Data(contentsOf: fixtureURL)).array)
        XCTAssertEqual(pairs.count, 5)
        for pair in pairs {
            let receipt = pair["receipt"], payload = receipt["payload"]
            let sender = try AptosIdentity.address(XCTUnwrap(receipt["sender"].string))
            let recipientIndex = payload["function"].string!.contains("primary_fungible_store") ? 1 : 0
            let recipient = try AptosIdentity.address(XCTUnwrap(payload["arguments"].array?[recipientIndex].string))
            for owner in [sender, recipient] {
                let (db, folder) = try await fixture()
                defer { try? FileManager.default.removeItem(at: folder) }
                try await db.pool.write { try $0.execute(sql: "UPDATE accounts SET address=? WHERE id='a1'", arguments: [owner]) }
                var filter = PortfolioFilter(); filter.hidesUnverifiedTokens = false
                try await db.savePortfolioFilter(filter, walletID: "w1")
                guard case .object(var index) = pair["index"] else { return XCTFail("Missing public index data") }
                index["account_address"] = .string(owner)
                let tx = try AptosDecoding.transaction(row: .object(index), detail: receipt, owner: owner)
                XCTAssertTrue(tx.events.allSatisfy { $0.owner == owner }, "Peers must not become this account's history movements")
                let ticket = try await db.beginAptosSync(accountID: "a1")
                let work = try await db.aptosHistoryWork(ticket)
                let cursor = try XCTUnwrap(work.first)
                try await db.commitAptosPage(.init(transactions: [tx], next: nil, head: tx.version, raw: try JSONEncoder().encode(pair)), cursor: cursor, ticket: ticket, catalog: .init(tokens: [:], aliases: [:]))
                let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
                let details = try await reopened.transactionDetails(accountID: "a1", transactionID: "aptos:" + tx.hash)
                XCTAssertEqual(try XCTUnwrap(details).fromAddresses, [sender])
                XCTAssertEqual(details?.toAddresses, [recipient])
            }
        }
    }
}

@MainActor final class ActivityDetailsTests: XCTestCase {
    func testEVMChecksummedAccountDoesNotDuplicateReceiptAddress() async throws {
        let (database, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sender = "0x" + String(repeating: "Ab", count: 20), recipient = "0x" + String(repeating: "c", count: 40)
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE accounts SET address=? WHERE id='a'", arguments: [sender])
            try TransactionRecord(id: "mixed-case", networkID: "ethereum", hash: "mixed-case", state: "confirmed", timestamp: 1, updatedAt: 1).insert(db)
            try ActivityRecord(id: "mixed-case-row", walletID: "w", accountID: "a", networkID: "ethereum", transactionID: "mixed-case", assetID: "ethereum:native", direction: "outgoing", amountAtomic: "10", counterparty: recipient, timestamp: 1).insert(db)
            try TransferRecord(id: "mixed-case-transfer", transactionID: "mixed-case", networkID: "ethereum", assetID: "ethereum:native", eventIndex: 0, fromAddress: sender.lowercased(), toAddress: recipient, amountAtomic: "10").insert(db)
        }
        let details = try await database.transactionDetails(accountID: "a", transactionID: "mixed-case")
        XCTAssertEqual(details?.fromAddresses, [sender.lowercased()]); XCTAssertEqual(details?.toAddresses, [recipient])
    }

    func testNearContractOnlyReceiptUsesCachedExecutionWithoutGuessingSelfTransfer() async throws {
        let (database, url) = try await fixture("near")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let raw = Data(#"{"transaction":{"hash":"execution","signer_id":"alice.near","receiver_id":"contract.near"}}"#.utf8)
        let execution = NearExecution(owner: "alice.near", hash: "execution", blockHeight: 1, timestamp: 1, failed: false, fee: "1", raw: raw)
        let data = try JSONEncoder().encode(execution)
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE accounts SET address='alice.near' WHERE id='a'")
            try TransactionRecord(id: "near:execution", networkID: "near", hash: "execution", state: "confirmed", timestamp: 1, updatedAt: 1).insert(db)
            try ActivityRecord(id: "execution-row", walletID: "w", accountID: "a", networkID: "near", transactionID: "near:execution", assetID: "near:native", direction: "self", amountAtomic: "0", counterparty: "", timestamp: 1).insert(db)
            try db.execute(sql: "INSERT INTO nearTransactions(accountID,hash,detail) VALUES('a','execution',?)", arguments: [data])
        }
        let details = try await database.transactionDetails(accountID: "a", transactionID: "near:execution")
        XCTAssertEqual(details?.fromAddresses, ["alice.near"]); XCTAssertEqual(details?.toAddresses, ["contract.near"])
    }

    func testBothPartiesSurviveMultipleTransfersAndAccountIsolation() async throws {
        let (database, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await database.pool.write { db in
            try TransactionRecord(id: "many", networkID: "ethereum", hash: "many", state: "confirmed", timestamp: 1, updatedAt: 1).insert(db)
            try ActivityRecord(id: "many-row", walletID: "w", accountID: "a", networkID: "ethereum", transactionID: "many", assetID: "ethereum:native", direction: "outgoing", amountAtomic: "30", counterparty: "", timestamp: 1).insert(db)
            for (index, recipient) in ["recipient-1", "recipient-2", "recipient-1"].enumerated() {
                try TransferRecord(id: "transfer-\(index)", transactionID: "many", networkID: "ethereum", assetID: "ethereum:native", eventIndex: index, fromAddress: "public", toAddress: recipient, amountAtomic: "10").insert(db)
            }
        }
        let result = try await database.transactionDetails(accountID: "a", transactionID: "many")
        XCTAssertEqual(result?.fromAddresses, ["public"])
        XCTAssertEqual(result?.toAddresses, ["recipient-1", "recipient-2"])
        let unrelated = try await database.transactionDetails(accountID: "unrelated", transactionID: "many")
        XCTAssertNil(unrelated)
    }

    func testSolanaReceiptUsesSelectedDerivationAndActivityOwner() async throws {
        let (database, url) = try await fixture("solana")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await database.pool.write { db in
            try db.execute(sql: "INSERT INTO solanaReceiveAddresses(accountID,path,address,isSelected) VALUES('a','selected','selected-owner',1)")
            try TransactionRecord(id: "solana:receipt", networkID: "solana", hash: "receipt", state: "confirmed", timestamp: 1, updatedAt: 1).insert(db)
            for (index, owner) in ["selected-owner", "other-owner"].enumerated() {
                let id = "row-\(index)"
                try ActivityRecord(id: id, walletID: "w", accountID: "a", networkID: "solana", transactionID: "solana:receipt", assetID: "solana:native", direction: "incoming", amountAtomic: "10", counterparty: "sender-\(index)", timestamp: 1).insert(db)
                try db.execute(sql: "INSERT INTO solanaActivity(activityID,owner) VALUES(?,?)", arguments: [id, owner])
                let detail = try JSONSerialization.data(withJSONObject: ["signature": "receipt", "slot": 1, "timestamp": 1, "failed": false, "fee": "5", "changes": [["mint": "native", "decimals": 9, "amount": "10", "direction": "incoming", "counterparty": "sender-\(index)"]], "tokenAccounts": [], "raw": "e30="])
                try db.execute(sql: "INSERT INTO solanaTransactions(accountID,owner,signature,detail) VALUES('a',?,'receipt',?)", arguments: [owner, detail])
            }
        }
        let detail = try await database.transactionDetails(accountID: "a", transactionID: "solana:receipt")
        XCTAssertEqual(detail?.fromAddresses, ["sender-0"])
        XCTAssertEqual(detail?.toAddresses, ["selected-owner"])
    }

    func testHistoryOnlyIncomingOutgoingAndUnknownParties() async throws {
        for direction in ["incoming", "outgoing", "self"] {
            let (database, url) = try await fixture("xrpl")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try await database.pool.write { db in
                try TransactionRecord(id: "payment", networkID: "xrpl", hash: "payment", state: "confirmed", timestamp: 1, updatedAt: 1).insert(db)
                try ActivityRecord(id: "payment-row", walletID: "w", accountID: "a", networkID: "xrpl", transactionID: "payment", assetID: "xrpl:native", direction: direction, amountAtomic: direction == "self" ? "0" : "10", counterparty: direction == "self" ? "" : "peer", timestamp: 1).insert(db)
            }
            let result = try await database.transactionDetails(accountID: "a", transactionID: "payment")
            XCTAssertEqual(result?.fromAddresses, direction == "incoming" ? ["peer"] : direction == "outgoing" ? ["public"] : [])
            XCTAssertEqual(result?.toAddresses, direction == "incoming" ? ["public"] : direction == "outgoing" ? ["peer"] : [])
        }
    }

    func testSolanaReceiptIncludesAllCachedTransferPeersWithoutNetwork() async throws {
        let (database, url) = try await fixture("solana")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let owner = "H31vEBxSJk1nQdUN11qZgZyhScyShhscKhvhZZU3dQoU"
        let recipients = ["HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk", "So11111111111111111111111111111111111111112"]
        let signature = String(repeating: "1", count: 64)
        let instructions = recipients.map { recipient in
            ["programId": "11111111111111111111111111111111", "parsed": ["type": "transfer", "info": ["source": owner, "destination": recipient]]] as [String: Any]
        }
        let raw = try JSONSerialization.data(withJSONObject: [
            "meta": ["preTokenBalances": [], "postTokenBalances": []],
            "transaction": ["signatures": [signature], "message": ["accountKeys": [owner] + recipients, "instructions": instructions]]])
        let detail = try JSONSerialization.data(withJSONObject: ["signature": signature, "slot": 1, "failed": false, "fee": "5", "changes": [["mint": "native", "decimals": 9, "amount": "20", "direction": "outgoing"]], "tokenAccounts": [], "raw": raw.base64EncodedString()])
        try await database.pool.write { db in
            try db.execute(sql: "INSERT INTO solanaReceiveAddresses(accountID,path,address,isSelected) VALUES('a','selected',?,1)", arguments: [owner])
            try TransactionRecord(id: "solana:multi", networkID: "solana", hash: signature, state: "confirmed", timestamp: 1, updatedAt: 1).insert(db)
            try ActivityRecord(id: "multi-row", walletID: "w", accountID: "a", networkID: "solana", transactionID: "solana:multi", assetID: "solana:native", direction: "outgoing", amountAtomic: "20", counterparty: "", timestamp: 1).insert(db)
            try db.execute(sql: "INSERT INTO solanaActivity(activityID,owner) VALUES('multi-row',?)", arguments: [owner])
            try db.execute(sql: "INSERT INTO solanaTransactions(accountID,owner,signature,detail) VALUES('a',?,?,?)", arguments: [owner, signature, detail])
        }
        let result = try await database.transactionDetails(accountID: "a", transactionID: "solana:multi")
        XCTAssertEqual(result?.fromAddresses, [owner]); XCTAssertEqual(result?.toAddresses, recipients.sorted())
    }

    func testTokenFeeUsesNativePriceAndCachedDisplayCurrency() async throws {
        let (database, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await database.pool.write { db in
            try AssetRecord(id: "token", networkID: "ethereum", reference: "0xtoken", name: "Token", symbol: "TKN", decimals: 6).insert(db)
            // This test exercises an explicitly tracked token's fee display.
            try db.execute(sql: "INSERT INTO trackedAssets(accountID,assetID,networkID,addedAt) VALUES('a','token','ethereum',1)")
            try TransactionRecord(id: "fee-tx", networkID: "ethereum", hash: "public-hash", state: "confirmed",
                timestamp: 10, feeAtomic: "21000000000000", updatedAt: 10).insert(db)
            try ActivityRecord(id: "fee-row", walletID: "w", accountID: "a", networkID: "ethereum", transactionID: "fee-tx",
                assetID: "token", direction: "outgoing", amountAtomic: "1000000", counterparty: "receiver", timestamp: 10).insert(db)
        }
        let missing = try await database.transactionDetails(accountID: "a", transactionID: "fee-tx", currency: "JOD")
        XCTAssertNil(missing?.feeFiatValue)
        try await database.savePrices([
            .init(assetID: "token", currency: "USD", value: "1000000", observedAt: 20, source: "fixture"),
            .init(assetID: "ethereum:native", currency: "USD", value: "2000", observedAt: 10, source: "fixture"),
            .init(assetID: "ethereum:native", currency: "USD", value: "3000", observedAt: 20, source: "fixture")])
        try await database.saveExchangeRates(.init(rates: ["USD": "1", "JOD": "0.709"], observedAt: 20, fetchedAt: 20, source: "fixture"))
        let local = try await database.transactionDetails(accountID: "a", transactionID: "fee-tx", currency: "JOD")
        XCTAssertEqual(local?.feeFiatValue, Decimal(string: "0.044667"))
        let usd = try await database.transactionDetails(accountID: "a", transactionID: "fee-tx")
        XCTAssertEqual(usd?.feeFiatValue, Decimal(string: "0.063"))
        let unavailableFX = try await database.transactionDetails(accountID: "a", transactionID: "fee-tx", currency: "EUR")
        XCTAssertNil(unavailableFX?.feeFiatValue)
        let reopened = try await OathDatabase.open(at: url)
        let cached = try await reopened.transactionDetails(accountID: "a", transactionID: "fee-tx", currency: "JOD")
        XCTAssertEqual(cached, local)
        var changes = database.observeTransactionDetails(accountID: "a", transactionID: "fee-tx", currency: "USD").makeAsyncIterator()
        let initial = try await changes.next()
        XCTAssertEqual(initial??.feeFiatValue, Decimal(string: "0.063"))
        try await database.savePrices([.init(assetID: "ethereum:native", currency: "USD", value: "4000", observedAt: 30, source: "fixture")])
        let updated = try await changes.next()
        XCTAssertEqual(updated??.feeFiatValue, Decimal(string: "0.084"))
        try await database.pool.write { try $0.execute(sql: "UPDATE transactions SET feeAtomic='0' WHERE id='fee-tx'") }
        let zero = try await database.transactionDetails(accountID: "a", transactionID: "fee-tx", currency: "EUR")
        XCTAssertEqual(zero?.feeFiatValue, 0)
    }

    func fixture(_ network: String = "ethereum") async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("activity-tests-" + UUID().uuidString).appendingPathComponent("db.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: [.init(id: network, name: network, family: UTXONetwork(rawValue: network) == nil ? "evm" : "utxo", symbol: "COIN", decimals: UTXONetwork(rawValue: network) == nil ? 18 : 8, derivationPath: "", logo: "", sortOrder: 0)],
            assets: [.init(id: network + ":native", networkID: network, reference: "native", name: network, symbol: "COIN", decimals: UTXONetwork(rawValue: network) == nil ? 18 : 8)])
        try await db.importWalletIfNeeded(.init(id: "w", name: "Public fixture", kind: "watchOnly", vaultReference: "none", createdAt: 1),
            accounts: [.init(id: "a", walletID: "w", networkID: network, address: "public", derivationPath: "")])
        return (db, url)
    }
    func testConflictRequiresMinedCompetitorAndSelfTransferEvidence() async throws {
        for cancelled in [false, true] {
            let (db,url) = try await fixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try await db.pool.write { db in
                let old = TransactionRecord(id: "old", networkID: "ethereum", hash: "old", state: "pending", timestamp: 10, updatedAt: 10)
                try old.insert(db)
                try ActivityRecord(id: "row", walletID: "w", accountID: "a", networkID: "ethereum", transactionID: "old", assetID: "ethereum:native", direction: "outgoing", amountAtomic: "100", counterparty: "receiver", timestamp: 10).insert(db)
                try OathDatabase.saveTransactionEvidence(accountID: "a", tx: old, keys: ["sender:7"], returnsToWallet: false, db: db)
                var winner = TransactionRecord(id: "new", networkID: "ethereum", hash: "new", state: "pending", timestamp: 20, updatedAt: 20)
                try winner.insert(db)
                try OathDatabase.saveTransactionEvidence(accountID: "a", tx: winner, keys: ["sender:7"], returnsToWallet: cancelled, db: db)
                XCTAssertNil(try String.fetchOne(db, sql: "SELECT outcome FROM transactionEvidence WHERE transactionID='old'"))
                winner.state = "confirmed"; try winner.update(db)
                try OathDatabase.saveTransactionEvidence(accountID: "a", tx: winner, keys: ["sender:7"], returnsToWallet: cancelled, db: db)
            }
            let rows = try await db.assetHistory(walletID: "w", accountID: "a", assetID: "ethereum:native")
            XCTAssertEqual(rows.first?.state, cancelled ? "canceled" : "replaced")
            let chain = try await db.chainHistory(walletID: "w", networkID: "ethereum", currency: "USD")
            XCTAssertEqual(chain.first?.entry.state, cancelled ? "canceled" : "replaced")
            let detail = try await db.transactionDetails(accountID: "a", transactionID: "old")
            XCTAssertEqual(detail?.state, cancelled ? "canceled" : "replaced")
            XCTAssertEqual(detail?.replacementHash, "new")
            let unrelated = try await db.transactionDetails(accountID: "other", transactionID: "old")
            XCTAssertNil(unrelated)
            let reopened = try await OathDatabase.open(at: url)
            let cached = try await reopened.assetHistory(walletID: "w", accountID: "a", assetID: "ethereum:native")
            XCTAssertEqual(cached, rows)
        }
    }
    func testOpenReceiptObservesStatusWithoutChangingSelectedActivity() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.pool.write { db in
            try TransactionRecord(id: "live", networkID: "ethereum", hash: "public-hash", state: "pending",
                timestamp: 10, updatedAt: 10).insert(db)
            try ActivityRecord(id: "live-row", walletID: "w", accountID: "a", networkID: "ethereum", transactionID: "live",
                assetID: "ethereum:native", direction: "incoming", amountAtomic: "100", counterparty: "sender", timestamp: 10).insert(db)
        }
        let rows = try await db.history(walletID: "w")
        let selected = try XCTUnwrap(rows.first)
        var changes = db.observeTransactionDetails(accountID: "a", transactionID: "live", currency: "USD").makeAsyncIterator()
        let initial = try await changes.next()
        XCTAssertEqual(initial??.state, "pending")
        for state in ["confirmed", "reorged", "pending", "failed"] {
            try await db.pool.write { db in
                try db.execute(sql: "UPDATE transactions SET state=? WHERE id='live'", arguments: [state])
            }
            let emitted = try await changes.next()
            let observed = try XCTUnwrap(emitted ?? nil)
            XCTAssertEqual(observed.state, state)
            let refreshed = selected.updatingState(observed.state)
            XCTAssertEqual(refreshed.state, state)
            XCTAssertEqual(refreshed.updatingState(selected.state), selected,
                "Status updates must preserve the selected asset, account, amount and transaction identity")
        }
    }

    func testReceiptObservesAccountScopedReplacementEvidence() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.pool.write { db in
            try AccountRecord(id: "a2", walletID: "w", networkID: "ethereum", address: "public2", derivationPath: "").insert(db)
            let tx = TransactionRecord(id: "shared", networkID: "ethereum", hash: "public-hash", state: "pending",
                timestamp: 10, updatedAt: 10)
            try tx.insert(db)
            for account in ["a", "a2"] {
                try ActivityRecord(id: "row-" + account, walletID: "w", accountID: account, networkID: "ethereum", transactionID: tx.id,
                    assetID: "ethereum:native", direction: "outgoing", amountAtomic: "100", counterparty: "receiver", timestamp: 10).insert(db)
                try OathDatabase.saveTransactionEvidence(accountID: account, tx: tx, keys: [], returnsToWallet: false, db: db)
            }
        }
        var changes = db.observeTransactionDetails(accountID: "a", transactionID: "shared", currency: "USD").makeAsyncIterator()
        let initial = try await changes.next()
        XCTAssertEqual(initial??.state, "pending")
        for state in ["replaced", "canceled"] {
            try await db.pool.write { db in
                try db.execute(sql: "UPDATE transactionEvidence SET outcome=?,replacementHash='winner' WHERE accountID='a' AND transactionID='shared'", arguments: [state])
            }
            let emitted = try await changes.next()
            XCTAssertEqual(emitted??.state, state)
            XCTAssertEqual(emitted??.replacementHash, "winner")
            XCTAssertEqual(emitted??.transaction.state, "pending", "The transaction record alone does not contain replacement evidence")
            let other = try await db.transactionDetails(accountID: "a2", transactionID: "shared")
            XCTAssertEqual(other?.state, "pending", "Another account's evidence must not leak into this receipt")
            XCTAssertNil(other?.replacementHash)
        }
        let reopened = try await OathDatabase.open(at: url)
        let persisted = try await reopened.transactionDetails(accountID: "a", transactionID: "shared")
        XCTAssertEqual(persisted?.state, "canceled")
    }

    func testBitcoinFamilyDirectionsFeesChangeAndCancellation() async throws {
        for network in UTXONetwork.allCases {
            let (db,url) = try await fixture(network.rawValue)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let descriptor = try network.wallet(seed: Data(0..<32))
            try await db.prepareBitcoin(accountID: "a", descriptor: descriptor)
            let own = try BitcoinKeys.addresses(branch: descriptor.branches[0], range: 0..<1)[0].script
            let other = try BitcoinKeys.addresses(branch: network.wallet(seed: Data(1...32)).branches[0], range: 0..<1)[0].script
            func data(_ hex: String) -> Data { Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! }) }
            func transaction(parent: String?, outputs: [(String, UInt64)]) -> Data {
                var raw = Data([2,0,0,0,1])
                raw += parent.map { Data(data($0).reversed()) } ?? Data(repeating: 0, count: 32)
                raw += parent == nil ? Data([255,255,255,255,2,1,1]) : Data([0,0,0,0,0])
                raw += Data([253,255,255,255,UInt8(outputs.count)])
                for (script, amount) in outputs {
                    var amount = amount.littleEndian; raw += withUnsafeBytes(of: &amount) { Data($0) }
                    let script = data(script); raw.append(UInt8(script.count)); raw += script
                }
                raw += Data(repeating: 0, count: 4); return raw
            }
            let funding = transaction(parent: nil, outputs: [(own, 10_000)])
            let fundingID = try BitcoinTransactions.txid(funding, network: network)
            let sent = transaction(parent: fundingID, outputs: [(other, 7_000), (own, 2_900)])
            let sentID = try BitcoinTransactions.txid(sent, network: network)
            let canceled = transaction(parent: fundingID, outputs: [(own, 9_800)])
            let cancelID = try BitcoinTransactions.txid(canceled, network: network)
            let raw = [fundingID: funding, sentID: sent, cancelID: canceled]
            let accountValue = try await db.account("a"), account = try XCTUnwrap(accountValue)
            try await db.pool.write { db in
                for (hash,height) in [(fundingID,1),(sentID,0)] {
                    try db.execute(sql: "INSERT INTO bitcoinHistory(accountID,txid,height) VALUES('a',?,?)", arguments: [hash,height])
                }
            }
            try await db.commitBitcoinActivity(account: account, page: [.init(txid: fundingID,height: 1),.init(txid: sentID,height: 0)], raw: raw, times: [1: 1_700_000_000])
            var rows = try await db.history(walletID: "w")
            XCTAssertEqual(rows.first { $0.hash == fundingID }?.amountAtomic, "10000")
            XCTAssertEqual(rows.first { $0.hash == fundingID }?.direction, "incoming")
            XCTAssertEqual(rows.first { $0.hash == sentID }?.amountAtomic, "7000")
            XCTAssertEqual(rows.first { $0.hash == sentID }?.direction, "outgoing")
            let existingAccountValue = try await db.account("a")
            let existingAccount = try XCTUnwrap(existingAccountValue)
            let ownWork = try await db.bitcoinActivityWork(account: existingAccount)
            XCTAssertFalse(ownWork.contains { $0.txid == fundingID })
            try await db.pool.write { db in
                try AccountRecord(id: "a2", walletID: "w", networkID: network.rawValue, address: "public2", derivationPath: "").insert(db)
            }
            try await db.prepareBitcoin(accountID: "a2", descriptor: descriptor)
            try await db.pool.write { try $0.execute(sql: "INSERT INTO bitcoinHistory(accountID,txid,height) VALUES('a2',?,1)", arguments: [fundingID]) }
            let secondAccountValue = try await db.account("a2")
            let secondAccount = try XCTUnwrap(secondAccountValue)
            let secondWork = try await db.bitcoinActivityWork(account: secondAccount)
            XCTAssertTrue(secondWork.contains { $0.txid == fundingID }, "Global transaction cache must not skip another account's projection")
            let sentDetails = try await db.transactionDetails(accountID: "a", transactionID: network.rawValue + ":" + sentID)
            XCTAssertEqual(sentDetails?.transaction.feeAtomic, "100")
            let ownAddress = try XCTUnwrap(BitcoinTransactions.details(funding, network: network).outputs.first?.address)
            let sentAddresses = try BitcoinTransactions.details(sent, network: network).outputs.compactMap(\.address).sorted()
            XCTAssertEqual(sentDetails?.fromAddresses, [ownAddress])
            XCTAssertEqual(sentDetails?.toAddresses, sentAddresses, "Keep recipient and change outputs distinct")
            let fundingDetails = try await db.transactionDetails(accountID: "a", transactionID: network.rawValue + ":" + fundingID)
            XCTAssertEqual(fundingDetails?.inputs, [], "Coinbase has no input addresses")
            XCTAssertEqual(sentDetails?.inputs?.count, 1)
            XCTAssertEqual(sentDetails?.outputs?.count, 2)
            XCTAssertEqual(sentDetails?.outputs?.map(\.id), ["0", "1"])
            XCTAssertEqual(fundingDetails?.fromAddresses, [], "Coinbase must not invent a sender")
            XCTAssertEqual(fundingDetails?.toAddresses, [ownAddress])
            // Two inputs have no single representative sender. Both must still
            // be searchable, including after an offline cache migration.
            let multiFunding = transaction(parent: nil, outputs: [(own, 21_000)])
            let multiFundingID = try BitcoinTransactions.txid(multiFunding, network: network)
            let otherFunding = transaction(parent: nil, outputs: [(other, 8_000)])
            let otherFundingID = try BitcoinTransactions.txid(otherFunding, network: network)
            var multi = Data([2,0,0,0,2])
            for parent in [multiFundingID, otherFundingID] {
                multi += Data(data(parent).reversed())
                multi += Data([0,0,0,0,0,253,255,255,255])
            }
            multi.append(1)
            var multiAmount = UInt64(28_900).littleEndian
            multi += withUnsafeBytes(of: &multiAmount) { Data($0) }
            let ownScript = data(own); multi.append(UInt8(ownScript.count)); multi += ownScript
            multi += Data(repeating: 0, count: 4)
            let multiID = try BitcoinTransactions.txid(multi, network: network)
            try await db.pool.write { try $0.execute(sql: "INSERT INTO bitcoinHistory(accountID,txid,height) VALUES('a',?,3)", arguments: [multiID]) }
            try await db.commitBitcoinActivity(account: account, page: [.init(txid: multiID, height: 3)],
                raw: [multiFundingID: multiFunding, otherFundingID: otherFunding, multiID: multi], times: [3: 1_700_000_200])
            let otherAddress = try XCTUnwrap(BitcoinTransactions.details(otherFunding, network: network).outputs.first?.address)
            let multiDetails = try await db.transactionDetails(accountID: "a", transactionID: network.rawValue + ":" + multiID)
            XCTAssertEqual(multiDetails?.fromAddresses, [ownAddress, otherAddress].sorted())
            XCTAssertEqual(multiDetails?.toAddresses, [ownAddress])
            XCTAssertEqual(multiDetails?.inputs?.map(\.amountAtomic), ["21000", "8000"])
            XCTAssertEqual(multiDetails?.outputs?.map(\.amountAtomic), ["28900"])
            XCTAssertEqual(Set(multiDetails?.inputs?.map(\.id) ?? []).count, 2)
            let repeated = transaction(parent: multiID, outputs: [(own, 14_000), (own, 14_000)])
            let repeatedID = try BitcoinTransactions.txid(repeated, network: network)
            try await db.pool.write { try $0.execute(sql: "INSERT INTO bitcoinHistory(accountID,txid,height) VALUES('a',?,4)", arguments: [repeatedID]) }
            try await db.commitBitcoinActivity(account: account, page: [.init(txid: repeatedID, height: 4)],
                raw: [multiID: multi, repeatedID: repeated], times: [4: 1_700_000_300])
            let repeatedDetails = try await db.transactionDetails(accountID: "a", transactionID: network.rawValue + ":" + repeatedID)
            XCTAssertEqual(repeatedDetails?.outputs?.map(\.address), [ownAddress, ownAddress], "Do not merge distinct outputs to the same address")
            XCTAssertEqual(repeatedDetails?.outputs?.map(\.amountAtomic), ["14000", "14000"])
            let results = try await db.chainHistory(walletID: "w", currency: "USD", search: otherAddress)
            XCTAssertTrue(results.contains { $0.entry.hash == multiID })
            try await db.pool.write { db in
                try db.execute(sql: "DELETE FROM transactionParticipants")
                try OathDatabase.backfillBitcoinParticipants(db)
            }
            let backfilled = try await db.chainHistory(walletID: "w", currency: "USD", search: otherAddress)
            XCTAssertEqual(backfilled.map(\.id), results.map(\.id))
            try await db.pool.write { db in
                try db.execute(sql: "DELETE FROM bitcoinHistory WHERE txid=?", arguments: [sentID])
                try db.execute(sql: "INSERT INTO bitcoinHistory(accountID,txid,height) VALUES('a',?,2)", arguments: [cancelID])
            }
            try await db.commitBitcoinActivity(account: account, page: [.init(txid: cancelID,height: 2)], raw: raw, times: [2: 1_700_000_100])
            rows = try await db.history(walletID: "w")
            XCTAssertEqual(rows.first { $0.hash == sentID }?.state, "canceled")
            XCTAssertEqual(rows.first { $0.hash == cancelID }?.direction, "self")
            try await assertActivityDetails(db, walletID: "w")
            let reset = try await db.beginWalletReset()
            try await db.eraseWalletData(resetID: reset); try await db.finishWalletReset(resetID: reset)
            let count = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transactionEvidence") }
            XCTAssertEqual(count, 0)
        }
    }
    func testLiveBitcoinFamilyActivity() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ACTIVITY_LIVE"] == "1" else { throw XCTSkip("Opt-in public history check") }
        // Published BIP39 vector, used only to reproduce public addresses. No keys are saved.
        let hex = "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4"
        let seed = Data(stride(from: 0, to: hex.count, by: 2).map { i in UInt8(hex.dropFirst(i).prefix(2), radix: 16)! })
        for network in UTXONetwork.allCases {
            let (db,url) = try await fixture(network.rawValue); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let descriptor = try network.wallet(seed: seed)
            try await db.prepareBitcoin(accountID: "a", descriptor: descriptor)
            let addresses = try descriptor.branches.filter { $0.change == 0 }.map { try BitcoinKeys.addresses(branch: $0, range: 0..<1)[0] }
            let client = ElectrumPool(network: network)
            let states = try await client.query(scriptHashes: addresses.map(\.scriptHash))
            let history = Dictionary(states.flatMap(\.history).map { ($0.txid, $0.height) }, uniquingKeysWith: max)
            let latest = Array(history.sorted { $0.value > $1.value }.prefix(5))
            XCTAssertFalse(latest.isEmpty, network.rawValue)
            try await db.pool.write { db in
                for (id,height) in latest { try db.execute(sql: "INSERT INTO bitcoinHistory(accountID,txid,height) VALUES('a',?,?)", arguments: [id,height]) }
            }
            try await BitcoinActivitySynchronizer(database: db, client: client).refresh(accountID: "a")
            await client.close()
            try await assertActivityDetails(db, walletID: "w")
            let before = try await db.history(walletID: "w")
            let reopened = try await OathDatabase.open(at: url)
            let after = try await reopened.history(walletID: "w")
            XCTAssertEqual(before, after); XCTAssertEqual(before.count, latest.count)
        }
    }
    func testLiveEveryAdvancedAPIChainActivity() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ACTIVITY_LIVE"] == "1",
              let config = ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"] else { throw XCTSkip("Opt-in public history check") }
        let secrets = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: config)), format: nil) as! [String: String]
        let client = try AnkrClient(apiKey: XCTUnwrap(secrets["AnkrAPIKey"]))
        // Public senders sampled from chain blocks and Transfer logs; never local wallets.
        let candidates: [String: [String]] = [
            "flare": ["0xf178fd26fac21d47bb279706e2f8705af8be8eef", "0xc37e39514b4eec019091322542ecc99e57036edd", "0xd331b898a3df5dee5d3cc9df246062889d134e67", "0xf45c1a5ef4fb09f1c33f772175b2fec229d1885b", "0x707562569cd6f10523fd9e5ef47d00b391c82c48", "0x88d46717b16619b37fa2dfd2f038defb4459f1f7", "0x1ee7a29642d780a7ded6769ad4bee82ef5fd8764", "0xa6186aa1405afca4d9e8b2b8d75470f725377b5f"],
            "taiko": ["0x0000777735367b36bc9b61c50022d9d0700db4ec"],
            "xlayer": ["0xdeaddeaddeaddeaddeaddeaddeaddeaddead0001", "0x5da6d51b8f96cf31f6d3f1da939115c2e44f3cc8", "0xdb42fc720af0119c9e248a0c31f3017ce0837100", "0x58954c92c84e51f8295f97d01a6bec2829426e1b", "0x137f3f05a341982c14aab1839c28ebc0523827c5", "0xdbfa44a3118d32ac9f73468c8e960160f3b346fb", "0x56fc18a19700c84d22c5fde1308b3c68f9a8d5ec", "0x0dedc3c5e15bee45166924ea5b02f54a35b1f9c6"],
            "somnia_mainnet": ["0xcf4985e30be5ff1cea7f779f96fc483a20a52ca0", "0x4c8ae78acf569db9a360d8e56cd5ddd42d0be18e", "0x6e1ddc62fb5445c5ffbff23cf22b7afcc0567a1c", "0xb593629c1df88090fc3385e9009a99f996d33dc7", "0x445c06abbd02887e083617400576f0577e1968bc", "0x06838d309999b20a35a5236d220a93e51afd0809"],
            "story_mainnet": ["0x99b79f66cc1e70cdfbaa293837919f06b8741647", "0x5602a32e08083d5d1117e2af85822a52535d09d3", "0x1407df7522fe59743690dc653380ddc36b8e6699", "0xb53fa06b4c37065dc1c7aad35ac1e339535dc498", "0xbcdff56331e6ac12b13d057c084c94d0de50405a", "0xa8f4c4134c93f838963c6afdbcfce7419ba67eb0", "0x2c10244755eded53e118a318c241873279523e9d", "0xa37eded373c5cdf88644db7c6b89f222e756afb2"],
            "telos": ["0x02ea28694ae65358be92bafef5cb8c211f33db1a", "0x0984f20f6939c8dcc385abb8f40dd7802902d500"],
        ]
        for chain in AnkrChain.allCases {
            var nativeCount = 0, tokenCount = 0
            for address in ["0xF977814e90dA44bFA03b6295A0616a897441aceC"] + (candidates[chain.rawValue] ?? []) {
            let (db,url) = try await fixture(chain.networkID); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try await db.pool.write { try $0.execute(sql: "UPDATE accounts SET address=? WHERE id='a'", arguments: [address]) }
            async let native = client.transactions(chain: chain, address: address, pageSize: 5)
            async let tokens = client.transfers(chain: chain, address: address, pageSize: 5)
            let (transactions,transfers) = try await (native,tokens)
            let txTicket = try await db.beginAnkrSync(accountID: "a", stream: "transactions")
            let tokenTicket = try await db.beginAnkrSync(accountID: "a", stream: "transfers")
            try await db.commitAnkrTransactions(transactions, ticket: txTicket, cursor: nil)
            try await db.commitAnkrTransfers(transfers, ticket: tokenTicket, cursor: nil)
            try await assertActivityDetails(db, walletID: "w", requireRows: false)
            for tx in transactions.value.transactions {
                let rows = try await db.assetHistory(walletID: "w", accountID: "a", assetID: chain.networkID + ":native")
                // Incoming zero-value calls are deliberately hidden by history.
                if tx.from.lowercased() != address.lowercased(), try AnkrQuantity.decimal(tx.value) == "0" { continue }
                let row = try XCTUnwrap(rows.first { $0.hash == tx.hash.lowercased() })
                XCTAssertEqual(row.amountAtomic, tx.status == "0x0" ? "0" : try AnkrQuantity.decimal(tx.value))
                XCTAssertEqual(row.timestamp, Double(try AnkrQuantity.decimal(tx.timestamp ?? "0")))
                let detail = try await db.transactionDetails(accountID: "a", transactionID: row.transactionID)
                XCTAssertTrue(detail?.fromAddresses.contains(tx.from.lowercased()) == true)
                if let to = tx.to, !to.isEmpty { XCTAssertTrue(detail?.toAddresses.contains(to.lowercased()) == true) }
            }
            nativeCount += transactions.value.transactions.count; tokenCount += transfers.value.transfers.count
            if nativeCount > 0 && tokenCount > 0 { break }
            }
            print("LIVE_CHAIN \(chain.rawValue) native=\(nativeCount) token=\(tokenCount)")
            if nativeCount == 0 || tokenCount == 0 { print("LIVE_COVERAGE_GAP \(chain.rawValue) lacks nonempty native or token fixture") }
        }
    }
}

extension TronLedgerTests {
    func testLiveTokenActivityDetails() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_TRON_DATABASE_KEY"] else { throw XCTSkip("Opt-in public TRC20 activity") }
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        // Exercise the user's explicit unverified-token visibility option in
        // this disposable public fixture, without changing the product default.
        var filter = PortfolioFilter(); filter.hidesUnverifiedTokens = false
        try await db.savePortfolioFilter(filter, walletID: "w1")
        let client = try TronClient(apiKey: key)
        let ticket = try await db.beginTronSync(accountID: "a1")
        let work = try await db.tronHistoryWork(ticket)
        var cursor = try XCTUnwrap(work.first { $0.stream == "trc20" })
        var page = try await client.history(owner: owner, stream: .trc20, start: cursor.start, end: cursor.end, limit: 5)
        if page.hashes.isEmpty {
            try await db.commitTronPage(page, transactions: [], tokens: [:], catalog: catalog, cursor: cursor, ticket: ticket)
            let older = try await db.tronHistoryWork(ticket)
            cursor = try XCTUnwrap(older.first { $0.stream == "trc20" })
            page = try await client.history(owner: owner, stream: .trc20, start: cursor.start, end: cursor.end, limit: 5)
        }
        XCTAssertFalse(page.hashes.isEmpty)
        let transactions = try await withThrowingTaskGroup(of: TronTransaction.self) { group in
            for hash in page.hashes { group.addTask { try await client.transaction(hash) } }
            var result: [TronTransaction] = []; for try await tx in group { result.append(tx) }; return result
        }
        var tokens: [String: TronToken] = [:]
        for ref in Set(transactions.flatMap(\.events).map(\.reference)) { tokens[ref] = try await client.token(ref) }
        try await db.commitTronPage(page, transactions: transactions, tokens: tokens, catalog: catalog, cursor: cursor, ticket: ticket)
        try await assertActivityDetails(db, walletID: "w1")
        let rows = try await db.history(walletID: "w1")
        XCTAssertTrue(rows.contains { $0.assetID != "tron:native" })
        for tx in transactions {
            for event in tx.events where event.from == owner || event.to == owner {
                XCTAssertTrue(rows.contains { $0.hash == tx.hash && $0.amountAtomic == event.amount && $0.assetID == "tron:" + event.reference })
            }
        }
    }
}

extension NearLedgerTests {
    func testLiveTokenActivityDetails() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_NEAR_DATABASE_KEY"] else { throw XCTSkip("Opt-in public NEP141 activity") }
        let client = try NearClient(apiKey: key)
        var tokenRows = 0
        for owner in ["root.near", "mob.near", "intents.near"] {
            let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
            var filter = PortfolioFilter(); filter.hidesUnverifiedTokens = false
            try await db.savePortfolioFilter(filter, walletID: "w1")
            try await db.pool.write { try $0.execute(sql: "UPDATE accounts SET address=? WHERE id='a1'", arguments: [owner]) }
            let ticket = try await db.beginNearSync(accountID: "a1")
            let work = try await db.nearHistoryWork(ticket, stream: "transfers")
            let cursor = try XCTUnwrap(work)
            let page = try await client.history(owner: owner, stream: "transfers", limit: 50)
            try await db.commitNearPage(page, cursor: cursor, ticket: ticket)
            try await assertActivityDetails(db, walletID: "w1")
            let rows = try await db.history(walletID: "w1")
            tokenRows += rows.filter { $0.assetID != "near:native" }.count
            for event in page.events where event.token != nil {
                XCTAssertTrue(rows.contains { $0.id == "a1:near:event:" + event.id && $0.amountAtomic == event.amount.replacingOccurrences(of: "-", with: "") })
            }
            if tokenRows > 0 { break }
        }
        XCTAssertGreaterThan(tokenRows, 0)
    }
}

extension SuiLedgerTests {
    func testLiveTokenActivityDetails() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_SUI_DATABASE_KEY"] else { throw XCTSkip("Opt-in public Sui token activity") }
        let client = try SuiClient(apiKey: key)
        var tokenRows = 0
        for owner in ["0x39ee291682e829771ad0c3ed46ebc69a962b7c2f9e6477409b22616bcf21ac34",
                      "0x42960e77d87a60d0a0599757beb320147510933c5e63a6ccfec3fdd54aa796fc",
                      "0x6be20abe12a8e930fd8da5120fcb392753ef7b57b43401417aedaadeb1106ec4"] {
            let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
            var filter = PortfolioFilter(); filter.hidesUnverifiedTokens = false
            try await db.savePortfolioFilter(filter, walletID: "w1")
            try await db.pool.write { try $0.execute(sql: "UPDATE accounts SET address=? WHERE id='a1'", arguments: [owner]) }
            let ticket = try await db.beginSuiSync(accountID: "a1")
            for _ in 0..<3 {
                guard let cursor = try await db.suiHistoryWork(ticket).first else { break }
                let page = try await client.history(owner: owner, before: cursor.beforeCursor, beforeCheckpoint: cursor.upperCheckpoint, limit: 25)
                try await db.commitSuiPage(page, cursor: cursor, ticket: ticket)
                let rows = try await db.history(walletID: "w1", limit: 200)
                tokenRows += rows.filter { $0.assetID != "sui:native" }.count
                for tx in page.transactions {
                    for movement in tx.movements where movement.token != nil {
                        XCTAssertTrue(rows.contains { $0.hash == tx.hash && $0.amountAtomic == movement.amount && $0.assetID == "sui:" + movement.reference })
                    }
                }
                if tokenRows > 0 { break }
            }
            try await assertActivityDetails(db, walletID: "w1")
            if tokenRows > 0 { break }
        }
        XCTAssertGreaterThan(tokenRows, 0)
    }
}
