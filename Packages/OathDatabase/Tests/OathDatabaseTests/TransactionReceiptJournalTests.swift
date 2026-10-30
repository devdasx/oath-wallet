import Foundation
import XCTest
@testable import OathAnkr
@testable import OathDatabase

/// Exercise the real signing/journaling boundary without a provider, then the
/// same durable receipt projection used by the transaction-details screen.
@MainActor private func assertLocalReceipt(_ db: OathDatabase, sender: String, recipient: String,
                                          file: StaticString = #filePath, line: UInt = #line) async throws {
    let fetched = try await db.send("receipt")
    let send = try XCTUnwrap(fetched, file: file, line: line)
    let id = try XCTUnwrap(send.transactionID, file: file, line: line)
    let value = try await db.transactionDetails(accountID: "a1", transactionID: id)
    let receipt = try XCTUnwrap(value, file: file, line: line)
    XCTAssertEqual(receipt.fromAddresses, [sender], file: file, line: line)
    XCTAssertEqual(receipt.toAddresses, [recipient], file: file, line: line)
    XCTAssertEqual(receipt.transaction.state, "pending", file: file, line: line)
    XCTAssertEqual(receipt.historyEntries.first?.amountAtomic, send.amountAtomic, file: file, line: line)
    let otherWallet = try await db.transactionDetails(accountID: "a2", transactionID: id)
    XCTAssertNil(otherWallet, "An identical address in another wallet is not this send", file: file, line: line)
}

extension EVMSendJournalTests {
    func testImmediateReceiptAddressesBeforeIndexerAndAfterReopen() async throws {
        for network in EVMSendNetwork.allCases where !network.isTestnet {
            let (db, folder, plan) = try await fixture(network: network)
            defer { try? FileManager.default.removeItem(at: folder) }
            try await draft("receipt", plan: plan, db: db)
            try await db.queueEVMSend(sendID: "receipt", plan: plan)
            let signed = try EVMSendCrypto.sign(plan, privateKey: key)
            try await db.journalEVMSignature(sendID: "receipt", signed: signed)
            try await assertLocalReceipt(db, sender: plan.sender, recipient: plan.recipient)
            _ = try await db.transitionSend("receipt", from: "signed", to: "broadcast")
            let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
            try await assertLocalReceipt(reopened, sender: plan.sender, recipient: plan.recipient)
        }
    }
}

extension ArcSendJournalTests {
    func testImmediateReceiptAddressesBeforeIndexerAndAfterReopen() async throws {
        let (db, folder, plan) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await draft("receipt", plan: plan, db: db)
        try await db.queueArcSend(sendID: "receipt", plan: plan)
        let signed = try ArcSendCrypto.sign(plan, privateKey: key)
        try await db.journalArcSignature(sendID: "receipt", signed: signed)
        try await assertLocalReceipt(db, sender: plan.sender, recipient: plan.recipient)
        _ = try await db.transitionSend("receipt", from: "signed", to: "broadcast")
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        try await assertLocalReceipt(reopened, sender: plan.sender, recipient: plan.recipient)
    }
}

extension SolanaSendJournalTests {
    func testImmediateReceiptAddressesBeforeIndexerAndAfterReopen() async throws {
        let (db, folder, plan) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await draft("receipt", plan: plan, db: db)
        try await db.queueSolanaSend(sendID: "receipt", plan: plan)
        let signed = try SolanaSendCrypto.sign(plan, privateKey: key)
        try await db.journalSolanaSignature(sendID: "receipt", signed: signed)
        try await assertLocalReceipt(db, sender: plan.sender, recipient: plan.recipient)
        _ = try await db.transitionSend("receipt", from: "signed", to: "broadcast")
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        try await assertLocalReceipt(reopened, sender: plan.sender, recipient: plan.recipient)
    }
}

extension StellarSendJournalTests {
    func testImmediateReceiptAddressesBeforeIndexerAndAfterReopen() async throws {
        let (db, folder, plan) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await draft("receipt", plan: plan, db: db)
        try await db.queueStellarSend(sendID: "receipt", plan: plan)
        let signed = try StellarSendCrypto.sign(plan, privateKey: key)
        try await db.journalStellarSignature(sendID: "receipt", signed: signed)
        try await assertLocalReceipt(db, sender: plan.sender, recipient: plan.recipient)
        _ = try await db.transitionSend("receipt", from: "signed", to: "broadcast")
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await assertLocalReceipt(reopened, sender: plan.sender, recipient: plan.recipient)
    }
}

