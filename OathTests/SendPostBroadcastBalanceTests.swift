import Foundation
import GRDB
import Testing
@testable import Aperture

struct SendPostBroadcastBalanceTests {
    @Test(arguments: AssetNetworkSelectorOption.allSupported.map(\.id))
    func unchangedBalanceRetriesUntilExactStatusAndFreshBalance(networkID: String) async throws {
        _ = try SendPostBroadcastChainRefreshRoute.resolve(networkID: networkID)
        let probe = FollowUpProbe(statuses: [.pending, .pending, .confirmed], balances: ["100", "100", "90", "90"])
        await run(probe)
        #expect(await probe.delays == [.seconds(2), .seconds(4), .seconds(8), .seconds(2)])
        #expect(await probe.refreshes == 4)
        #expect(await probe.statusReads == 3)
    }

    @Test
    func knownRejectionRefreshesOnceWithoutLookingForAnUnbroadcastHash() async {
        let probe = FollowUpProbe(statuses: [], balances: ["100"])
        await run(probe, terminal: .failed)
        #expect(await probe.refreshes == 1)
        #expect(await probe.statusReads == 0)
        #expect(await probe.delays == [.seconds(2)])
    }

    @Test
    func failureDiscoveredDuringRefreshRequiresAnotherFreshRead() async {
        let probe = FollowUpProbe(statuses: [.failed], balances: ["100", "100"])
        await run(probe)
        #expect(await probe.refreshes == 2)
        #expect(await probe.statusReads == 1)
    }

    @Test
    func confirmedUnchangedSelfTransferDoesNotPollForever() async {
        let probe = FollowUpProbe(statuses: [], balances: ["100"])
        await run(probe, terminal: .confirmed)
        #expect(await probe.refreshes == 5)
        #expect(await probe.delays == [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)])
    }

    @Test
    func changedBalanceAloneCannotEndPendingTracking() async {
        let probe = FollowUpProbe(statuses: [.pending, .pending, .confirmed], balances: ["90"])
        await run(probe)
        #expect(await probe.refreshes == 4)
        #expect(await probe.delays == [.seconds(2), .seconds(30), .seconds(30), .seconds(2)])
    }

    @Test
    func balanceReadFailureRetriesAndNeverInventsZeroOrTransactionFailure() async {
        let probe = FollowUpProbe(statuses: [.pending, .confirmed], balances: ["100", "90"], failedRefreshes: 2)
        await run(probe)
        #expect(await probe.refreshes >= 3)
        #expect(await probe.current == "90")
    }

    @Test
    func statusErrorsRemainUnknownAndCancellationStopsRetries() async {
        let probe = FollowUpProbe(statuses: [], balances: ["100"], cancelAfter: 4)
        await SendPostBroadcastBalanceFollowUp(sleep: { try await probe.sleep($0) }).run(
            snapshot: { await probe.snapshot() }, status: { throw URLError(.timedOut) },
            refresh: { _ in await probe.refresh() })
        #expect(await probe.refreshes == 4)
        #expect(await probe.current == "100")
    }

