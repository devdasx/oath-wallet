import Foundation
import GRDB
import Testing
import SwiftUI
import UIKit
@testable import Aperture

@Suite(.timeLimit(.minutes(2)))
struct StablecoinBlacklistTests {
    static let address = "0x000000000000000000000000000000000000dead"
    static let targets = StablecoinBlacklistRegistry.all.filter { $0.networkID == "eth" }

    @Test(arguments: [false, true])
    func canonicalBoolean(value: Bool) throws {
        #expect(try StablecoinBlacklistABI.boolean("0x" + String(repeating: "0", count: 63) + (value ? "1" : "0")) == value)
    }

    @Test(arguments: ["", "0x", "0x0", "false", "0x" + String(repeating: "0", count: 63) + "2",
                      "0x1" + String(repeating: "0", count: 63), String(repeating: "0", count: 65)])
    func invalidBooleanIsUnknown(value: String) {
        #expect(throws: StablecoinCheckError.self) { try StablecoinBlacklistABI.boolean(value) }
    }

    @Test
    func addressEncodingIsExactAndRejectsMalformedInput() throws {
        #expect(try StablecoinBlacklistABI.parameter(address: Self.address) == String(repeating: "0", count: 60) + "dead")
        for address in ["0x123", "", "0x" + String(repeating: "g", count: 40)] {
            #expect(throws: StablecoinCheckError.self) { try StablecoinBlacklistABI.parameter(address: address) }
        }
    }

    @Test
    func registryCoversEveryShippedEVMNetworkWithoutCallingUnsupportedContracts() {
        let evm = Set(ReceiveNetworkCatalog.all.filter { $0.blockchain.isEVM }.map(\.id))
        #expect(Set(StablecoinBlacklistRegistry.all.filter { $0.networkID != "tron" }.map(\.networkID)) == evm)
        #expect(Set(StablecoinBlacklistRegistry.all.map(\.id)).count == StablecoinBlacklistRegistry.all.count)
        for network in evm {
            let symbols = StablecoinBlacklistRegistry.all.filter { $0.networkID == network }.map(\.symbol)
            #expect(symbols.contains { $0.hasPrefix("USDT") })
            #expect(symbols.contains { $0.hasPrefix("USDC") })
        }
        #expect(StablecoinBlacklistRegistry.all.filter { $0.networkID == "bsc" }.allSatisfy { $0.method == nil })
    }

    @Test(arguments: [false, true])
    func successfulResultsAreCheckedOnlyOnceAcrossMonitorInstances(value: Bool) async throws {
        let (db, walletID) = try await Self.database()
        let monitor = StablecoinBlacklistMonitor { _, _ in value }
        #expect(await monitor.check(database: db, walletID: walletID, targets: Self.targets))
        let next = StablecoinBlacklistMonitor { _, _ in
            Issue.record("A successful result was fetched again")
            throw URLError(.timedOut)
        }
        #expect(await next.check(database: db, walletID: walletID, targets: Self.targets))
        let records = try await db.pool.read { try StablecoinBlacklistRecord.fetchAll($0) }
        #expect(records.count == Self.targets.count)
        #expect(records.allSatisfy { $0.isBlacklisted == value })
        #expect(try await db.pool.read { try WalletDatabase.confirmedStablecoinChecks(in: $0).count } == (value ? Self.targets.count : 0))
    }

    @Test
    func failureRetriesWithoutErasingConfirmedFinding() async throws {
        let (db, walletID) = try await Self.database()
        let partial = StablecoinBlacklistMonitor { target, _ in
            if target.symbol == "USDT" { return true }
            throw StablecoinCheckError.rpc(-32000, "execution reverted")
        }
        #expect(await !partial.check(database: db, walletID: walletID, targets: Self.targets))
        #expect(try await db.pool.read { try StablecoinBlacklistRecord.fetchCount($0) } == 1)
        let retry = StablecoinBlacklistMonitor { target, _ in
            #expect(target.symbol == "USDC")
            return false
        }
        #expect(await retry.check(database: db, walletID: walletID, targets: Self.targets))
        #expect(try await db.pool.read { try WalletDatabase.confirmedStablecoinChecks(in: $0).map(\.symbol) } == ["USDT"])
    }

