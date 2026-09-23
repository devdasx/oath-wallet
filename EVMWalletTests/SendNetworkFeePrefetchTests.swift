import Foundation
import GRDB
import Testing
@testable import Aperture

struct SendNetworkFeePrefetchTests {
    @Test
    func sendOnAnEmptyCacheUsesDefaultsWithoutAnyProviderRequests() async throws {
        let database = try WalletDatabase.temporary()
        let probe = NetworkFeeCacheProbe()
        let repository = SendNetworkFeeQuoteRepository { try await probe.load($0) }
        for networkID in ReceiveNetworkCatalog.catalogNetworkIdentifiers {
            let quote = try await repository.quote(for: networkID, database: database)
            #expect(quote.provider == SendNetworkFeeAPIClient.builtInDefaultProvider)
            #expect(SendNetworkFeeAPIClient.isValid(quote, expectedNetworkID: networkID))
            #expect(quote.tiers == (try SendNetworkFeeAPIClient.defaultQuote(for: networkID)).tiers)
        }
        #expect(await probe.count == 0)
        #expect(Set(ReceiveNetworkCatalog.catalogNetworkIdentifiers) == SendNetworkFeeAPIClient.supportedQuoteNetworkIDs)
    }

    @Test
    func foregroundRefreshPersistsAllNetworksAndSendNeverRefetches() async throws {
        let database = try WalletDatabase.temporary()
        let probe = NetworkFeeCacheProbe()
        let repository = SendNetworkFeeQuoteRepository { try await probe.load($0) }
        await repository.refresh(database: database)
        for networkID in ReceiveNetworkCatalog.catalogNetworkIdentifiers {
            let stored = try #require(try await database.networkFeeRecord(for: networkID))
            let received = try await repository.quote(for: networkID, database: database)
            #expect(stored.quote == received)
            #expect(stored.lastAttemptSucceeded)
            #expect(received.provider == "fixture-provider")
        }
        await repository.refresh(database: database)
        #expect(await probe.count == ReceiveNetworkCatalog.catalogNetworkIdentifiers.count)
        #expect(await probe.maximumConcurrentRequests <= 4)
    }

    @Test
    func concurrentDashboardAndForegroundRefreshesCoalesce() async throws {
        let database = try WalletDatabase.temporary()
        let probe = NetworkFeeCacheProbe(delay: .milliseconds(30))
        let repository = SendNetworkFeeQuoteRepository { try await probe.load($0) }
        async let first: Void = repository.refresh(database: database, force: true)
        async let second: Void = repository.refresh(database: database, force: true)
        _ = await (first, second)
        #expect(await probe.count == ReceiveNetworkCatalog.catalogNetworkIdentifiers.count)
        #expect(await probe.maximumConcurrentRequests <= 4)
    }

    @Test
    func sendDoesNotWaitForAnInFlightRefresh() async throws {
        let database = try WalletDatabase.temporary()
        let gate = NetworkFeeCacheGate()
        let repository = SendNetworkFeeQuoteRepository { networkID in
            await gate.pause()
            return try Self.quote(networkID)
        }
        let refreshing = Task { await repository.refresh(database: database) }
        await gate.waitForStart()
        // This read must complete before the provider is released, not merely
        // issue zero additional requests while awaiting its result.
        let read = Task { try await repository.quote(for: "bitcoin", database: database) }
        let result = try await withThrowingTaskGroup(of: SendNetworkFeeQuote.self) { group in
            group.addTask { try await read.value }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                await gate.release()
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try #require(try await group.next())
        }
        #expect(result.provider == SendNetworkFeeAPIClient.builtInDefaultProvider)
        await gate.release()
        await refreshing.value
    }