extension TronSendJournalTests {
    func testImmediateReceiptAddressesBeforeIndexerAndAfterReopen() async throws {
        let (db, folder, plan) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await draft("receipt", plan: plan, db: db)
        try await db.queueTronSend(sendID: "receipt", plan: plan)
        let signed = try TronSendCrypto.sign(plan, privateKey: key)
        try await db.journalTronSignature(sendID: "receipt", signed: signed)
        try await assertLocalReceipt(db, sender: plan.sender, recipient: plan.recipient)
        _ = try await db.transitionSend("receipt", from: "signed", to: "broadcast")
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await assertLocalReceipt(reopened, sender: plan.sender, recipient: plan.recipient)
    }
}

extension TonSendJournalTests {
    func testImmediateReceiptAddressesBeforeIndexerAndAfterReopen() async throws {
        for token in [false, true] {
            let (db, folder, plan) = try await fixture(token: token)
            defer { try? FileManager.default.removeItem(at: folder) }
            try await draft("receipt", plan: plan, db: db)
            try await db.queueTonSend(sendID: "receipt", plan: plan)
            let signed = try TonSendCrypto.sign(plan, privateKey: key)
            try await db.journalTonSignature(sendID: "receipt", signed: signed)
            try await assertLocalReceipt(db, sender: plan.sender, recipient: plan.recipient)
            _ = try await db.transitionSend("receipt", from: "signed", to: "broadcast")
            let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
            try await assertLocalReceipt(reopened, sender: plan.sender, recipient: plan.recipient)
        }
    }
}

extension NearSendJournalTests {
    func testImmediateReceiptAddressesBeforeIndexerAndAfterReopen() async throws {
        let (db, folder, plan) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await draft("receipt", plan: plan, db: db)
        try await db.queueNearSend(sendID: "receipt", plan: plan)
        let signed = try NearSendCrypto.sign(plan, privateKey: key)
        try await db.journalNearSignature(sendID: "receipt", signed: signed)
        try await assertLocalReceipt(db, sender: plan.sender, recipient: plan.recipient)
        _ = try await db.transitionSend("receipt", from: "signed", to: "broadcast")
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await assertLocalReceipt(reopened, sender: plan.sender, recipient: plan.recipient)
    }
}

extension SuiSendJournalTests {
    func testImmediateReceiptAddressesBeforeIndexerAndAfterReopen() async throws {
        let (db, folder, plan) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await draft("receipt", plan: plan, db: db)
        try await db.queueSuiSend(sendID: "receipt", plan: plan)
        let signed = try SuiSendCrypto.sign(plan, privateKey: key)
        try await db.journalSuiSignature(sendID: "receipt", signed: signed)
        try await assertLocalReceipt(db, sender: plan.sender, recipient: plan.recipient)
        _ = try await db.transitionSend("receipt", from: "signed", to: "broadcast")
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await assertLocalReceipt(reopened, sender: plan.sender, recipient: plan.recipient)
    }
}

extension AptosSendJournalTests {
    func testImmediateReceiptAddressesBeforeIndexerAndAfterReopen() async throws {
        let (db, folder, plan) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await draft("receipt", plan: plan, db: db)
        try await db.queueAptosSend(sendID: "receipt", plan: plan)
        let signed = try AptosSendCrypto.sign(plan, privateKey: key)
        try await db.journalAptosSignature(sendID: "receipt", signed: signed)
        try await assertLocalReceipt(db, sender: plan.sender, recipient: plan.recipient)
        _ = try await db.transitionSend("receipt", from: "signed", to: "broadcast")
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        try await assertLocalReceipt(reopened, sender: plan.sender, recipient: plan.recipient)
    }
}

extension XrplSendJournalTests {
    func testImmediateReceiptAddressesBeforeIndexerAndAfterReopen() async throws {
        let (db, folder, plan) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await draft("receipt", plan: plan, db: db)
        try await db.queueXrplSend(sendID: "receipt", plan: plan)
        let signed = try XrplSendCrypto.sign(plan, privateKey: key)
        try await db.journalXrplSignature(sendID: "receipt", signed: signed)
        try await assertLocalReceipt(db, sender: plan.sender, recipient: plan.recipient)
        _ = try await db.transitionSend("receipt", from: "signed", to: "broadcast")
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await assertLocalReceipt(reopened, sender: plan.sender, recipient: plan.recipient)
    }
}

extension ThorchainSendJournalTests {
    func testImmediateReceiptAddressesBeforeIndexerAndAfterReopen() async throws {
        let (db, folder, plan) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await draft("receipt", plan: plan, db: db)
        try await db.queueThorchainSend(sendID: "receipt", plan: plan)
        let signed = try ThorchainSendCrypto.sign(plan, privateKey: key)
        try await db.journalThorchainSignature(sendID: "receipt", signed: signed)
        try await assertLocalReceipt(db, sender: plan.sender, recipient: plan.recipient)
        _ = try await db.transitionSend("receipt", from: "signed", to: "broadcast")
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        try await assertLocalReceipt(reopened, sender: plan.sender, recipient: plan.recipient)
    }
}

