import XCTest
import GRDB
import OathBitcoin
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class SelfTransferFeeTests: XCTestCase {
    private func fixture(_ network: String, family: String, amount: String = "50000000", fee: String? = "1234", owned: Bool = true) async throws -> (OathDatabase, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SelfFee-" + UUID().uuidString)
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        try await db.seed(networks: [.init(id: network, name: network, family: family, symbol: "COIN", decimals: 8, derivationPath: "", logo: "", sortOrder: 0)], assets: [
            .init(id: network + ":native", networkID: network, reference: "native", name: "Coin", symbol: "COIN", decimals: 8),
            .init(id: network + ":token", networkID: network, reference: "token", name: "Token", symbol: "TOK", decimals: 6)])
        try await db.importWalletIfNeeded(.init(id: "w", name: "Fixture", kind: "watchOnly", vaultReference: "fixture", createdAt: 1), accounts: [
            .init(id: "a", walletID: "w", networkID: network, address: "0x1234", derivationPath: "")])
        try await db.pool.write { sql in
            let tx = TransactionRecord(id: "tx", networkID: network, hash: "tx", state: "confirmed", timestamp: 10, feeAtomic: fee, updatedAt: 10)
            try tx.insert(sql)
            try ActivityRecord(id: "row", walletID: "w", accountID: "a", networkID: network, transactionID: "tx", assetID: network + ":native", direction: "self", amountAtomic: amount, counterparty: "0x1234", timestamp: 10).insert(sql)
            try OathDatabase.saveTransactionEvidence(accountID: "a", tx: tx, keys: [], returnsToWallet: owned, db: sql)
        }
        return (db, folder)
    }

    func testEveryUTXOAndEVMNetworkUsesFeeWithoutRewritingPrincipal() async throws {
        let networks = UTXONetwork.allCases.map { ($0.rawValue, "utxo") }
            + (AnkrChain.allCases.map(\.networkID) + ["arc", "robinhood", "hyperevm", "unichain", "monad"]).map { ($0, "evm") }
        for (network, family) in networks {
            let (db, folder) = try await fixture(network, family: family)
            defer { try? FileManager.default.removeItem(at: folder) }
            let general = try await db.history(walletID: "w")
            let asset = try await db.assetHistory(walletID: "w", accountID: "a", assetID: network + ":native")
            let chain = try await db.chainHistory(walletID: "w", currency: "USD")
            let details = try await db.transactionDetails(accountID: "a", transactionID: "tx")
            for entry in general + asset + chain.map(\.entry) + (details?.historyEntries ?? []) {
                XCTAssertEqual(entry.amountAtomic, "50000000", network)
                XCTAssertEqual(entry.displayAmountAtomic, "1234", network)
                XCTAssertEqual(entry.displayDirection, "outgoing", network)
                XCTAssertEqual(entry.direction, "self", network)
                XCTAssertEqual(entry.updatingState("pending").displayAmountAtomic, "1234")
            }
            XCTAssertEqual(general.count, 1, network)
            let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
            let cached = try await reopened.history(walletID: "w")
            XCTAssertEqual(cached.first?.displayAmountAtomic, "1234")
        }
    }

    func testMissingFeeIsUnknownAndObservationUpdatesWhenReceiptArrives() async throws {
        let (db, folder) = try await fixture("bitcoin", family: "utxo", fee: nil)
        defer { try? FileManager.default.removeItem(at: folder) }
        var stream = db.observeHistory(walletID: "w").makeAsyncIterator()
        var detailStream = db.observeTransactionDetails(accountID: "a", transactionID: "tx", currency: "USD").makeAsyncIterator()
        let initialDetail = try await detailStream.next()
        XCTAssertNil(initialDetail??.historyEntries.first?.displayAmountAtomic)
        let initial = try await stream.next()
        XCTAssertEqual(initial?.first?.usesSelfTransferFee, true)
        XCTAssertNil(initial?.first?.displayAmountAtomic)
        try await db.pool.write { try $0.execute(sql: "UPDATE transactions SET feeAtomic='9007199254740993' WHERE id='tx'") }
        let updated = try await stream.next()
        XCTAssertEqual(updated?.first?.displayAmountAtomic, "9007199254740993")
        let updatedDetail = try await detailStream.next()
        XCTAssertEqual(updatedDetail??.historyEntries.first?.displayAmountAtomic, "9007199254740993")
    }

    func testExternalTransfersTokensAndCollaborativeUTXOsDoNotUseNativeFee() async throws {
        let (db, folder) = try await fixture("bitcoin", family: "utxo", owned: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        var rows = try await db.history(walletID: "w")
        XCTAssertNil(rows.first?.usesSelfTransferFee)
        try await db.pool.write { try $0.execute(sql: "UPDATE activity SET direction='outgoing' WHERE id='row'") }
        rows = try await db.history(walletID: "w")
        XCTAssertEqual(rows.first?.displayAmountAtomic, "50000000")
        try await db.pool.write { sql in
            try sql.execute(sql: "UPDATE activity SET direction='self', assetID='bitcoin:token' WHERE id='row'")
            try sql.execute(sql: "INSERT INTO trackedAssets(accountID,assetID,networkID,addedAt) VALUES('a','bitcoin:token','bitcoin',1)")
        }
        rows = try await db.history(walletID: "w")
        XCTAssertEqual(rows.first?.displayAmountAtomic, "50000000")
        XCTAssertNil(rows.first?.usesSelfTransferFee)
    }

    func testAccountChainsRequireOwnerFeeEvidence() async throws {
        for network in ["solana", "stellar", "xrpl", "aptos", "near"] {
            for owned in [true, false] {
                let (db, folder) = try await fixture(network, family: "account", amount: "0")
                defer { try? FileManager.default.removeItem(at: folder) }
                let payer = owned ? "0x1234" : "0x5678"
                try await db.pool.write { sql in
                    switch network {
                    case "solana":
                        let raw = Data("{\"transaction\":{\"message\":{\"accountKeys\":[\"\(payer)\"]}}}".utf8)
                        let receipt = SolanaTransaction(signature: "tx", slot: 1, timestamp: 10, failed: false, fee: "1234", changes: [], tokenAccounts: [], raw: raw)
                        try sql.execute(sql: "INSERT INTO solanaTransactions(accountID,owner,signature,detail) VALUES('a','0x1234','tx',?)", arguments: [try JSONEncoder().encode(receipt)])
                        try sql.execute(sql: "INSERT INTO solanaActivity(activityID,owner) VALUES('row','0x1234')")
                    case "stellar":
                        if owned {
                            let event = StellarEvent(id: "fee", hash: "tx", checkpoint: 1, timestamp: 10, reference: "native", token: nil, amount: "1234", direction: "outgoing", kind: "fee", successful: true, counterparty: nil, raw: .null)
                            try sql.execute(sql: "INSERT INTO stellarEvents(accountID,id,hash,detail) VALUES('a','fee','tx',?)", arguments: [try JSONEncoder().encode(event)])
                        }
                    case "xrpl":
                        let raw = Data("{\"tx_json\":{\"Account\":\"\(payer)\"}}".utf8)
                        let receipt = XrplTransaction(hash: "tx", checkpoint: 1, timestamp: 10, failed: false, fee: "1234", owner: "0x1234", counterparty: nil, movements: [], raw: raw)
                        try sql.execute(sql: "INSERT INTO xrplTransactions(accountID,hash,checkpoint,detail,unresolved) VALUES('a','tx',1,?,0)", arguments: [try JSONEncoder().encode(receipt)])
                    case "aptos":
                        let raw = Data("{\"receipt\":{\"signature\":{\"fee_payer_address\":\"\(payer)\"}}}".utf8)
                        let receipt = AptosTransaction(hash: "tx", version: 1, timestamp: 10, failed: false, fee: "1234", sender: "0x1234", events: [], raw: raw)
                        try sql.execute(sql: "INSERT INTO aptosTransactions(accountID,hash,version,detail) VALUES('a','tx',1,?)", arguments: [try JSONEncoder().encode(receipt)])
                    default:
                        try sql.execute(sql: "UPDATE activity SET counterparty=? WHERE id='row'", arguments: [payer])
                    }
                }
                let rows = try await db.history(walletID: "w")
                XCTAssertEqual(rows.count, 1, network)
                XCTAssertEqual(rows.first?.usesSelfTransferFee == true, owned, network)
                XCTAssertEqual(rows.first?.displayAmountAtomic, owned ? "1234" : "0", network)
            }
        }
    }

    func testDetailKeepsAccountScopedFeeInsteadOfGlobalFee() async throws {
        let (db, folder) = try await fixture("stellar", family: "account", amount: "0", fee: "999")
        defer { try? FileManager.default.removeItem(at: folder) }
        let event = StellarEvent(id: "fee", hash: "tx", checkpoint: 1, timestamp: 10, reference: "native", token: nil, amount: "12", direction: "outgoing", kind: "fee", successful: true, counterparty: nil, raw: .null)
        try await db.pool.write { sql in
            try sql.execute(sql: "INSERT INTO stellarEvents(accountID,id,hash,detail) VALUES('a','fee','tx',?)", arguments: [try JSONEncoder().encode(event)])
        }
        let details = try await db.transactionDetails(accountID: "a", transactionID: "tx")
        XCTAssertEqual(details?.transaction.feeAtomic, "999")
        XCTAssertEqual(details?.historyEntries.first?.displayAmountAtomic, "12")
        XCTAssertEqual(details?.historyEntries.first?.displayDirection, "outgoing")
    }

    func testSuiSelfTransferOnlyChargesItsOwnGasWithoutChargingSponsorOrRebate() async throws {
        for (fee, netGas) in [("12" as String?, "12"), (nil, "12"), ("0", "-12")] {
            let (db, folder) = try await fixture("sui", family: "account", amount: "0")
            defer { try? FileManager.default.removeItem(at: folder) }
            let receipt = SuiTransaction(hash: "tx", checkpoint: 1, timestamp: 10, failed: false, fee: fee, netGas: netGas, sender: "0x1234", owner: "0x1234", movements: [], raw: Data("{}".utf8))
            let data = try JSONEncoder().encode(receipt)
            try await db.pool.write { sql in
                try sql.execute(sql: "INSERT INTO suiTransactions(accountID,hash,checkpoint,detail,unresolved) VALUES('a','tx',1,?,0)", arguments: [data])
            }
            let rows = try await db.history(walletID: "w")
            XCTAssertEqual(rows.first?.displayAmountAtomic, fee != nil && !netGas.hasPrefix("-") ? "12" : "0")
            XCTAssertEqual(rows.first?.usesSelfTransferFee == true, fee != nil && !netGas.hasPrefix("-"))
        }
    }
}