    @Test
    func unrelatedWalletAndDisabledAccountNeverInheritWarning() async throws {
        let (db, walletID) = try await Self.database()
        _ = await StablecoinBlacklistMonitor { _, _ in true }.check(database: db, walletID: walletID, targets: Self.targets)
        let findings = try await db.pool.read { try WalletDatabase.confirmedStablecoinChecks(in: $0) }
        #expect(findings.filter { $0.walletID == "unrelated" }.isEmpty)
        try await db.pool.write { try $0.execute(sql: "UPDATE walletAccounts SET isEnabled = 0 WHERE walletID = ?", arguments: [walletID]) }
        #expect(try await db.pool.read { try WalletDatabase.confirmedStablecoinChecks(in: $0) }.isEmpty)
    }

    @Test
    func changedAddressRejectsLateResponseAndGetsItsOwnCheck() async throws {
        let (db, walletID) = try await Self.database()
        let jobs = try await db.pendingStablecoinChecks(walletID: walletID, targets: Self.targets)
        let job = try #require(jobs.first)
        let other = "0x0000000000000000000000000000000000000001"
        try await db.pool.write { try $0.execute(sql: "UPDATE walletAccounts SET address = ? WHERE walletID = ?", arguments: [other, walletID]) }
        try await db.storeStablecoinCheck(.init(walletID: walletID, accountID: job.accountID,
            networkID: job.target.networkID, contract: job.target.contract, address: job.address,
            symbol: job.target.symbol, isBlacklisted: true, checkedAt: 1))
        #expect(try await db.pool.read { try StablecoinBlacklistRecord.fetchCount($0) } == 0)
        #expect(try await db.pendingStablecoinChecks(walletID: walletID, targets: Self.targets).allSatisfy { $0.address == other })
    }

    @Test
    func sharedEVMIdentityChecksAllChainsButTronPrivateKeyDoesNot() async throws {
        let (db, walletID) = try await Self.database()
        let jobs = try await db.pendingStablecoinChecks(walletID: walletID, targets: StablecoinBlacklistRegistry.all)
        #expect(jobs.allSatisfy { $0.address == Self.address && $0.target.networkID != "tron" })
        #expect(Set(jobs.map { $0.target.networkID }).count == 12) // BSC's bridged tokens lack getters.
        let (tron, tronID) = try await Self.database(network: "tron", address: "TDqGdq76PDHrEXfEPMmNa2ayc7E4PKzfS1")
        let tronJobs = try await tron.pendingStablecoinChecks(walletID: tronID, targets: StablecoinBlacklistRegistry.all)
        #expect(tronJobs.count == 2)
        #expect(tronJobs.allSatisfy { $0.target.networkID == "tron" })
    }

    @Test
    func concurrentRefreshDoesNotDuplicateChecks() async throws {
        let (db, walletID) = try await Self.database()
        let gate = StablecoinTestGate()
        let monitor = StablecoinBlacklistMonitor { _, _ in await gate.enter(); return false }
        async let first = monitor.check(database: db, walletID: walletID, targets: Array(Self.targets.prefix(1)))
        await gate.waitForEntry()
        #expect(await !monitor.check(database: db, walletID: walletID, targets: Self.targets))
        await gate.release()
        #expect(await first)
        #expect(await gate.calls == 1)
    }

    @Test
    func cancellationDoesNotCacheResult() async throws {
        let (db, walletID) = try await Self.database()
        let gate = StablecoinTestGate()
        let monitor = StablecoinBlacklistMonitor { _, _ in await gate.enter(); return true }
        let task = Task { await monitor.check(database: db, walletID: walletID, targets: Array(Self.targets.prefix(1))) }
        await gate.waitForEntry()
        task.cancel()
        await gate.release()
        #expect(await !task.value)
        #expect(try await db.pool.read { try StablecoinBlacklistRecord.fetchCount($0) } == 0)
    }

