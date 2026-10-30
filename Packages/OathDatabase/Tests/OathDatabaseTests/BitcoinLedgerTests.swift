import Foundation
import XCTest
import GRDB
import OathBitcoin
@testable import OathDatabase

private struct LedgerQuery: BitcoinAddressQuerying {
    let replies: [String: BitcoinAddressState]
    func query(scriptHashes: [String]) async throws -> [BitcoinAddressState] {
        scriptHashes.map { replies[$0] ?? .init(confirmed: 0, unconfirmed: 0, history: [], unspent: []) }
    }
}

@MainActor final class BitcoinLedgerTests: XCTestCase {
    private func fixture(network: UTXONetwork = .bitcoin, descriptor supplied: BitcoinWalletDescriptor? = nil) async throws -> (OathDatabase, URL, BitcoinWalletDescriptor) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OathBitcoinLedger-" + UUID().uuidString).appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: [.init(id: network.rawValue, name: network.rawValue, family: "utxo", symbol: network.rawValue.uppercased(), decimals: 8, derivationPath: "m/84'/0'/0'", logo: "btc", sortOrder: 0)],
                          assets: [.init(id: network.rawValue + ":native", networkID: network.rawValue, reference: "native", name: network.rawValue, symbol: network.rawValue.uppercased(), decimals: 8)])
        // Public deterministic test material; never funded or used by the app.
        let descriptor = try supplied ?? network.wallet(seed: Data(0..<32))
        let first = try BitcoinKeys.addresses(branch: descriptor.branches[0], range: 0..<1)[0]
        for n in 1...2 {
            try await db.importWalletIfNeeded(.init(id: "w\(n)", name: "Fixture", kind: "hd", vaultReference: "test-\(n)", createdAt: 1),
                accounts: [.init(id: "a\(n)", walletID: "w\(n)", networkID: network.rawValue, address: first.address, derivationPath: first.path)])
            try await db.prepareBitcoin(accountID: "a\(n)", descriptor: descriptor)
        }
        return (db, url, descriptor)
    }

    private func funding(_ descriptor: BitcoinWalletDescriptor, coinbase: Bool = false) async throws -> (BitcoinScan, [String: Data]) {
        let addresses = try descriptor.branches.map { try BitcoinKeys.addresses(branch: $0, range: 0..<1)[0] }
        var raw = Data([2,0,0,0,1])
        raw += Data(repeating: coinbase ? 0 : 17, count: 32)
        raw += coinbase ? Data([255,255,255,255,2,1,1]) : Data([0,0,0,0,0])
        raw += Data([255,255,255,255,UInt8(addresses.count)])
        for address in addresses {
            var value = UInt64(1000).littleEndian
            raw += withUnsafeBytes(of: &value) { Data($0) }
            let bytes = stride(from: 0, to: address.script.count, by: 2).map { offset -> UInt8 in
                let start = address.script.index(address.script.startIndex, offsetBy: offset)
                return UInt8(address.script[start..<address.script.index(start, offsetBy: 2)], radix: 16)!
            }
            raw.append(UInt8(bytes.count)); raw += bytes
        }
        raw += Data(repeating: 0, count: 4)
        let txid = try BitcoinTransactions.txid(raw)
        let replies = Dictionary(uniqueKeysWithValues: addresses.enumerated().map { i, address in
            (address.scriptHash, BitcoinAddressState(confirmed: 1000, unconfirmed: 0,
                history: [.init(txid: txid, height: 800_000)], unspent: [.init(txid: txid, vout: i, value: 1000, height: 800_000)]))
        })
        return (try await BitcoinDiscovery(query: LedgerQuery(replies: replies)).scan(descriptor), [txid: raw])
    }
    private func commit(_ db: OathDatabase, account: String = "a1", scan: BitcoinScan, transactions: [String: Data], tip: Int64 = 800_200) async throws {
        let id = try await db.beginBitcoinScan(accountID: account)
        try await db.commitBitcoinScan(accountID: account, scanID: id, scan: scan, transactions: transactions, tipHeight: tip)
    }
    private func draft(_ id: String, wallet: Int = 1) -> SendRecord {
        .init(id: id, walletID: "w\(wallet)", accountID: "a\(wallet)", networkID: "bitcoin", assetID: "bitcoin:native", idempotencyKey: id,
              recipient: "test", amountAtomic: "1000", state: "draft", createdAt: 1, updatedAt: 1)
    }

    func testMissingActivityAncestorsDoNotInvalidateVerifiedQuoteInputs() async throws {
        let (db, _, wallet) = try await fixture()
        let (scan, transactions) = try await funding(wallet)
        try await commit(db, scan: scan, transactions: transactions)
        let before = try await db.bitcoinSpendableOutputs(walletID: "w1")
        XCTAssertFalse(before.isEmpty)
        // The funding transaction is verified and cached; only its ancestors
        // (needed for historical display amounts) are unavailable.
        let offline = ElectrumPool(servers: [])
        do { try await BitcoinActivitySynchronizer(database: db, client: offline).refresh(accountID: "a1"); XCTFail() }
        catch { XCTAssertEqual(error as? BitcoinError, .unavailable) }
        let after = try await db.bitcoinSpendableOutputs(walletID: "w1")
        XCTAssertEqual(after.map(\.output.transactionHash), before.map(\.output.transactionHash))
        let coins = after.map { BitcoinSendCoin(accountID: $0.output.accountID, txid: $0.output.transactionHash,
            vout: $0.output.outputIndex, value: $0.output.value, address: $0.derivation, previousTransaction: $0.previousTransaction) }
        let change = try await db.bitcoinChangeAddress(accountID: "a1")
        let recipient = try BitcoinKeys.addresses(branch: wallet.branches[0], range: 5..<6)[0]
        let plan = try BitcoinSendPlan.make(coins: coins, recipient: recipient.address, amount: 1000, change: change, ratePerKVByte: 1000)
        XCTAssertEqual(plan.recipientAmount, 1000)
        XCTAssertGreaterThan(plan.fee, 0)
    }


    func testGeneratedAddressPaginationCoversEveryTypeAndBothPathsWithoutIssuingAddresses() async throws {
        for network in UTXONetwork.allCases {
            let (db, url, wallet) = try await fixture(network: network)
            let before = try await db.bitcoinState(accountID: "a1")
            for branch in wallet.branches {
                // Model the persisted public lookahead produced by a long scan.
                let additional = try BitcoinKeys.addresses(branch: branch, range: 20..<73)
                try await db.pool.write { sql in
                    for address in additional {
                        try sql.execute(sql: """
                            INSERT INTO bitcoinAddresses(accountID,branchID,addressIndex,address,script,scriptHash,detail,used,issued)
                            VALUES(?,?,?,?,?,?,?,0,0)
                            """, arguments: ["a1", address.branchID, address.index, address.address, address.script,
                                              address.scriptHash, try JSONEncoder().encode(address)])
                    }
                }
                var collected: [BitcoinDerivedAddress] = []
                while true {
                    let page = try await db.bitcoinAddresses(accountID: "a1", branchID: branch.id, after: collected.last?.index, limit: 7)
                    if page.isEmpty { break }
                    collected += page
                }
                XCTAssertEqual(collected.map(\.index), Array(UInt32(0)..<73))
                XCTAssertEqual(Set(collected.map(\.id)).count, 73)
                XCTAssertTrue(collected.allSatisfy { $0.type == branch.type && $0.change == branch.change })
                let reopened = try await OathDatabase.open(at: url)
                let last = try await reopened.bitcoinAddress(accountID: "a1", branchID: branch.id, index: 72)
                XCTAssertEqual(last, collected.last)
                let anotherWallet = try await db.bitcoinAddress(accountID: "a2", branchID: branch.id, index: 72)
                XCTAssertNil(anotherWallet)

                // Search reaches persisted addresses beyond the first 50-row
                // browser page and retains account/type/receive-change scope.
                let target = try XCTUnwrap(collected.last)
                for query in [target.address, "  " + target.address.uppercased() + "  ", target.path,
                              target.path.replacingOccurrences(of: "'", with: "’"), "aDdReSs 72",
                              "\u{2066}" + target.address + "\u{2069}"] {
                    let results = try await reopened.bitcoinAddresses(accountID: "a1", branchID: branch.id,
                        search: .init(query: query))
                    XCTAssertEqual(results, [target])
                }
                let localized = try await db.bitcoinAddresses(accountID: "a1", branchID: branch.id,
                    search: .init(query: "العنوان ٧٢", nameFormat: "العنوان %@", localeIdentifier: "ar"))
                XCTAssertEqual(localized, [target])
                let firstMatches = try await db.bitcoinAddresses(accountID: "a1", branchID: branch.id, limit: 2,
                    search: .init(query: "Address 7"))
                let nextMatches = try await db.bitcoinAddresses(accountID: "a1", branchID: branch.id,
                    after: firstMatches.last?.index, limit: 2, search: .init(query: "Address 7"))
                XCTAssertEqual((firstMatches + nextMatches).map(\.index), [7, 70, 71, 72])
                let otherResults = try await db.bitcoinAddresses(accountID: "a2", branchID: branch.id,
                    search: .init(query: target.address))
                XCTAssertTrue(otherResults.isEmpty)
                for query in ["%", "_", "' OR 1=1 --", "no matching address"] {
                    let results = try await db.bitcoinAddresses(accountID: "a1", branchID: branch.id,
                        search: .init(query: query))
                    XCTAssertTrue(results.isEmpty, "Search text must remain literal, not SQL or wildcard syntax")
                }
            }
            let after = try await db.bitcoinState(accountID: "a1")
            XCTAssertEqual(before?.requiredThrough, after?.requiredThrough, "Browsing must not issue addresses or change the discovery gap")
            XCTAssertEqual(before?.preferredType, after?.preferredType)
        }
    }

    func testDogecoinHDChangeReceivePersistenceAndMaturity() async throws {
        let (db, url, wallet) = try await fixture(network: .dogecoin)
        let (scan, transactions) = try await funding(wallet, coinbase: true)
        try await commit(db, scan: scan, transactions: transactions, tip: 800_238)
        let immature = try await db.dogecoinSpendableOutputs(walletID: "w1")
        XCTAssertTrue(immature.isEmpty)
        try await commit(db, scan: scan, transactions: [:], tip: 800_239)
        let pool = try await db.dogecoinSpendableOutputs(walletID: "w1")
        XCTAssertEqual(pool.count, 2)
        XCTAssertEqual(Set(pool.map { $0.derivation.change }), [0, 1])
        XCTAssertTrue(pool.allSatisfy { $0.output.networkID == "dogecoin" })
        let balance = try await db.balance(accountID: "a1", assetID: "dogecoin:native")
        let bitcoin = try await db.balance(accountID: "a1", assetID: "bitcoin:native")
        XCTAssertEqual(balance?.amountAtomic, "2000"); XCTAssertNil(bitcoin)
        let address = try await db.bitcoinReceiveAddress(accountID: "a1")
        XCTAssertEqual(address.index, 1); XCTAssertTrue(address.address.hasPrefix("D"))
        let reopened = try await OathDatabase.open(at: url)
        let again = try await reopened.bitcoinReceiveAddress(accountID: "a1")
        XCTAssertEqual(again, address)
        try await reopened.saveReceive(.init(id: UUID().uuidString, accountID: "a1", networkID: "dogecoin",
            assetID: "dogecoin:native", address: address.address, state: "open", createdAt: Date.now.timeIntervalSince1970))
        let history = try await reopened.bitcoinHistory(accountID: "a1")
        XCTAssertEqual(history.count, 1)
        let id = try await reopened.beginBitcoinScan(accountID: "a1")
        try await reopened.failBitcoinScan(accountID: "a1", scanID: id, code: "disconnected")
        let cached = try await reopened.balance(accountID: "a1", assetID: "dogecoin:native")
        XCTAssertEqual(cached, balance)
        do { _ = try await reopened.dogecoinSpendableOutputs(walletID: "w1"); XCTFail("Failed scan was spendable") }
        catch { XCTAssertEqual(error as? StoreError, .staleSync) }
    }

    func testDogecoinReservationsAreGlobalAndResetFenced() async throws {
        let (db, _, wallet) = try await fixture(network: .dogecoin)
        let (scan, transactions) = try await funding(wallet)
        for id in ["a1", "a2"] { try await commit(db, account: id, scan: scan, transactions: transactions) }
        let pool = try await db.dogecoinSpendableOutputs(walletID: "w1")
        let points = pool.map { Outpoint(hash: $0.output.transactionHash, index: $0.output.outputIndex) }
        for n in 1...2 {
            try await db.saveDraft(.init(id: "doge-\(n)", walletID: "w\(n)", accountID: "a\(n)", networkID: "dogecoin",
                assetID: "dogecoin:native", idempotencyKey: "doge-\(n)", recipient: "test", amountAtomic: "1000", state: "draft", createdAt: 1, updatedAt: 1))
        }
        _ = try await db.queueSend("doge-1", outputs: points)
        do { _ = try await db.queueSend("doge-2", outputs: points); XCTFail("Duplicate Dogecoin reservation accepted") }
        catch { XCTAssertEqual(error as? StoreError, .reservationConflict) }
        let reserved = try await db.reservedOutputs(sendID: "doge-1")
        XCTAssertEqual(reserved.count, 2)
        XCTAssertEqual(Set(reserved.map(\.networkID)), ["dogecoin"])
        _ = try await db.beginWalletReset()
        do { _ = try await db.beginBitcoinScan(accountID: "a1"); XCTFail("Late DOGE scan started during reset") } catch { }
        do { _ = try await db.bitcoinReceiveAddress(accountID: "a1"); XCTFail("DOGE address written during reset") } catch { }
    }

    func testDogecoinAndBitcoinIdenticalOutpointsStaySeparate() async throws {
        // A single uncompressed key has the same locking script on both chains.
        // Identical transaction hashes must still have separate balances/reservations.
        let key = Data(repeating: 0, count: 31) + Data([1])
        let dogecoin = try DogecoinKeys.singleKey(bytes: key, compressed: false)
        let bitcoin = try BitcoinKeys.singleKey(bytes: key, compressed: false)
        let (db, _, _) = try await fixture(network: .dogecoin, descriptor: dogecoin)
        try await db.seed(networks: [.init(id: "bitcoin", name: "Bitcoin", family: "utxo", symbol: "BTC", decimals: 8, derivationPath: "imported", logo: "btc", sortOrder: 1)],
                          assets: [.init(id: "bitcoin:native", networkID: "bitcoin", reference: "native", name: "Bitcoin", symbol: "BTC", decimals: 8)])
        let receive = try BitcoinKeys.addresses(branch: bitcoin.branches[0], range: 0..<1)[0]
        try await db.pool.write { sql in
            try AccountRecord(id: "b1", walletID: "w1", networkID: "bitcoin", address: receive.address, derivationPath: "imported").insert(sql)
        }
        try await db.prepareBitcoin(accountID: "b1", descriptor: bitcoin)
        let (dogeScan, dogeRaw) = try await funding(dogecoin)
        let (btcScan, btcRaw) = try await funding(bitcoin)
        XCTAssertEqual(dogeRaw, btcRaw)
        try await commit(db, scan: dogeScan, transactions: dogeRaw)
        try await commit(db, account: "b1", scan: btcScan, transactions: btcRaw)
        let dogePool = try await db.dogecoinSpendableOutputs(walletID: "w1")
        let points = dogePool.map { Outpoint(hash: $0.output.transactionHash, index: $0.output.outputIndex) }
        XCTAssertEqual(points.count, 1)
        for (id, account, network) in [("doge", "a1", "dogecoin"), ("btc", "b1", "bitcoin")] {
            try await db.saveDraft(.init(id: id, walletID: "w1", accountID: account, networkID: network, assetID: network + ":native",
                idempotencyKey: id, recipient: "test", amountAtomic: "1000", state: "draft", createdAt: 1, updatedAt: 1))
        }
        _ = try await db.queueSend("doge", outputs: points)
        let btcPool = try await db.bitcoinSpendableOutputs(walletID: "w1")
        XCTAssertEqual(btcPool.count, 1, "DOGE reservations must not reserve BTC")
        let empty = try await BitcoinDiscovery(query: LedgerQuery(replies: [:])).scan(dogecoin)
        try await commit(db, scan: empty, transactions: [:])
        let btcAfter = try await db.bitcoinSpendableOutputs(walletID: "w1")
        XCTAssertEqual(btcAfter.count, 1, "Spent DOGE must not mark BTC spent")
        _ = try await db.queueSend("btc", outputs: points)
        let reservedBTC = try await db.reservedOutputs(sendID: "btc")
        XCTAssertEqual(Set(reservedBTC.map(\.networkID)), ["bitcoin"])
        let balanceBTC = try await db.balance(accountID: "b1", assetID: "bitcoin:native")
        let balanceDOGE = try await db.balance(accountID: "a1", assetID: "dogecoin:native")
        XCTAssertEqual(balanceBTC?.amountAtomic, "1000"); XCTAssertEqual(balanceDOGE?.amountAtomic, "0")
    }

    func testBitcoinCashAndBitcoinIdenticalOutpointsStaySeparate() async throws {
        // A single uncompressed key has the same locking script on both chains.
        // Identical transaction hashes must still have separate balances/reservations.
        let key = Data(repeating: 0, count: 31) + Data([1])
        let bitcoincash = try BitcoinCashKeys.singleKey(bytes: key, compressed: false)
        let bitcoin = try BitcoinKeys.singleKey(bytes: key, compressed: false)
        let (db, _, _) = try await fixture(network: .bitcoincash, descriptor: bitcoincash)
        try await db.seed(networks: [.init(id: "bitcoin", name: "Bitcoin", family: "utxo", symbol: "BTC", decimals: 8, derivationPath: "imported", logo: "btc", sortOrder: 1)],
                          assets: [.init(id: "bitcoin:native", networkID: "bitcoin", reference: "native", name: "Bitcoin", symbol: "BTC", decimals: 8)])
        let receive = try BitcoinKeys.addresses(branch: bitcoin.branches[0], range: 0..<1)[0]
        try await db.pool.write { sql in
            try AccountRecord(id: "b1", walletID: "w1", networkID: "bitcoin", address: receive.address, derivationPath: "imported").insert(sql)
        }
        try await db.prepareBitcoin(accountID: "b1", descriptor: bitcoin)
        let (bchScan, bchRaw) = try await funding(bitcoincash)
        let (btcScan, btcRaw) = try await funding(bitcoin)
        XCTAssertEqual(bchRaw, btcRaw)
        try await commit(db, scan: bchScan, transactions: bchRaw)
        try await commit(db, account: "b1", scan: btcScan, transactions: btcRaw)
        let bchPool = try await db.bitcoinSpendableOutputs(walletID: "w1", network: .bitcoincash)
        let points = bchPool.map { Outpoint(hash: $0.output.transactionHash, index: $0.output.outputIndex) }
        XCTAssertEqual(points.count, 1)
        for (id, account, network) in [("bch", "a1", "bitcoincash"), ("btc", "b1", "bitcoin")] {
            try await db.saveDraft(.init(id: id, walletID: "w1", accountID: account, networkID: network, assetID: network + ":native",
                idempotencyKey: id, recipient: "test", amountAtomic: "1000", state: "draft", createdAt: 1, updatedAt: 1))
        }
        _ = try await db.queueSend("bch", outputs: points)
        let btcPool = try await db.bitcoinSpendableOutputs(walletID: "w1")
        XCTAssertEqual(btcPool.count, 1, "BCH reservations must not reserve BTC")
        let empty = try await BitcoinDiscovery(query: LedgerQuery(replies: [:])).scan(bitcoincash)
        try await commit(db, scan: empty, transactions: [:])
        let btcAfter = try await db.bitcoinSpendableOutputs(walletID: "w1")
        XCTAssertEqual(btcAfter.count, 1, "Spent BCH must not mark BTC spent")
        _ = try await db.queueSend("btc", outputs: points)
        let reservedBTC = try await db.reservedOutputs(sendID: "btc")
        XCTAssertEqual(Set(reservedBTC.map(\.networkID)), ["bitcoin"])
        let balanceBTC = try await db.balance(accountID: "b1", assetID: "bitcoin:native")
        let balanceBCH = try await db.balance(accountID: "a1", assetID: "bitcoincash:native")
        XCTAssertEqual(balanceBTC?.amountAtomic, "1000"); XCTAssertEqual(balanceBCH?.amountAtomic, "0")
    }

    func testLiveDogecoinDiscoveryDatabaseReopen() async throws {
        guard ProcessInfo.processInfo.environment["OATH_DOGECOIN_LIVE"] == "1" else { throw XCTSkip("Opt-in public-network check") }
        let (db, url, wallet) = try await fixture(network: .dogecoin)
        let pool = ElectrumPool(network: .dogecoin)
        let tip = try await pool.chainTip()
        let scan = try await BitcoinDiscovery(query: pool).scan(wallet)
        let txids = Array(Set(scan.addresses.flatMap { $0.state.unspent.map(\.txid) }))
        let transactions = try await pool.transactions(txids: txids)
        try await commit(db, scan: scan, transactions: transactions, tip: tip.height)
        let reopened = try await OathDatabase.open(at: url)
        let state = try await reopened.bitcoinState(accountID: "a1")
        XCTAssertEqual(state?.descriptor.network, .dogecoin)
        XCTAssertNotNil(state?.lastSuccess)
        let balance = try await reopened.balance(accountID: "a1", assetID: "dogecoin:native")
        XCTAssertEqual(balance?.amountAtomic, String(scan.total))
        await pool.close()
    }

    func testLiveLitecoinDiscoveryDatabaseReopen() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LITECOIN_LIVE"] == "1" else { throw XCTSkip("Opt-in public-network check") }
        let (db, url, wallet) = try await fixture(network: .litecoin)
        let pool = ElectrumPool(network: .litecoin)
        let tip = try await pool.chainTip()
        let scan = try await BitcoinDiscovery(query: pool).scan(wallet)
        let txids = Array(Set(scan.addresses.flatMap { $0.state.unspent.map(\.txid) }))
        let transactions = try await pool.transactions(txids: txids)
        try await commit(db, scan: scan, transactions: transactions, tip: tip.height)
        let reopened = try await OathDatabase.open(at: url)
        let state = try await reopened.bitcoinState(accountID: "a1")
        XCTAssertEqual(state?.descriptor.network, .litecoin)
        XCTAssertNotNil(state?.lastSuccess)
        let balance = try await reopened.balance(accountID: "a1", assetID: "litecoin:native")
        XCTAssertEqual(balance?.amountAtomic, String(scan.total))
        await pool.close()
    }

    func testLiveBitcoinCashDiscoveryDatabaseReopen() async throws {
        guard ProcessInfo.processInfo.environment["OATH_BITCOINCASH_LIVE"] == "1" else { throw XCTSkip("Opt-in public-network check") }
        let (db, url, wallet) = try await fixture(network: .bitcoincash)
        let pool = ElectrumPool(network: .bitcoincash)
        let tip = try await pool.chainTip()
        let scan = try await BitcoinDiscovery(query: pool).scan(wallet)
        let txids = Array(Set(scan.addresses.flatMap { $0.state.unspent.map(\.txid) }))
        let transactions = try await pool.transactions(txids: txids)
        try await commit(db, scan: scan, transactions: transactions, tip: tip.height)
        let reopened = try await OathDatabase.open(at: url)
        let state = try await reopened.bitcoinState(accountID: "a1")
        XCTAssertEqual(state?.descriptor.network, .bitcoincash)
        XCTAssertNotNil(state?.lastSuccess)
        let balance = try await reopened.balance(accountID: "a1", assetID: "bitcoincash:native")
        XCTAssertEqual(balance?.amountAtomic, String(scan.total))
        await pool.close()
    }

    func testEveryTypeAndChangeBranchPersistAndReceiveChoiceDoesNotFilterCoins() async throws {
        let (db, url, descriptor) = try await fixture()
        let (scan, transactions) = try await funding(descriptor)
        try await commit(db, scan: scan, transactions: transactions)
        let before = try await db.bitcoinSpendableOutputs(walletID: "w1")
        XCTAssertEqual(before.count, 8)
        XCTAssertEqual(Set(before.map { $0.derivation.type }), Set(BitcoinAddressType.allCases))
        XCTAssertEqual(Set(before.map { $0.derivation.change }), [0,1])
        XCTAssertTrue(before.allSatisfy { !$0.previousTransaction.isEmpty })
        for type in BitcoinAddressType.allCases {
            let address = try await db.bitcoinReceiveAddress(accountID: "a1", type: type)
            XCTAssertEqual(address.index, 1)
            let reopened = try await OathDatabase.open(at: url)
            let again = try await reopened.bitcoinReceiveAddress(accountID: "a1")
            XCTAssertEqual(again, address)
            try await reopened.saveReceive(.init(id: UUID().uuidString, accountID: "a1", networkID: "bitcoin", assetID: "bitcoin:native", address: address.address, state: "open", createdAt: Date.now.timeIntervalSince1970))
            let pool = try await reopened.bitcoinSpendableOutputs(walletID: "w1")
            XCTAssertEqual(pool, before)
        }
        let balance = try await db.balance(accountID: "a1", assetID: "bitcoin:native")
        XCTAssertEqual(balance?.amountAtomic, "8000")
        let history = try await db.bitcoinHistory(accountID: "a1")
        XCTAssertEqual(history.count, 1)
        let missing = try await db.bitcoinMissingTransactions(accountID: "a1", txids: Set(transactions.keys))
        XCTAssertTrue(missing.isEmpty)
    }

    func testLitecoinEveryTypeAndChangeBranchPersistAndReceiveChoiceDoesNotFilterCoins() async throws {
        let (db, url, descriptor) = try await fixture(network: .litecoin)
        let (scan, transactions) = try await funding(descriptor)
        try await commit(db, scan: scan, transactions: transactions)
        let before = try await db.bitcoinSpendableOutputs(walletID: "w1", network: .litecoin)
        XCTAssertEqual(before.count, 8)
        XCTAssertEqual(Set(before.map { $0.derivation.type }), Set(BitcoinAddressType.allCases))
        XCTAssertEqual(Set(before.map { $0.derivation.change }), [0,1])
        XCTAssertTrue(before.allSatisfy { !$0.previousTransaction.isEmpty })
        for type in BitcoinAddressType.allCases {
            let address = try await db.bitcoinReceiveAddress(accountID: "a1", type: type)
            XCTAssertEqual(address.index, 1)
            let reopened = try await OathDatabase.open(at: url)
            let again = try await reopened.bitcoinReceiveAddress(accountID: "a1")
            XCTAssertEqual(again, address)
            try await reopened.saveReceive(.init(id: UUID().uuidString, accountID: "a1", networkID: "litecoin", assetID: "litecoin:native", address: address.address, state: "open", createdAt: Date.now.timeIntervalSince1970))
            let pool = try await reopened.bitcoinSpendableOutputs(walletID: "w1", network: .litecoin)
            XCTAssertEqual(pool, before)
        }
        let balance = try await db.balance(accountID: "a1", assetID: "litecoin:native")
        XCTAssertEqual(balance?.amountAtomic, "8000")
        let history = try await db.bitcoinHistory(accountID: "a1")
        XCTAssertEqual(history.count, 1)
        let missing = try await db.bitcoinMissingTransactions(accountID: "a1", txids: Set(transactions.keys))
        XCTAssertTrue(missing.isEmpty)
    }

    func testFailureAndStaleResponseCannotEraseLastSuccessfulSnapshot() async throws {
        let (db, _, descriptor) = try await fixture(); let (scan, transactions) = try await funding(descriptor)
        try await commit(db, scan: scan, transactions: transactions)
        let old = try await db.beginBitcoinScan(accountID: "a1")
        let current = try await db.beginBitcoinScan(accountID: "a1")
        do { try await db.commitBitcoinScan(accountID: "a1", scanID: old, scan: scan, transactions: transactions, tipHeight: 800_200); XCTFail("Stale scan committed") }
        catch { XCTAssertEqual(error as? StoreError, .staleSync) }
        try await db.failBitcoinScan(accountID: "a1", scanID: current, code: "timeout")
        let balance = try await db.balance(accountID: "a1", assetID: "bitcoin:native")
        XCTAssertEqual(balance?.amountAtomic, "8000")
        do { _ = try await db.bitcoinSpendableOutputs(walletID: "w1"); XCTFail("Failed scan left pool spendable") }
        catch { XCTAssertEqual(error as? StoreError, .staleSync) }
        try await commit(db, scan: scan, transactions: [:]) // Raw transactions restored from cache.
        do { _ = try await db.bitcoinSpendableOutputs(walletID: "w1", now: .now.addingTimeInterval(180)); XCTFail("Expired pool accepted") }
        catch { XCTAssertEqual(error as? StoreError, .staleSync) }
    }

    func testRepeatedOutageKeepsBalanceAndHistoryAcrossReopenForEveryChain() async throws {
        for network in UTXONetwork.allCases {
            let (db, url, descriptor) = try await fixture(network: network)
            let (scan, transactions) = try await funding(descriptor)
            try await commit(db, scan: scan, transactions: transactions)
            let initialHistory = try await db.bitcoinHistory(accountID: "a1")
            let initialOutputs = try await db.bitcoinSpendableOutputs(walletID: "w1", network: network)
            XCTAssertFalse(initialHistory.isEmpty)
            XCTAssertFalse(initialOutputs.isEmpty)

            for code in ["timeout", "timeout", "disconnected"] {
                let ticket = try await db.beginBitcoinScan(accountID: "a1")
                try await db.failBitcoinScan(accountID: "a1", scanID: ticket, code: code)
            }
            let reopened = try await OathDatabase.open(at: url)
            let balance = try await reopened.balance(accountID: "a1", assetID: network.rawValue + ":native")
            let history = try await reopened.bitcoinHistory(accountID: "a1")
            XCTAssertEqual(balance?.amountAtomic, String(scan.total))
            XCTAssertEqual(history, initialHistory)
            do {
                _ = try await reopened.bitcoinSpendableOutputs(walletID: "w1", network: network)
                XCTFail("Cached display data must not make stale outputs spendable")
            } catch { XCTAssertEqual(error as? StoreError, .staleSync) }

            // A later successful refresh verifies the same funding from the
            // durable raw-transaction cache and restores spendability.
            try await commit(reopened, scan: scan, transactions: [:])
            let recovered = try await reopened.bitcoinSpendableOutputs(walletID: "w1", network: network)
            XCTAssertEqual(recovered, initialOutputs)
            let otherBalance = try await reopened.balance(accountID: "a2", assetID: network.rawValue + ":native")
            XCTAssertNil(otherBalance, "Recovery must not populate another wallet")
        }
    }

    func testUnverifiedFundingTransactionRollsBackWholeCommit() async throws {
        let (db, _, descriptor) = try await fixture(); let (scan, _) = try await funding(descriptor)
        do { try await commit(db, scan: scan, transactions: [:]); XCTFail("Unverified output committed") } catch { }
        let balance = try await db.balance(accountID: "a1", assetID: "bitcoin:native")
        let history = try await db.bitcoinHistory(accountID: "a1")
        XCTAssertNil(balance); XCTAssertTrue(history.isEmpty)
    }

    func testCoinbaseMaturityAndCrossWalletReservations() async throws {
        let (db, _, descriptor) = try await fixture(); let (scan, transactions) = try await funding(descriptor, coinbase: true)
        try await commit(db, scan: scan, transactions: transactions, tip: 800_098)
        let immature = try await db.bitcoinSpendableOutputs(walletID: "w1"); XCTAssertTrue(immature.isEmpty)
        try await commit(db, scan: scan, transactions: transactions, tip: 800_099)
        try await commit(db, account: "a2", scan: scan, transactions: transactions, tip: 800_099)
        let mature = try await db.bitcoinSpendableOutputs(walletID: "w1"); XCTAssertEqual(mature.count, 8)
        let outputs = mature.map { Outpoint(hash: $0.output.transactionHash, index: $0.output.outputIndex) }
        try await db.saveDraft(draft("first")); try await db.saveDraft(draft("second", wallet: 2))
        _ = try await db.queueSend("first", outputs: outputs)
        do { _ = try await db.queueSend("second", outputs: outputs); XCTFail("Coin reserved twice") }
        catch { XCTAssertEqual(error as? StoreError, .reservationConflict) }
        try await commit(db, scan: scan, transactions: [:], tip: 800_100)
        let reserved = try await db.reservedOutputs(sendID: "first"); XCTAssertEqual(reserved.count, 8)
        let available = try await db.bitcoinSpendableOutputs(walletID: "w1"); XCTAssertTrue(available.isEmpty)
    }

    func testReservationCombinesDifferentBitcoinAccountsInOneWallet() async throws {
        let (db, _, first) = try await fixture()
        let second = try BitcoinKeys.wallet(seed: Data(0..<32), account: 1)
        let receive = try BitcoinKeys.addresses(branch: second.branches[0], range: 0..<1)[0]
        try await db.pool.write { sql in
            try AccountRecord(id: "a1-next", walletID: "w1", networkID: "bitcoin", address: receive.address, derivationPath: receive.path, accountIndex: 1).insert(sql)
        }
        try await db.prepareBitcoin(accountID: "a1-next", descriptor: second)
        let (scan1, raw1) = try await funding(first); let (scan2, raw2) = try await funding(second)
        try await commit(db, scan: scan1, transactions: raw1)
        try await commit(db, account: "a1-next", scan: scan2, transactions: raw2)
        let coins = try await db.bitcoinSpendableOutputs(walletID: "w1")
        XCTAssertEqual(coins.count, 16); XCTAssertEqual(Set(coins.map { $0.output.accountID }), ["a1", "a1-next"])
        try await db.saveDraft(draft("combined"))
        _ = try await db.queueSend("combined", outputs: coins.map { .init(hash: $0.output.transactionHash, index: $0.output.outputIndex) })
        let reserved = try await db.reservedOutputs(sendID: "combined"); XCTAssertEqual(reserved.count, 16)
        XCTAssertEqual(Set(reserved.map(\.accountID)), ["a1", "a1-next"])
    }

    func testSpentOutputsDisappearAndResetBlocksLateBitcoinWrites() async throws {
        let (db, _, descriptor) = try await fixture(); let (scan, raw) = try await funding(descriptor)
        try await commit(db, scan: scan, transactions: raw)
        let empty = try await BitcoinDiscovery(query: LedgerQuery(replies: [:])).scan(descriptor)
        try await commit(db, scan: empty, transactions: [:])
        let coins = try await db.bitcoinSpendableOutputs(walletID: "w1"); XCTAssertTrue(coins.isEmpty)
        let balance = try await db.balance(accountID: "a1", assetID: "bitcoin:native"); XCTAssertEqual(balance?.amountAtomic, "0")
        let next = try await db.bitcoinReceiveAddress(accountID: "a1"); XCTAssertEqual(next.index, 1, "Previously used addresses are never recycled after a reorg")
        _ = try await db.beginWalletReset()
        do { _ = try await db.beginBitcoinScan(accountID: "a1"); XCTFail("Late scan started during reset") } catch { }
        do { _ = try await db.bitcoinReceiveAddress(accountID: "a1", type: .legacy); XCTFail("Address written during reset") } catch { }
    }

    func testLiveDiscoveryDatabaseCommitAndReopen() async throws {
        guard ProcessInfo.processInfo.environment["OATH_BITCOIN_LIVE"] == "1" else { throw XCTSkip("Live network check not requested") }
        let (db, url, descriptor) = try await fixture()
        let pool = ElectrumPool()
        let scan = try await BitcoinDiscovery(query: pool, maximumIndex: 200).scan(descriptor)
        let transactions = try await pool.transactions(txids: Array(Set(scan.addresses.flatMap { $0.state.unspent.map(\.txid) })))
        let tip = try await pool.chainTip()
        try await commit(db, scan: scan, transactions: transactions, tip: tip.height)
        await pool.close()
        let reopened = try await OathDatabase.open(at: url)
        let state = try await reopened.bitcoinState(accountID: "a1")
        let balance = try await reopened.balance(accountID: "a1", assetID: "bitcoin:native")
        XCTAssertEqual(balance?.amountAtomic, String(scan.total))
        XCTAssertNotNil(state?.lastSuccess); XCTAssertNil(state?.failure)
        XCTAssertEqual(state?.descriptor.types, BitcoinAddressType.allCases)
        XCTAssertEqual(Set(scan.addresses.map { $0.address.branchID }).count, 8)
    }

    func testResetRemovesBitcoinLedgerAndRetainsPricesAndPreferences() async throws {
        let (db, _, descriptor) = try await fixture(); let (scan, transactions) = try await funding(descriptor)
        try await commit(db, scan: scan, transactions: transactions)
        try await db.setSetting("currency", value: "JOD")
        try await db.savePrices([.init(assetID: "bitcoin:native", currency: "USD", value: "50000", observedAt: 1, source: "fixture")])
        let reset = try await db.beginWalletReset()
        try await db.eraseWalletData(resetID: reset); try await db.finishWalletReset(resetID: reset)
        let state = try await db.bitcoinState(accountID: "a1"); XCTAssertNil(state)
        let settings = try await db.settings(); XCTAssertEqual(settings["currency"], "JOD")
        let count = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM prices") }
        XCTAssertEqual(count, 1)
    }
}
