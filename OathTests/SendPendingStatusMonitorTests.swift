import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct SendPendingStatusMonitorTests {
    @Test @MainActor
    func restoresAndConfirmsEverySupportedChainWithoutOpeningSend() async throws {
        let database = try WalletDatabase.temporary()
        let networks = AssetNetworkSelectorOption.allSupported
        #expect(networks.count == 26)
        var ids: [String] = []
        for network in networks {
            let asset = try SendEntryTestFixtures.nativeChoice(for: network)
            _ = try await SendRecipientHistoryTestFixtures.seed(database, asset: asset)
            let receipt = SendRecipientHistoryTestFixtures.receipt(asset: asset,
                hash: "0x" + String(repeating: "a", count: 64))
            let id = try await database.recordSubmittedSend(receipt: receipt,
                draft: SendEntryTestFixtures.draft(asset: asset, recipient: receipt.toAddress, amount: receipt.amount),
                outcome: .accepted)
            ids.append(id)
        }
        let targets = try await database.pool.read { try WalletDatabase.pendingStatusTargets(in: $0) }
        #expect(targets.count == 26)
        let monitor = SendPendingStatusMonitor(refreshesBalances: false, reader: { _ in .confirmed })
        let start = ContinuousClock.now
        let work = Task { await monitor.run(database: database) }
        defer { work.cancel() }
        try await waitUntil {
            try await database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions WHERE status = 'pending'") == 0
            }
        }
        print("STATUS_MONITOR restored_26_terminal_seconds=\(start.duration(to: .now))")
        #expect(monitor.failureCodes.isEmpty)
        let count = try await database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sendStatusTracking WHERE status = 'confirmed'")
        }
        #expect(count == ids.count)
    }

    @Test @MainActor
    func pendingReceiptDiscoveredAfterMonitoringStartsAndFailurePersists() async throws {
        let database = try WalletDatabase.temporary()
        let monitor = SendPendingStatusMonitor(refreshesBalances: false, reader: { _ in .failed })
        let work = Task { await monitor.run(database: database) }
        defer { work.cancel() }
        let (_, id) = try await seed(database)
        try await waitUntil {
            try await database.pool.read { try DBTransactionRecord.fetchOne($0, key: id)?.status == "failed" }
        }
        #expect(try await database.pool.read { try WalletDatabase.pendingStatusTargets(in: $0).isEmpty })
    }

    @Test @MainActor
    func readErrorDoesNotMarkTransactionFailedAndResumeRetriesImmediately() async throws {
        let database = try WalletDatabase.temporary()
        let (_, id) = try await seed(database)
        let first = SendPendingStatusMonitor(refreshesBalances: false, reader: { _ in throw URLError(.timedOut) })
        let task = Task { await first.run(database: database) }
        try await waitUntil { await MainActor.run { !first.failureCodes.isEmpty } }
        task.cancel()
        await task.value
        #expect(try await database.pool.read { try DBTransactionRecord.fetchOne($0, key: id)?.status } == "pending")
        let second = SendPendingStatusMonitor(refreshesBalances: false, reader: { _ in .confirmed })
        let start = ContinuousClock.now
        let resumed = Task { await second.run(database: database) }
        defer { resumed.cancel() }
        try await waitUntil {
            try await database.pool.read { try DBTransactionRecord.fetchOne($0, key: id)?.status == "confirmed" }
        }
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test @MainActor
    func terminalNetworkResultRetriesFailedPersistenceWithoutAnotherLookup() async throws {
        actor Counter {
            var reads = 0
            func read() -> SendTransactionNetworkStatus { reads += 1; return .confirmed }
        }
        let database = try WalletDatabase.temporary()
        let counter = Counter()
        let receipt = SendRecipientHistoryTestFixtures.receipt(hash: "0x" + String(repeating: "f", count: 64))
        let operation = SendOperation(database: database,
            draft: SendEntryTestFixtures.draft(recipient: receipt.toAddress, amount: receipt.amount),
            walletAddress: receipt.fromAddress, nativeUnitUSDPrice: nil,
            statusReader: { _ in await counter.read() })
        defer { operation.stopMonitoring() }
        operation.start { .init(receipt: receipt, localTransactionID: nil, localPersistenceWarningCode: "fixture") }
        try await waitUntil { operation.statusPersistenceWarningCode != nil }
        #expect(operation.networkStatus == .confirmed)
        _ = try await SendRecipientHistoryTestFixtures.seed(database)
        try await waitUntil { operation.localTransactionID != nil && operation.statusPersistenceWarningCode == nil }
        #expect(await counter.reads == 1)
        #expect(try await database.persistedTerminalSendStatus(receipt) == .confirmed)
    }

    @Test
    func duplicateObserversShareOneRead() async throws {
        actor Probe {
            var reads = 0
            var active = 0
            var maximumActive = 0
            func read() async throws -> SendTransactionNetworkStatus {
                reads += 1; active += 1; maximumActive = max(maximumActive, active)
                defer { active -= 1 }
                try await Task.sleep(for: .milliseconds(80))
                return .confirmed
            }
        }
        let probe = Probe()
        let pool = SendStatusRequestPool(reader: { _ in try await probe.read() })
        let asset = SendEntryTestFixtures.ethereum
        let receipt = SendRecipientHistoryTestFixtures.receipt(asset: asset, hash: "0x" + String(repeating: "b", count: 64))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let status = try await pool.status(for: receipt)
                    #expect(status == .confirmed)
                }
            }
            try await group.waitForAll()
        }
        #expect(await probe.reads == 1)
        #expect(await probe.maximumActive == 1)
    }

    @Test
    func concurrentNetworksRespectTheGlobalLimit() async throws {
        actor Probe {
            var active = 0
            var peak = 0
            func read() async throws -> SendTransactionNetworkStatus {
                active += 1; peak = max(peak, active)
                defer { active -= 1 }
                try await Task.sleep(for: .milliseconds(80))
                return .confirmed
            }
        }
        let probe = Probe()
        let pool = SendStatusRequestPool(limit: 2, reader: { _ in try await probe.read() })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for network in ["eth", "base", "arbitrum", "polygon", "optimism"] {
                let receipt = Self.publicReceipt(network: network)
                group.addTask { _ = try await pool.status(for: receipt) }
            }
            try await group.waitForAll()
        }
        #expect(await probe.peak == 2)
    }

    @Test @MainActor
    func cancellingQueuedWorkDoesNotStartAnotherProviderRead() async throws {
        actor Probe {
            var reads = 0
            func read() async throws -> SendTransactionNetworkStatus {
                reads += 1
                try await Task.sleep(for: .milliseconds(200))
                return .confirmed
            }
        }
        let probe = Probe()
        let pool = SendStatusRequestPool(limit: 1, reader: { _ in try await probe.read() })
        let running = Task { try await pool.status(for: Self.publicReceipt(network: "eth")) }
        try await waitUntil { await probe.reads == 1 }
        let queued = Task { try await pool.status(for: Self.publicReceipt(network: "base")) }
        await Task.yield()
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        _ = try await running.value
        #expect(await probe.reads == 1)
    }

    private static func publicReceipt(network: String) -> SendTransactionReceipt {
        SendTransactionReceipt(transactionHash: "0x" + String(repeating: "d", count: 64),
            accountID: "fixture", networkID: network, fromAddress: "", toAddress: "", assetID: "",
            assetSymbol: "", amount: "0", amountAtomic: "0", networkFee: nil,
            networkFeeAtomic: nil, networkFeeSymbol: "", submittedAt: Date())
    }

    @Test
    func fastChainCadenceAndErrorBackoffAreBounded() {
        #expect(SendTransactionStatusPollingPolicy.interval(networkID: "eth") == .seconds(2))
        #expect(SendTransactionStatusPollingPolicy.interval(networkID: "bitcoin_cash") == .seconds(4))
        #expect(SendTransactionStatusPollingPolicy.interval(networkID: "ton") == .seconds(4))
        #expect(SendTransactionStatusPollingPolicy.interval(networkID: "eth", failures: 100) == .seconds(30))
    }

    @Test
    func verboseUTXOStatusRequiresMatchingTransactionAndBlockEvidence() throws {
        let hash = String(repeating: "a", count: 64)
        let pending: JSONValue = .object(["txid": .string(hash), "vin": .array([]), "vout": .array([])])
        #expect(try BitcoinFamilyTransactionStatusProvider.verboseStatus(pending, expectedHash: hash,
            networkID: "bitcoin_cash") == .pending)
        let confirmed: JSONValue = .object(["txid": .string(hash), "vin": .array([]), "vout": .array([]),
            "confirmations": .number(1), "blockhash": .string(String(repeating: "b", count: 64))])
        #expect(try BitcoinFamilyTransactionStatusProvider.verboseStatus(confirmed, expectedHash: hash,
            networkID: "bitcoin_cash") == .confirmed)
        #expect(throws: (any Error).self) {
            try BitcoinFamilyTransactionStatusProvider.verboseStatus(confirmed,
                expectedHash: String(repeating: "c", count: 64), networkID: "bitcoin_cash")
        }
    }

    private func seed(_ database: WalletDatabase) async throws -> (SendTransactionReceipt, String) {
        let asset = SendEntryTestFixtures.ethereum
        _ = try await SendRecipientHistoryTestFixtures.seed(database, asset: asset)
        let receipt = SendRecipientHistoryTestFixtures.receipt(asset: asset, hash: "0x" + String(repeating: "c", count: 64))
        let id = try await database.recordSubmittedSend(receipt: receipt,
            draft: SendEntryTestFixtures.draft(asset: asset, recipient: receipt.toAddress, amount: receipt.amount),
            outcome: .accepted)
        return (receipt, id)
    }

    @MainActor
    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while try await !condition() {
            try #require(ContinuousClock.now < deadline, "Status did not reach the database")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor @Suite(.serialized)
struct PendingTransactionReconciliationTests {
    @Test(arguments: ["missing", "present", "confirmedDuringLookup", "wrongHash", "outage"])
    func esploraFalseStatusIsNotProofOfMempoolPresence(_ mode: String) async throws {
        let hash = String(repeating: "a", count: 64)
        let reader = SendBitcoinExactStatus(executor: { request in
            let data: Data
            let code: Int
            if request.url!.path.hasSuffix("/status") {
                data = Data("{\"confirmed\":false}".utf8); code = 200
            } else {
                #expect(request.url!.path.hasSuffix("/tx/" + hash))
                code = mode == "missing" ? 404 : (mode == "outage" ? 503 : 200)
                let returnedHash = mode == "wrongHash" ? String(repeating: "b", count: 64) : hash
                let status: String = mode == "confirmedDuringLookup"
                    ? "{\"confirmed\":true,\"block_height\":900000,\"block_hash\":\"\(String(repeating: "c", count: 64))\"}"
                    : "{\"confirmed\":false}"
                data = Data("{\"txid\":\"\(returnedHash)\",\"status\":\(status)}".utf8)
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        })
        if mode == "outage" || mode == "wrongHash" {
            await #expect(throws: (any Error).self) { try await reader.status(hash: hash) }
        } else {
            let expected: SendTransactionNetworkStatus = mode == "missing" ? .notFound : (mode == "present" ? .pending : .confirmed)
            #expect(try await reader.status(hash: hash) == expected)
        }
    }

    @Test
    func missingReceivedPaymentIsVisibleAndCanConfirmAfterRestart() async throws {
        let database = try WalletDatabase.temporary()
        let target = try await received(database)
        let now = Date()
        _ = try await database.recordPendingObservation(.notFound, target: target, now: now)
        #expect(try await displayed(database, target: target)?.status == .pending)
        _ = try await database.recordPendingObservation(.notFound, target: target, now: now.addingTimeInterval(16))
        #expect(try await displayed(database, target: target)?.status == .notFound)
        #expect(try await database.pool.read { try WalletDatabase.pendingStatusTargets(in: $0).count } == 1)
        let restarted = SendPendingStatusMonitor(refreshesBalances: false, reader: { _ in .confirmed })
        let task = Task { await restarted.run(database: database) }
        defer { task.cancel() }
        try await wait { try await displayed(database, target: target)?.status == .confirmed }
        #expect(try await database.pool.read {
            try WalletDatabase.pendingStatusTargets(in: $0, includeDirtyBalances: true).count
        } == 1, "Terminal status must leave durable balance refresh work")
    }

    @Test(arguments: [SendTransactionNetworkStatus.confirmed, .failed, .canceled])
    func incomingTransactionsReconcileOnEverySupportedNetwork(_ status: SendTransactionNetworkStatus) async throws {
        let database = try WalletDatabase.temporary()
        for network in AssetNetworkSelectorOption.allSupported {
            _ = try await received(database, network: network.id)
        }
        let targets = try await database.pool.read { try WalletDatabase.pendingStatusTargets(in: $0) }
        #expect(targets.count == AssetNetworkSelectorOption.allSupported.count)
        #expect(targets.count == 26)
        let monitor = SendPendingStatusMonitor(refreshesBalances: false, reader: { _ in status })
        let task = Task { await monitor.run(database: database) }
        defer { task.cancel() }
        try await wait {
            try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transactions WHERE status = 'pending'") == 0 }
        }
        #expect(try await database.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transactions WHERE status = ?", arguments: [status.databaseStatus])
        } == 26)
    }

    @Test
    func replacementRemainsRecheckableUntilConflictingTransactionConfirms() async throws {
        let database = try WalletDatabase.temporary()
        let target = try await received(database, network: "bitcoin")
        let replacement = String(repeating: "b", count: 64)
        try await database.recordReplacement(replacement, target: target)
        _ = try await database.recordPendingObservation(.replaced, target: target)
        let view = try #require(try await displayed(database, target: target))
        #expect(view.status == .replaced)
        #expect(view.replacementTransactionHash == replacement)
        #expect(!SendTransactionNetworkStatus.replaced.isTerminal)
        #expect(try await database.pool.read { try WalletDatabase.pendingStatusTargets(in: $0).count } == 1)
        _ = try await database.recordPendingObservation(.pending, target: target)
        #expect(try await displayed(database, target: target)?.status == .pending, "Original may return before any conflict confirms")
        _ = try await database.recordPendingObservation(.canceled, target: target)
        _ = try await database.updateSubmittedSendStatus(receipt: target.receipt, status: .canceled)
        #expect(try await displayed(database, target: target)?.status == .replaced)
        #expect(try await database.pool.read { try WalletDatabase.pendingStatusTargets(in: $0).isEmpty })
    }

    @Test
    func staleHistoryCannotEraseObservedReplacementAndNotesSurvive() async throws {
        let database = try WalletDatabase.temporary()
        let target = try await received(database)
        var record = try #require(try await database.pool.read { try DBTransactionRecord.fetchOne($0, key: target.transactionID) })
        try await database.setTransactionNote(transactionID: record.id, note: "Payment review")
        _ = try await database.recordPendingObservation(.replaced, target: target)
        record.observedStatus = nil
        try await database.pool.write { [record] in try record.save($0) }
        let view = try #require(try await displayed(database, target: target))
        #expect(view.status == .replaced)
        #expect(view.metadata.note == "Payment review")
    }

    @Test
    func readFailureNeverCreatesMissingEvidence() async throws {
        let database = try WalletDatabase.temporary()
        let target = try await received(database)
        let monitor = SendPendingStatusMonitor(refreshesBalances: false, reader: { _ in throw URLError(.timedOut) })
        let task = Task { await monitor.run(database: database) }
        defer { task.cancel() }
        try await wait { !monitor.failureCodes.isEmpty }
        #expect(try await displayed(database, target: target)?.status == .pending)
        #expect(try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pendingTransactionEvidence") } == 0)
    }

    @Test
    func publicOriginalInputsAreDurableAndWalletScoped() async throws {
        let database = try WalletDatabase.temporary()
        let target = try await received(database, network: "bitcoin")
        try await database.savePendingEvidence(.init(rawTransaction: Self.raw, nonce: 17), target: target)
        let restored = try await database.pendingEvidence(target)
        #expect(restored.rawTransaction == Self.raw)
        #expect(restored.nonce == 17)
        let asset = try SendRecipientHistoryTestFixtures.asset(networkID: "bitcoin")
        _ = try await SendRecipientHistoryTestFixtures.seed(database, asset: asset, walletID: "another-wallet", selected: false)
        let other = SendPendingStatusTarget(receipt: SendRecipientHistoryTestFixtures.receipt(asset: asset,
            walletID: "another-wallet", hash: target.receipt.transactionHash), transactionID: nil,
            accountAddress: target.accountAddress, isTONHistory: false, contractAddress: nil)
        #expect(try await database.pendingEvidence(other).rawTransaction == nil)
        #expect(try await database.pendingEvidence(other).nonce == nil)
        #expect(try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pendingTransactionEvidence") } == 1)
    }

    @Test(arguments: [SendTransactionNetworkStatus.pending, .confirmed, .notFound])
    func rbfRecordRequiresOriginalIdentityAndLiveReplacement(_ replacementStatus: SendTransactionNetworkStatus) async throws {
        let original = String(repeating: "a", count: 64), replacement = String(repeating: "b", count: 64)
        let reader = PendingBitcoinConflictReader(executor: { request in
            #expect(request.url?.path == "/api/v1/tx/\(original)/rbf")
            let data = Data("""
                {"replacements":{"tx":{"txid":"\(replacement)"},"replaces":[{"tx":{"txid":"\(original)"},"replaces":[]}]}}
                """.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, exactStatus: { hash in #expect(hash == replacement); return replacementStatus })
        let result = try await reader.conflict(chain: .bitcoin, hash: original, originalRaw: nil)
        if replacementStatus == .notFound { #expect(result == nil) }
        else {
            #expect(result?.hash == replacement)
            #expect(result?.confirmed == (replacementStatus == .confirmed))
        }
        let unrelated: JSONValue = .object(["tx": .object(["txid": .string(replacement)]), "replaces": .array([])])
        #expect(!PendingBitcoinConflictReader.rbfContains(hash: original, node: unrelated, depth: 0))
    }

    @Test
    func legacyBase58NormalizationDoesNotHideMissingStatusOrBalanceRefresh() async throws {
        let database = try WalletDatabase.temporary()
        _ = try await received(database, network: "solana")
        let hash = "AbCdEF123"
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE transactions SET transactionHash = ?, normalizedTransactionHash = ?",
                arguments: [hash, hash.lowercased()])
        }
        let target = try #require(try await database.pool.read { try WalletDatabase.pendingStatusTargets(in: $0).first })
        let now = Date()
        _ = try await database.recordPendingObservation(.notFound, target: target, now: now)
        _ = try await database.recordPendingObservation(.notFound, target: target, now: now.addingTimeInterval(16))
        #expect(try await displayed(database, target: target)?.status == .notFound)
        #expect(try await database.pool.read { try WalletDatabase.pendingStatusTargets(in: $0, includeDirtyBalances: true).first?.balanceNeedsRefresh } == true)
    }

    @Test(arguments: ["solana", "sui", "near"])
    func caseSensitiveIdentifiersCannotShareAnotherTransactionsStatus(_ network: String) async throws {
        let database = try WalletDatabase.temporary()
        let asset = try SendRecipientHistoryTestFixtures.asset(networkID: network)
        let scope = try await SendRecipientHistoryTestFixtures.seed(database, asset: asset)
        let first = SendRecipientHistoryTestFixtures.transaction(id: "case-upper", hash: "AbCdEF123", scope: scope,
            kind: "received", direction: "incoming", status: "confirmed", amount: "1")
        let second = SendRecipientHistoryTestFixtures.transaction(id: "case-lower", hash: "abcdef123", scope: scope,
            kind: "received", direction: "incoming", status: "pending", amount: "1")
        try await SendRecipientHistoryTestFixtures.save([first, second], in: database)
        let target = try #require(try await database.pool.read {
            try WalletDatabase.pendingStatusTargets(in: $0).first { $0.transactionID == second.id }
        })
        #expect(try await database.persistedTerminalSendStatus(target.receipt) == nil)
        let now = Date()
        _ = try await database.recordPendingObservation(.notFound, target: target, now: now)
        _ = try await database.recordPendingObservation(.notFound, target: target, now: now.addingTimeInterval(16))
        try await database.recordReplacement("Replacement123", target: target)
        #expect(try await displayed(database, target: target)?.status == .notFound)
        let unchanged = try #require(try await database.pool.read { try DBTransactionRecord.fetchOne($0, key: first.id) })
        #expect(unchanged.status == "confirmed")
        #expect(unchanged.observedStatus == nil)
        #expect(unchanged.replacementTransactionHash == nil)
    }

    @Test
    func clockCorrectionDoesNotLeaveMissingPaymentPendingIndefinitely() async throws {
        let database = try WalletDatabase.temporary()
        let target = try await received(database)
        let now = Date()
        _ = try await database.recordPendingObservation(.notFound, target: target, now: now.addingTimeInterval(3600))
        _ = try await database.recordPendingObservation(.notFound, target: target, now: now)
        #expect(try await displayed(database, target: target)?.status == .pending)
        _ = try await database.recordPendingObservation(.notFound, target: target, now: now.addingTimeInterval(16))
        #expect(try await displayed(database, target: target)?.status == .notFound)
    }

    @Test
    func replacementRequiresASharedInputAndExplicitConfirmationEvidence() throws {
        let original = try #require(BitcoinRawTransaction(hex: Self.raw))
        func candidate(previous: String, confirmed: Bool, block: Bool) -> JSONValue {
            var status: [String: JSONValue] = ["confirmed": .bool(confirmed)]
            if block { status["block_height"] = .number(900000); status["block_hash"] = .string(String(repeating: "c", count: 64)) }
            return .object(["txid": .string(String(repeating: "b", count: 64)),
                "vin": .array([.object(["txid": .string(previous), "vout": .number(0)])]), "status": .object(status)])
        }
        #expect(try PendingBitcoinConflictReader.verifiedConflict(original: original,
            candidate: candidate(previous: String(repeating: "d", count: 64), confirmed: false, block: false)) == nil)
        let pending = try #require(try PendingBitcoinConflictReader.verifiedConflict(original: original,
            candidate: candidate(previous: String(repeating: "1", count: 64), confirmed: false, block: false)))
        #expect(!pending.confirmed)
        #expect(throws: (any Error).self) {
            try PendingBitcoinConflictReader.verifiedConflict(original: original,
                candidate: candidate(previous: String(repeating: "1", count: 64), confirmed: true, block: false))
        }
        #expect(try PendingBitcoinConflictReader.verifiedConflict(original: original,
            candidate: candidate(previous: String(repeating: "1", count: 64), confirmed: true, block: true))?.confirmed == true)
    }

    @Test
    func allMissingProvidersDifferFromMissingPlusOutageOrMempoolPresence() async throws {
        func attempt(_ suffix: String, _ status: SendTransactionNetworkStatus?) -> AdaptiveProviderAttempt<SendTransactionNetworkStatus> {
            .init(endpoint: .init(serviceID: "fixture-reconciliation", endpointURL: URL(string: "https://\(suffix).invalid")!, baselinePriority: 0)) {
                if let status { return status }; throw URLError(.timedOut)
            }
        }
        #expect(try await SendStatusReadResolver.resolve(attempts: [attempt("a", .notFound), attempt("b", .notFound)]) == .notFound)
        #expect(try await SendStatusReadResolver.resolve(attempts: [attempt("a", .notFound), attempt("b", .pending)]) == .pending)
        await #expect(throws: (any Error).self) {
            try await SendStatusReadResolver.resolve(attempts: [attempt("a", .notFound), attempt("b", nil)])
        }
    }

    private static let raw = "0200000001" + String(repeating: "11", count: 32) + "0000000000fdffffff013b2e000000000000015100000000"

    private func received(_ database: WalletDatabase, network: String = "eth") async throws -> SendPendingStatusTarget {
        let asset = try SendRecipientHistoryTestFixtures.asset(networkID: network)
        let scope = try await SendRecipientHistoryTestFixtures.seed(database, asset: asset)
        let hash = String(repeating: "a", count: 64)
        let record = SendRecipientHistoryTestFixtures.transaction(id: "received-" + network, hash: hash, scope: scope,
            kind: "received", direction: "incoming", status: "pending", amount: "0.00011835")
        try await SendRecipientHistoryTestFixtures.save([record], in: database)
        return try #require(try await database.pool.read {
            try WalletDatabase.pendingStatusTargets(in: $0).first { $0.transactionID == record.id }
        })
    }

    private func displayed(_ database: WalletDatabase, target: SendPendingStatusTarget) async throws -> WalletTransaction? {
        var iterator = database.pendingActivityTransaction(id: try #require(target.transactionID)).makeAsyncIterator()
        return try await iterator.next() ?? nil
    }

    private func wait(_ condition: () async throws -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while try await !condition() {
            try #require(ContinuousClock.now < end)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