    @Test
    func tronExecutionSuccessFlagAloneCannotMeanNotBlacklisted() throws {
        #expect(try !SendTronAPIClient.decodeStablecoinBlacklist([
            "result": ["result": true], "constant_result": [String(repeating: "0", count: 64)]]))
        #expect(try SendTronAPIClient.decodeStablecoinBlacklist([
            "result": ["result": true], "constant_result": [String(repeating: "0", count: 63) + "1"]]))
        for object: [String: Any] in [
            ["result": ["result": true, "message": "REVERT opcode executed"], "constant_result": [""]],
            ["result": ["code": "OTHER_ERROR", "message": "invalid address"]],
            ["result": ["result": true], "constant_result": []],
            ["result": ["result": 1], "constant_result": [String(repeating: "0", count: 64)]],
            ["Error": "rate limit exceeded"]
        ] {
            #expect(throws: StablecoinCheckError.self) { try SendTronAPIClient.decodeStablecoinBlacklist(object) }
        }
    }

    @Test
    func missingCanonicalAccountRemainsPending() async throws {
        let (db, walletID) = try await Self.database()
        try await db.pool.write {
            try $0.execute(sql: "UPDATE wallets SET kind = 'importedRecoveryPhrase' WHERE id = ?", arguments: [walletID])
            try $0.execute(sql: "DELETE FROM walletAccounts WHERE walletID = ?", arguments: [walletID])
        }
        let plan = try await db.stablecoinCheckPlan(walletID: walletID, targets: Self.targets)
        #expect(plan.jobs.isEmpty)
        #expect(!plan.accountsComplete)
        let monitor = StablecoinBlacklistMonitor { _, _ in Issue.record("No account to check"); return false }
        #expect(await !monitor.check(database: db, walletID: walletID, targets: Self.targets))
    }

    @MainActor
    @Test(.serialized, arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func combinedWarningUsesOneAdaptiveNativeRow(layout: NativeListTestLayout) async throws {
        let findings = Self.targets.map { target in
            StablecoinBlacklistRecord(walletID: "fixture", accountID: "account", networkID: target.networkID,
                contract: target.contract, address: Self.address, symbol: target.symbol, isBlacklisted: true, checkedAt: 1)
        }
        for hasMultisig in [false, true] {
            let host = try NativeListTestHost(layout: layout) {
                List { Section { WalletAccountWarningRow(hasTronMultisig: hasMultisig, findings: findings) } }
            }
            defer { host.close() }
            let list = try await host.list()
            #expect(list.numberOfSections == 1)
            #expect(list.numberOfItems(inSection: 0) == 1)
            let cell = try await host.cell(at: IndexPath(item: 0, section: 0), in: list)
            #expect(cell.bounds.width <= list.bounds.width)
            #expect(cell.bounds.height > 0)
        }
    }

    static func database(network: String = "eth", address: String = address) async throws -> (WalletDatabase, String) {
        let db = try WalletDatabase.temporary(), id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        try await db.pool.write { database in
            try DBWalletRecord(id: id, profileID: WalletDatabase.defaultProfileID,
                name: "Blacklist Fixture", kind: "importedPrivateKey", secretKeyReference: nil,
                isSelected: true, sortOrder: 0, createdAt: now, updatedAt: now,
                lastOpenedAt: now, archivedAt: nil).insert(database)
            try DBWalletAccountRecord(id: "\(id):\(network):0", walletID: id, networkID: network,
                address: address, normalizedAddress: address.lowercased(), label: nil,
                derivationPath: nil, accountIndex: 0, publicKey: "fixture-public-key",
                isWatchOnly: false, isEnabled: true, createdAt: now, updatedAt: now,
                lastSyncedAt: nil).insert(database)
        }
        return (db, id)
    }
}

private actor StablecoinTestGate {
    private(set) var calls = 0
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func enter() async {
        calls += 1
        entryWaiter?.resume(); entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitForEntry() async {
        if calls > 0 { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