    @Test
    func comparesLosslessLedgerUnitsAndIgnoresPriceChanges() async throws {
        let database = try WalletDatabase.temporary()
        _ = try await SendRecipientHistoryTestFixtures.seed(database)
        let receipt = SendRecipientHistoryTestFixtures.receipt()
        try await database.pool.write { db in
            try DBAccountAssetRecord(accountID: receipt.accountID, assetID: receipt.assetID,
                balance: "9007199254740993.000000000000000001", balanceAtomic: "9007199254740993000000000000000001",
                fiatUSDValue: "1", isEnabled: true, isPinned: false, isHidden: false, sortOrder: nil,
                firstSeenAt: 1, lastSeenAt: 1, updatedAt: 1).insert(db)
        }
        let before = try await database.sendBalanceSnapshot(receipt: receipt)
        #expect(before.quantities[receipt.assetID] == "9007199254740993000000000000000001")
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE accountAssets SET fiatUSDValue = '999'")
        }
        #expect(try await database.sendBalanceSnapshot(receipt: receipt) == before)
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE accountAssets SET balanceAtomic = '9007199254740993000000000000000000'")
        }
        #expect(try await database.sendBalanceSnapshot(receipt: receipt) != before)
    }

    @Test
    func base58TransactionIdentityRemainsCaseSensitive() throws {
        let asset = try SendRecipientHistoryTestFixtures.asset(networkID: "solana")
        let upper = SendRecipientHistoryTestFixtures.receipt(asset: asset, hash: "AbCd")
        let lower = SendRecipientHistoryTestFixtures.receipt(asset: asset, hash: "abcd")
        #expect(SendPostBroadcastChainRefreshID(walletID: "w", receipt: upper)
            != SendPostBroadcastChainRefreshID(walletID: "w", receipt: lower))
    }

    @Test @MainActor
    func terminalStatusImmediatelyRequestsFreshBalanceEvenDuringBackoff() async throws {
        let database = try WalletDatabase.temporary()
        _ = try await SendRecipientHistoryTestFixtures.seed(database)
        let receipt = SendRecipientHistoryTestFixtures.receipt()
        var requests: [SendPostBroadcastRefreshRequest] = []
        let operation = SendOperation(database: database,
            draft: SendEntryTestFixtures.draft(recipient: receipt.toAddress, amount: receipt.amount),
            walletAddress: receipt.fromAddress, nativeUnitUSDPrice: nil,
            onTransactionBroadcast: { requests.append($0) }, statusReader: { _ in .confirmed })
        defer { operation.stopMonitoring() }
        operation.start { .init(receipt: receipt, localTransactionID: nil, localPersistenceWarningCode: nil) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while requests.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(requests.count == 2)
        #expect(requests.first?.knownTerminalStatus == nil)
        #expect(requests.last?.knownTerminalStatus == .confirmed)
    }

    @Test @MainActor
    func rejectedSubmissionCarriesKnownFailureIntoBalanceRefresh() async throws {
        let database = try WalletDatabase.temporary()
        let receipt = SendRecipientHistoryTestFixtures.receipt()
        var requests: [SendPostBroadcastRefreshRequest] = []
        let operation = SendOperation(database: database,
            draft: SendEntryTestFixtures.draft(recipient: receipt.toAddress, amount: receipt.amount),
            walletAddress: receipt.fromAddress, nativeUnitUSDPrice: nil,
            onTransactionBroadcast: { requests.append($0) })
        defer { operation.stopMonitoring() }
        operation.start { throw SendTransactionSubmissionError.broadcastRejected(code: "dust", message: "dust", receipt: receipt) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while requests.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(requests.count == 1)
        #expect(requests.first?.knownTerminalStatus == .failed)
    }

    @Test
    func cancellingOnlyRefreshSubscriberCancelsItsProviderWork() async throws {
        actor Probe {
            var started = false
            var cancelled = false
            func read() async -> WalletChainSyncOutcome {
                started = true
                do { try await Task.sleep(for: .seconds(60)) }
                catch { cancelled = true }
                return .cancelled(.evm)
            }
        }
        let database = try WalletDatabase.temporary()
        let probe = Probe()
        let pool = SendPostBroadcastBalanceRefreshPool()
        let work = Task {
            await pool.refresh(key: .init(database: ObjectIdentifier(database), walletID: "w", networkID: "eth"),
                onProgress: nil) { _ in await probe.read() }
        }
        defer { work.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await probe.started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        work.cancel()
        _ = await work.value
        while !(await probe.cancelled), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await probe.cancelled)
    }

    private func run(_ probe: FollowUpProbe, terminal: SendTransactionNetworkStatus? = nil) async {
        await SendPostBroadcastBalanceFollowUp(sleep: { try await probe.sleep($0) }).run(
            knownTerminalStatus: terminal, snapshot: { await probe.snapshot() },
            status: { await probe.status() }, refresh: { _ in await probe.refresh() })
    }
}

private actor FollowUpProbe {
    let statuses: [SendTransactionNetworkStatus]
    let balances: [String]
    let failedRefreshes: Int
    let cancelAfter: Int
    var statusReads = 0
    var refreshes = 0
    var delays: [Duration] = []
    var current = "100"

    init(statuses: [SendTransactionNetworkStatus], balances: [String], failedRefreshes: Int = 0, cancelAfter: Int = 20) {
        self.statuses = statuses; self.balances = balances
        self.failedRefreshes = failedRefreshes; self.cancelAfter = cancelAfter
    }
    func sleep(_ duration: Duration) throws {
        if delays.count >= cancelAfter { throw CancellationError() }
        delays.append(duration)
    }
    func snapshot() -> SendBalanceSnapshot { .init(quantities: ["native": current]) }
    func status() -> SendTransactionNetworkStatus {
        defer { statusReads += 1 }
        return statuses.isEmpty ? .pending : statuses[min(statusReads, statuses.count - 1)]
    }
    func refresh() -> Bool {
        refreshes += 1
        guard refreshes > failedRefreshes else { return false }
        current = balances[min(refreshes - 1, balances.count - 1)]
        return true
    }
}
