import Foundation
import XCTest
@testable import OathAnkr
@testable import OathDatabase

private actor RefreshGate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiting.append($0) } } }
    func open() { opened = true; let work = waiting; waiting.removeAll(); work.forEach { $0.resume() } }
}

private actor GatedPolkadotProvider: PolkadotSyncProviding {
    let started = RefreshGate(), replacementStarted = RefreshGate(), oldReleased = RefreshGate()
    let releaseOld = RefreshGate(), releaseReplacement = RefreshGate()
    private var inventoryCalls = 0, oldStarted = 0, oldFinished = 0
    private(set) var cancelledWorkers = 0
    private var seen: Set<String> = []
    func inventory(owner: String) async throws -> PolkadotInventory {
        inventoryCalls += 1
        let generation = inventoryCalls
        if generation == 2 { await replacementStarted.open(); await releaseReplacement.wait() }
        return .init(owner: owner, blockHash: "0x" + String(repeating: "ab", count: 32), height: Int64(generation * 100),
                     holdings: [.init(token: .native, amount: String(generation * 10_000))], observedAt: Date(timeIntervalSince1970: Double(generation * 100)))
    }
    private func holdFirst(_ stream: String) async {
        guard seen.insert(stream).inserted else { return }
        oldStarted += 1
        if oldStarted == 7 { await started.open() }
        await releaseOld.wait()
        if Task.isCancelled { cancelledWorkers += 1 }
        oldFinished += 1
        if oldFinished == 7 { await oldReleased.open() }
    }
    func prices(for tokens: [PolkadotToken]) async throws -> [PolkadotPrice] {
        await holdFirst("prices")
        return [.init(reference: "native", usd: "4", source: "fixture", observedAt: Date())]
    }
    func history(owner: String, stream: String, page: Int, finalizedHeight: Int64) async throws -> PolkadotHistoryPage {
        await holdFirst(stream)
        return .init(events: [], next: nil)
    }
    func relayFinalizedHeight() async throws -> Int64 { 200 }
}

@MainActor final class PolkadotRefreshLifetimeTests: XCTestCase {
    func testOnlyCancelledStaleDatabaseWorkBecomesCancellation() async throws {
        do {
            try await PolkadotSynchronizer.runBackgroundOperation { throw StoreError.staleSync }
            XCTFail("Active stale work must remain an error")
        } catch { XCTAssertEqual(error as? StoreError, .staleSync) }
        for failure in [StoreError.staleSync, StoreError.conflictingIdentity] {
            let entered = RefreshGate(), release = RefreshGate()
            let task = Task {
                try await PolkadotSynchronizer.runBackgroundOperation {
                    await entered.open()
                    await release.wait()
                    throw failure
                }
            }
            await entered.wait()
            task.cancel()
            await release.open()
            do { try await task.value; XCTFail("Expected a terminal error") }
            catch {
                if failure == .staleSync { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? StoreError, .conflictingIdentity) }
            }
        }
    }
    func testReplacementCancelsAllOldWorkersBeforeInvalidatingTheirTicket() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PolkadotLifetime-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await db.seed(networks: [.init(id: "polkadot", name: "Polkadot", family: "account", symbol: "DOT", decimals: 10, derivationPath: "fixture", logo: "network-polkadot", sortOrder: 0)], assets: [.init(id: "polkadot:native", networkID: "polkadot", reference: "native", name: "Polkadot", symbol: "DOT", decimals: 10)])
        try await db.importWalletIfNeeded(.init(id: "wallet", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1), accounts: [.init(id: "account", walletID: "wallet", networkID: "polkadot", address: "13vg3Mrxm3GL9eXxLsGgLYRueiwFCiMbkdHBL4ZN5aob5D4N", derivationPath: "fixture")])
        let provider = GatedPolkadotProvider()
        let sync = PolkadotSynchronizer(database: db, provider: provider)
        try await sync.refresh(accountID: "account")
        await provider.started.wait()
        let replacement = Task { try await sync.refresh(accountID: "account") }
        await provider.replacementStarted.wait()
        await provider.releaseOld.open()
        await provider.oldReleased.wait()
        let cancelled = await provider.cancelledWorkers
        XCTAssertEqual(cancelled, 7, "All six history streams and prices must be cancelled before the new inventory request starts")
        await provider.releaseReplacement.open()
        try await replacement.value
        await sync.waitForBackground(accountID: "account")
        let inventory = try await db.polkadotInventory(accountID: "account")
        XCTAssertEqual(inventory?.height, 200)
        XCTAssertEqual(inventory?.holdings.first?.amount, "20000")
        let snapshot = try await db.snapshot(walletID: "wallet", currency: "USD")
        XCTAssertEqual(snapshot.holdings.first?.price, "4")
        await sync.cancel()
    }
}