    @Test
    func quoteSurvivesDatabaseAndRepositoryReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try WalletDatabase.applicationDatabase(at: directory)
        let quote = try Self.quote("eth")
        try await Self.save(quote, in: database)
        let reopened = try WalletDatabase.applicationDatabase(at: directory)
        let probe = NetworkFeeCacheProbe()
        let repository = SendNetworkFeeQuoteRepository { try await probe.load($0) }
        #expect(try await repository.quote(for: "eth", database: reopened) == quote)
        #expect(await probe.count == 0)
    }

    @Test
    func failedRefreshKeepsAUsableSavedQuoteAndDefaultsOnlyMissingNetworks() async throws {
        let database = try WalletDatabase.temporary()
        let saved = try Self.quote("bitcoin", now: Date().addingTimeInterval(-90))
        try await Self.save(saved, in: database)
        let repository = SendNetworkFeeQuoteRepository { _ in throw URLError(.notConnectedToInternet) }
        await repository.refresh(database: database, force: true)
        #expect(try await repository.quote(for: "bitcoin", database: database) == saved)
        #expect(try await database.networkFeeRecord(for: "bitcoin")?.lastAttemptSucceeded == false)
        let missing = try await repository.quote(for: "solana", database: database)
        #expect(missing.provider == SendNetworkFeeAPIClient.builtInDefaultProvider)
    }

    @Test
    func builtInProviderFallbackCannotOverwriteTheLastSuccessfulQuote() async throws {
        let database = try WalletDatabase.temporary()
        let saved = try Self.quote("arc")
        try await Self.save(saved, in: database)
        let repository = SendNetworkFeeQuoteRepository { try SendNetworkFeeAPIClient.defaultQuote(for: $0) }
        await repository.refresh(database: database, force: true)
        #expect(try await repository.quote(for: "arc", database: database) == saved)
        #expect(try await database.networkFeeRecord(for: "arc")?.lastAttemptSucceeded == false)
    }

    @Test(arguments: [0.0, 45.0, 899.0, 900.0, 901.0])
    func savedQuotesHaveABoundedReuseWindowWithoutChangingTimestamps(age: TimeInterval) async throws {
        let database = try WalletDatabase.temporary()
        let sampledAt = Date().addingTimeInterval(-age)
        let quote = try Self.quote("eth", now: sampledAt)
        try await Self.save(quote, in: database, now: sampledAt)
        let now = sampledAt.addingTimeInterval(age)
        let result = try await SendNetworkFeeQuoteRepository().quote(for: "eth", database: database, now: now)
        if age <= WalletNetworkFeeCachePolicy.maximumReuseAge {
            #expect(result == quote)
            #expect(result.fetchedAt == sampledAt)
        } else {
            #expect(result.provider == SendNetworkFeeAPIClient.builtInDefaultProvider)
        }
    }

    @Test
    func corruptWrongNetworkAndFutureDatedPayloadsCannotBecomeSendFees() async throws {
        let database = try WalletDatabase.temporary()
        let now = Date()
        let payloads = [
            "{broken-json}",
            String(repeating: "x", count: 16_385),
            String(decoding: try JSONEncoder().encode(Self.quote("bsc")), as: UTF8.self),
            String(decoding: try JSONEncoder().encode(Self.quote("eth", now: now.addingTimeInterval(120))), as: UTF8.self)
        ]
        for payload in payloads {
            try await database.pool.write { db in
                try WalletNetworkFeeRecord(networkID: "eth", payload: payload,
                    lastAttemptAt: now.timeIntervalSince1970, lastAttemptSucceeded: true).save(db)
            }
            let result = try await SendNetworkFeeQuoteRepository().quote(for: "eth", database: database, now: now)
            #expect(result.provider == SendNetworkFeeAPIClient.builtInDefaultProvider)
        }
    }

    @Test
    func invalidTierAndLateResultCannotReplaceANewerRate() async throws {
        let database = try WalletDatabase.temporary()
        let quote = try Self.quote("eth")
        try await Self.save(quote, in: database)
        let invalid = SendNetworkFeeQuote(networkID: "eth", provider: "fixture-provider",
            fetchedAt: Date(), expiresAt: Date().addingTimeInterval(30), tiers: [
                SendNetworkFeeTier(preset: .standard, model: .evmEIP1559, primaryValue: "-1", secondaryValue: "0")
            ])
        try await Self.save(invalid, in: database)
        try await Self.save(Self.quote("eth", now: quote.fetchedAt.addingTimeInterval(-10)), in: database)
        #expect(try await database.networkFeeRecord(for: "eth")?.quote == quote)
    }

    @Test
    func databaseReadFailureReturnsDefaults() async throws {
        let database = try WalletDatabase.temporary()
        try await database.pool.write { try $0.execute(sql: "DROP TABLE networkFeeQuotes") }
        let quote = try await SendNetworkFeeQuoteRepository().quote(for: "eth", database: database)
        #expect(quote.provider == SendNetworkFeeAPIClient.builtInDefaultProvider)
    }

    @Test
    func resetClearsQuotesAndRejectsAnOldRefreshGeneration() async throws {
        let database = try WalletDatabase.temporary()
        let quote = try Self.quote("bitcoin")
        try await Self.save(quote, in: database)
        let generation = database.applicationSettingsPersistenceGeneration()
        database.beginAppReset()
        try await database.eraseAllData()
        database.finishAppReset()
        try await database.saveNetworkFeeAttempt(networkID: "bitcoin", quote: quote, expectedGeneration: generation)
        #expect(try await database.networkFeeRecord(for: "bitcoin") == nil)
    }

    @Test
    func customFeePreferencesRemainAuthoritativeWithoutDisablingTheGlobalCache() async throws {
        let database = try WalletDatabase.temporary()
        let preferences = SendNetworkFeePreferenceRepository(database: database)
        let custom = SendNetworkFeeCustomValue(model: .utxoPerVByte, primaryValue: "7", secondaryValue: nil,
                                               totalBudgetAtomic: "10000")
        try await preferences.saveCustom(custom, for: "bitcoin")
        try await Self.save(Self.quote("bitcoin"), in: database)
        let policy = try await preferences.policy(for: "bitcoin")
        let quote = try await SendNetworkFeeQuoteRepository().quote(for: "bitcoin", database: database)
        let resolved = try SendResolvedNetworkFee.resolve(policy: policy, quote: quote)
        #expect(resolved.primaryValue == "7")
        #expect(resolved.totalBudgetAtomic == "10000")
        #expect(quote.provider == "fixture-provider")
    }

    @Test
    func cachedTronPricesSurviveEncodingCustomBudgetAndAuthorization() async throws {
        let database = try WalletDatabase.temporary()
        let parameters = SendTronProtocolParameters(energyPrice: 125, bandwidthPrice: 1_500,
            accountCreationFee: 2_000_000, accountCreationBandwidthFee: 200_000, accountCreationBandwidthRate: 2)
        let now = Date()
        let quote = SendNetworkFeeQuote(networkID: "tron", provider: "fixture-provider", fetchedAt: now,
            expiresAt: now.addingTimeInterval(60), tiers: [SendNetworkFeePreset.economy, .standard, .fastest].map {
                SendNetworkFeeTier(preset: $0, model: .tronProtocol, primaryValue: "125", secondaryValue: "1500")
            }, tronParameters: parameters)
        try await Self.save(quote, in: database)
        let cached = try await SendNetworkFeeQuoteRepository().quote(for: "tron", database: database)
        #expect(cached.tronParameters == parameters)
        let policy = SendNetworkFeePolicy.custom(SendNetworkFeeCustomValue(model: .tronFeeLimit,
            primaryValue: "30000000", secondaryValue: nil, totalBudgetAtomic: "30000000"))
        let fee = try SendResolvedNetworkFee.resolve(policy: policy, quote: cached)
        let draft = SendNetworkFeeTests.customFeeDraft(networkID: "tron", blockchain: .tron, policy: policy)
            .replacingPreparedNetworkFee(fee)
        #expect(try SendSubmissionNetworkFee.resolve(draft: draft).resolvedTronParameters(isCustom: true) == parameters)
        #expect(try SendSubmissionNetworkFee.resolve(draft: draft).primaryValue == "30000000")
        let changed = draft.replacingPreparedNetworkFee(fee.withTronParameters(.defaults))
        #expect(try SendReviewedDraftDigest.make(draft) != SendReviewedDraftDigest.make(changed))
    }

    static func quote(_ networkID: String, now: Date = Date()) throws -> SendNetworkFeeQuote {
        let fallback = try SendNetworkFeeAPIClient.defaultQuote(for: networkID, now: now)
        return SendNetworkFeeQuote(networkID: networkID, provider: "fixture-provider", fetchedAt: now,
            expiresAt: now.addingTimeInterval(30), tiers: fallback.tiers, tronParameters: fallback.tronParameters)
    }

    static func save(_ quote: SendNetworkFeeQuote, in database: WalletDatabase, now: Date = Date()) async throws {
        try await database.saveNetworkFeeAttempt(networkID: quote.networkID, quote: quote,
            expectedGeneration: database.applicationSettingsPersistenceGeneration(), now: now)
    }
}

private actor NetworkFeeCacheProbe {
    let delay: Duration
    var count = 0
    var concurrentRequests = 0
    var maximumConcurrentRequests = 0
    init(delay: Duration = .zero) { self.delay = delay }
    func load(_ networkID: String) async throws -> SendNetworkFeeQuote {
        count += 1
        concurrentRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, concurrentRequests)
        defer { concurrentRequests -= 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        return try SendNetworkFeePrefetchTests.quote(networkID)
    }
}

private actor NetworkFeeCacheGate {
    var started = false
    var released = false
    var startWaiters: [CheckedContinuation<Void, Never>] = []
    var finishWaiters: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }
    func waitForStart() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() {
        released = true
        finishWaiters.forEach { $0.resume() }
        finishWaiters.removeAll()
    }
}
