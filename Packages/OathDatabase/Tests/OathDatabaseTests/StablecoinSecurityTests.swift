import Foundation
import XCTest
import OathAnkr
@testable import OathDatabase

@MainActor final class StablecoinSecurityTests: XCTestCase {
    let account = StablecoinRestrictionAccount(network: "ethereum", address: "0x0000000000000000000000000000000000000001")
    func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StablecoinSecurity-" + UUID().uuidString).appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: [.init(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH", decimals: 18,
                                         derivationPath: "fixture", logo: "ethereum", sortOrder: 0)], assets: [])
        for id in ["first", "second"] {
            try await addWallet(id, db)
        }
        return (db, url)
    }
    func addWallet(_ id: String, _ db: OathDatabase) async throws {
        try await db.importWalletIfNeeded(.init(id: id, name: "Fixture", kind: "imported", vaultReference: "fixture-" + id, createdAt: 1),
                                         accounts: [.init(id: id + "-account", walletID: id, networkID: "ethereum", address: account.address, derivationPath: "fixture")])
    }
    func testClaimIsAtomicAndDurableAcrossReopen() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let account = self.account
        async let first = db.claimRestrictionChecks(walletID: "first", account: account)
        async let second = db.claimRestrictionChecks(walletID: "first", account: account)
        let combined = try await first + second
        XCTAssertEqual(combined.count, 2)
        let reopened = try await OathDatabase.open(at: url)
        let again = try await reopened.claimRestrictionChecks(walletID: "first", account: account)
        XCTAssertTrue(again.isEmpty, "An interrupted attempt must not restart")
        let rows = try await reopened.pool.read { db in
            try String.fetchAll(db, sql: "SELECT outcome FROM stablecoinSecurityChecks")
        }
        XCTAssertEqual(rows, ["unavailable", "unavailable"], "Claimed attempts are unknown, never a clean result")
    }
    func testFindingsAndAcknowledgementAreWalletScoped() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tokens = try await db.claimRestrictionChecks(walletID: "first", account: account)
        try await db.saveRestrictionChecks(walletID: "first", account: account, results: tokens.map { .init(token: $0, outcome: .restricted) })
        let first = try await db.stablecoinSecurityState(walletID: "first")
        let second = try await db.stablecoinSecurityState(walletID: "second")
        XCTAssertFalse(first.acknowledged); XCTAssertEqual(first.restricted.count, 2)
        XCTAssertFalse(second.acknowledged); XCTAssertTrue(second.restricted.isEmpty)
        try await db.acknowledgeStablecoinSecurity(walletID: "first")
        let reopened = try await OathDatabase.open(at: url)
        let acknowledged = try await reopened.stablecoinSecurityState(walletID: "first")
        XCTAssertTrue(acknowledged.acknowledged)
        let independent = try await reopened.claimRestrictionChecks(walletID: "second", account: account)
        XCTAssertEqual(independent.count, 2, "Same address in a separate import has its own one-time check")
    }
    func testDeletingWalletRemovesCheckAndNoticeButRenameDoesNot() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try await db.claimRestrictionChecks(walletID: "first", account: account)
        try await db.acknowledgeStablecoinSecurity(walletID: "first")
        try await db.customizeWallet("first", name: "Renamed", colorHex: nil)
        let before = try await db.stablecoinSecurityState(walletID: "first")
        XCTAssertTrue(before.acknowledged)
        try await db.deleteWalletMetadata("first")
        try await addWallet("first", db)
        let after = try await db.stablecoinSecurityState(walletID: "first")
        XCTAssertFalse(after.acknowledged)
        let fresh = try await db.claimRestrictionChecks(walletID: "first", account: account)
        XCTAssertEqual(fresh.count, 2)
    }
    func testDuplicateHomeTasksAndCancelledWaiterDoNotRepeatNetworkWork() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = SecurityScanTransport()
        let checker = StablecoinRestrictionCheck(endpoints: ["ethereum": URL(string: "https://fixture.example")!], transport: transport)
        let scan = StablecoinSecurityScan()
        let account = self.account
        let caller = Task { await scan.run(database: db, walletID: "first", accounts: [account, account], checker: checker) }
        caller.cancel() // Models SwiftUI cancellation during navigation.
        async let duplicate: Void = scan.run(database: db, walletID: "first", accounts: [account], checker: checker)
        await caller.value; await duplicate
        let firstCount = await transport.calls
        XCTAssertEqual(firstCount, 3) // one network identity + USDT + USDC
        let result = try await db.stablecoinSecurityState(walletID: "first")
        XCTAssertEqual(result.restricted.count, 2)
        let reopened = try await OathDatabase.open(at: url)
        await scan.run(database: reopened, walletID: "first", accounts: [account], checker: checker)
        let afterReopen = await transport.calls
        XCTAssertEqual(afterReopen, firstCount)
    }
    func testFailedProviderIsNotRetriedOrShownAsRestriction() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = SecurityScanTransport(fail: true)
        let checker = StablecoinRestrictionCheck(endpoints: ["ethereum": URL(string: "https://fixture.example")!], transport: transport)
        let scan = StablecoinSecurityScan()
        for _ in 0..<3 { await scan.run(database: db, walletID: "first", accounts: [account], checker: checker) }
        let count = await transport.calls
        XCTAssertEqual(count, 1)
        let state = try await db.stablecoinSecurityState(walletID: "first")
        XCTAssertTrue(state.restricted.isEmpty)
    }
    func testUnsupportedChainsAndDeletedWalletsCannotCreateFindings() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let unsupported = try await db.claimRestrictionChecks(walletID: "first", account: .init(network: "bitcoin", address: "fixture"))
        XCTAssertTrue(unsupported.isEmpty)
        try await db.reconcileWalletLifecycle([.init(id: "first", deletedAt: 100)])
        do {
            _ = try await db.claimRestrictionChecks(walletID: "first", account: account)
            XCTFail("Soft-deleted wallet was scanned")
        } catch StoreError.missingRecord {}
    }
    func testCombinedRestrictionsKeepAcknowledgementsIndependentAcrossReopen() async throws {
        for multisigFirst in [true, false] {
            let (db, url) = try await fixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let tokens = try await db.claimRestrictionChecks(walletID: "first", account: account)
            try await db.saveRestrictionChecks(walletID: "first", account: account,
                results: tokens.map { .init(token: $0, outcome: .restricted) })
            if multisigFirst {
                try await db.acknowledgeMultisigNotice(walletID: "first")
            } else {
                try await db.acknowledgeStablecoinSecurity(walletID: "first")
            }
            let reopened = try await OathDatabase.open(at: url)
            let multisig = try await reopened.multisigNoticeState(walletID: "first")
            let stablecoin = try await reopened.stablecoinSecurityState(walletID: "first")
            XCTAssertEqual(multisig.acknowledged, multisigFirst)
            XCTAssertEqual(stablecoin.acknowledged, !multisigFirst)
            XCTAssertEqual(stablecoin.restricted.count, 2, "Acknowledging either warning must preserve both confirmed restrictions")
            let otherMultisig = try await reopened.multisigNoticeState(walletID: "second")
            let otherStablecoin = try await reopened.stablecoinSecurityState(walletID: "second")
            XCTAssertFalse(otherMultisig.acknowledged)
            XCTAssertFalse(otherStablecoin.acknowledged)
            // The remaining warning can still be acknowledged independently.
            if multisigFirst {
                try await reopened.acknowledgeStablecoinSecurity(walletID: "first")
            } else {
                try await reopened.acknowledgeMultisigNotice(walletID: "first")
            }
            let finishedMultisig = try await reopened.multisigNoticeState(walletID: "first")
            let finishedStablecoin = try await reopened.stablecoinSecurityState(walletID: "first")
            XCTAssertTrue(finishedMultisig.acknowledged)
            XCTAssertTrue(finishedStablecoin.acknowledged)
        }
    }
}

private actor SecurityScanTransport: AnkrTransport {
    private(set) var calls = 0
    let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        if fail { return (Data("{}".utf8), 503) }
        try await Task.sleep(for: .milliseconds(20))
        let body = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
        let result = body["method"].string == "eth_chainId" ? "0x1" : "0x" + String(repeating: "0", count: 63) + "1"
        return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": .number("1"), "result": .string(result)])), 200)
    }
}
