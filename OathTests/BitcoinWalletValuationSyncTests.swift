import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.timeLimit(.minutes(1)))
struct BitcoinWalletValuationSyncTests {
    @Test
    @MainActor
    func replacedIncomingPaymentRefreshesToZeroAfterRelaunchWithoutSendScreen() async throws {
        let fixture = try await Fixture.make()
        try await fixture.database.saveAssetUSDPrice(Fixture.quote())
        try await fixture.database.saveBitcoinFamilyBalance(BitcoinFamilyAtomicInteger(Int64(11_835)),
            material: Fixture.material, walletID: fixture.walletID)
        #expect(try await fixture.fiatValue() != "0")
        let scope = SendRecipientHistoryScope(walletID: fixture.walletID, networkID: "bitcoin")
        let record = SendRecipientHistoryTestFixtures.transaction(id: "replaced-incoming", hash: String(repeating: "a", count: 64),
            scope: scope, kind: "received", direction: "incoming", status: "pending", amount: "0.00011835")
        try await SendRecipientHistoryTestFixtures.save([record], in: fixture.database)
        let target = try #require(try await fixture.database.pool.read {
            try WalletDatabase.pendingStatusTargets(in: $0).first
        })
        _ = try await fixture.database.recordPendingObservation(.canceled, target: target)
        _ = try await fixture.database.updateSubmittedSendStatus(receipt: target.receipt, status: .canceled)
        // The app terminates after the status write, before refreshing balance.
        // A new monitor must find the durable job even though no tx is pending.
        let attempts = BalanceAttempts()
        let monitor = SendPendingStatusMonitor(balanceReader: { database, target in
            if await attempts.next() == 1 {
                // A transient provider error must not erase the positive cache
                // or acknowledge the refresh job.
                return .failure(.bitcoinFamily, stage: .providerRead, error: URLError(.timedOut))
            }
            do {
                try BitcoinFamilySyncService.validateBalanceTransition(
                    previousBalance: BitcoinFamilyAtomicInteger(Int64(11_835)),
                    fetchedBalance: BitcoinFamilyAtomicInteger(Int64(0)), hasHistoryEvidence: false)
                try BitcoinFamilySyncService.validateZeroBalanceHistoryEvidence(.array([]))
                try await database.saveBitcoinFamilySnapshot(.init(material: Fixture.material,
                    balanceAtomic: BitcoinFamilyAtomicInteger(Int64(0)), history: []), walletID: fixture.walletID)
                return .success(.bitcoinFamily, didPersistData: true)
            } catch { Issue.record(error); return .cancelled(.bitcoinFamily) }
        }, reader: { _ in Issue.record("No pending status should remain"); return .pending })
        var publications = 0
        let task = Task { await monitor.run(database: fixture.database, onUpdate: { publications += 1 }) }
        defer { task.cancel() }
        let end = ContinuousClock.now.advanced(by: .seconds(12))
        while try await fixture.fiatValue() != "0" || publications == 0 {
            try #require(ContinuousClock.now < end)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await attempts.count >= 2)
        #expect(try await fixture.database.bitcoinFamilyPersistedBalance(walletID: fixture.walletID)?.decimalText == "0")
        #expect(try await fixture.database.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pendingTransactionEvidence WHERE balanceNeedsRefresh = 1")
        } == 0)
        #expect(try await fixture.database.pool.read {
            try DBTransactionRecord.fetchOne($0, key: record.id)?.status
        } == "canceled", "Retain the rejected payment in history")
    }

    private actor BalanceAttempts {
        var count = 0
        func next() -> Int { count += 1; return count }
    }

    @Test(arguments: BitcoinFamilyChain.allCases)
    func canceledFirstDepositClearsCoinAndFiatForEveryBitcoinFamilyChain(_ chain: BitcoinFamilyChain) async throws {
        let database = try WalletDatabase.temporary()
        let asset = try SendRecipientHistoryTestFixtures.asset(networkID: chain.networkID)
        let scope = try await SendRecipientHistoryTestFixtures.seed(database, asset: asset)
        let material = BitcoinFamilyAccountMaterial(chain: chain, address: SendEntryTestFixtures.address(for: chain.blockchain),
            derivationPath: "", publicKey: "", scriptPubKey: Data([0x51]))
        try await database.saveAssetUSDPrice(.init(assetID: chain.networkID + ":native", price: 100,
            provider: "fixture", observedAt: Date()))
        try await database.saveBitcoinFamilyBalance(BitcoinFamilyAtomicInteger(Int64(11_835)), material: material, walletID: scope.walletID)
        try BitcoinFamilySyncService.validateBalanceTransition(previousBalance: BitcoinFamilyAtomicInteger(Int64(11_835)),
            fetchedBalance: BitcoinFamilyAtomicInteger(Int64(0)), hasHistoryEvidence: false)
        try await database.saveBitcoinFamilySnapshot(.init(material: material,
            balanceAtomic: BitcoinFamilyAtomicInteger(Int64(0)), history: []), walletID: scope.walletID)
        let holding = try #require(try await database.pool.read { try DBAccountAssetRecord.fetchOne($0,
            key: ["accountID": SendRecipientHistoryTestFixtures.accountID(networkID: chain.networkID),
                  "assetID": chain.networkID + ":native"]) })
        #expect(holding.balanceAtomic == "0")
        #expect(holding.fiatUSDValue == "0")
    }

    @Test
    func fiatPublishesWhileHistoryIsStillBlocked() async throws {
        let fixture = try await Fixture.make()
        let balanceReady = AsyncStream<Void>.makeStream()
        let historyRelease = AsyncStream<Void>.makeStream()
        let events = Events()
        let outcome = await BitcoinWalletValuationSync.run(
            databaseProvider: { fixture.database },
            onProgress: { event in
                #expect(event.stage == .valuationPersisted)
                do {
                    #expect(try await fixture.fiatValue() == "15776.416")
                } catch { Issue.record(error) }
                #expect(await events.historyFinished == false)
                await events.didPublish()
                historyRelease.continuation.finish()
            },
            quoteProvider: { asset in
                for await _ in balanceReady.stream {}
                #expect(asset.id == "bitcoin:native")
                return Fixture.quote()
            },
            synchronize: {
                do {
                    try await fixture.saveBalance()
                    balanceReady.continuation.finish()
                    // History cannot finish until fiat is already published.
                    for await _ in historyRelease.stream {}
                    await events.didFinishHistory()
                    return .success(.bitcoinFamily, didPersistData: true)
                } catch {
                    balanceReady.continuation.finish()
                    historyRelease.continuation.finish()
                    Issue.record(error)
                    return .cancelled(.bitcoinFamily)
                }
            }
        )
        #expect(outcome.failures.isEmpty)
        #expect(await events.publications == 1)
        #expect(await events.historyFinished)
    }

    @Test
    func quoteArrivingBeforeBalanceIsUsedByFirstBalanceWrite() async throws {
        let fixture = try await Fixture.make()
        let quoteReady = AsyncStream<Void>.makeStream()
        let outcome = await BitcoinWalletValuationSync.run(
            databaseProvider: { fixture.database },
            onProgress: { _ in quoteReady.continuation.finish() },
            quoteProvider: { _ in Fixture.quote() },
            synchronize: {
                for await _ in quoteReady.stream {}
                do {
                    try await fixture.saveBalance()
                    #expect(try await fixture.fiatValue() == "15776.416")
                    return .success(.bitcoinFamily, didPersistData: true)
                } catch {
                    Issue.record(error)
                    return .cancelled(.bitcoinFamily)
                }
            }
        )
        #expect(outcome.failures.isEmpty)
    }

    @Test
    func providerFailurePreservesNativeBalanceAndReportsFailure() async throws {
        let fixture = try await Fixture.make()
        try await fixture.saveBalance()
        let outcome = await BitcoinWalletValuationSync.run(
            databaseProvider: { fixture.database },
            onProgress: { _ in Issue.record("Failed quote must not publish valuation") },
            quoteProvider: { _ in
                throw AssetPriceError.providerFailure(
                    provider: "coinbase", reason: .httpStatus, statusCode: 429
                )
            },
            synchronize: { .success(.bitcoinFamily, didPersistData: true) }
        )
        #expect(outcome.didPersistData)
        #expect(outcome.failures.count == 1)
        #expect(outcome.failures.first?.stage == .providerRead)
        #expect(outcome.failures.first?.publicCode == "price_coinbase_httpStatus_429")
        #expect(outcome.failures.first?.kind == .providerRejected)
        #expect(try await fixture.database.bitcoinFamilyPersistedBalance(
            walletID: fixture.walletID
        )?.decimalText == "20000000")
        #expect(try await fixture.database.cachedAssetUSDPrice(
            assetID: "bitcoin:native"
        ) == nil)
    }

    @Test(arguments: ["zero", "negative", "wrong-asset"])
    func invalidQuotesNeverBecomeFiatBalances(_ scenario: String) async throws {
        let fixture = try await Fixture.make()
        let outcome = await BitcoinWalletValuationSync.run(
            databaseProvider: { fixture.database },
            onProgress: { _ in Issue.record("Invalid quote was published") },
            quoteProvider: { _ in
                AssetUSDPrice(
                    assetID: scenario == "wrong-asset" ? "eth:native" : "bitcoin:native",
                    price: scenario == "zero" ? 0 : (scenario == "negative" ? -1 : 2000),
                    provider: "fixture", observedAt: Date()
                )
            },
            synchronize: { .success(.bitcoinFamily, didPersistData: true) }
        )
        #expect(outcome.failures.count == 1)
        #expect(try await fixture.database.cachedAssetUSDPrice(
            assetID: "bitcoin:native"
        ) == nil)
    }

    @Test
    func cancelledSyncDoesNotPublishLatePrice() async throws {
        let fixture = try await Fixture.make()
        let started = AsyncStream<Void>.makeStream()
        let events = Events()
        let task = Task {
            await BitcoinWalletValuationSync.run(
                databaseProvider: { fixture.database },
                onProgress: { _ in await events.didPublish() },
                quoteProvider: { _ in
                    started.continuation.finish()
                    try await Task.sleep(for: .seconds(60))
                    return Fixture.quote()
                },
                synchronize: { .success(.bitcoinFamily, didPersistData: true) }
            )
        }
        for await _ in started.stream {}
        task.cancel()
        _ = await task.value
        #expect(await events.publications == 0)
        #expect(try await fixture.database.cachedAssetUSDPrice(
            assetID: "bitcoin:native"
        ) == nil)
    }

    @Test
    func identicalCachedQuoteCanBeReappliedWithoutDuplicateFailure() async throws {
        let fixture = try await Fixture.make()
        let quote = Fixture.quote()
        try await fixture.database.saveAssetUSDPrice(quote)
        try await fixture.saveBalance()
        // Model a holding refreshed since the original quote observation.
        try await fixture.database.pool.write { db in
            try db.execute(sql: "UPDATE accountAssets SET fiatUSDValue = NULL")
        }
        let outcome = await BitcoinWalletValuationSync.run(
            databaseProvider: { fixture.database },
            onProgress: nil,
            quoteProvider: { _ in quote },
            synchronize: { .success(.bitcoinFamily, didPersistData: true) }
        )
        #expect(outcome.failures.isEmpty)
        #expect(try await fixture.fiatValue() == "15776.416")
        let count = try await fixture.database.pool.read { db in
            try DBAssetPriceRecord.fetchCount(db)
        }
        #expect(count == 1)
    }

    @Test
    func concurrentPriceAndBalanceWritesAlwaysAgree() async throws {
        let fixture = try await Fixture.make()
        for index in 1...20 {
            let balance = BitcoinFamilyAtomicInteger(UInt64(index * 1_000_000))
            let quote = AssetUSDPrice(
                assetID: "bitcoin:native", price: Fixture.quote().price + Decimal(index),
                provider: "fixture", observedAt: Date()
            )
            async let price: Void = fixture.database.saveAssetUSDPrice(quote)
            async let holding: Void = fixture.database.saveBitcoinFamilyBalance(
                balance, material: Fixture.material, walletID: fixture.walletID
            )
            _ = try await (price, holding)
            let expected = Decimal(index) / 100 * quote.price
            #expect(try await fixture.fiatValue() == NSDecimalNumber(decimal: expected).stringValue)
        }
        try await fixture.database.saveBitcoinFamilySnapshot(
            BitcoinFamilyChainSnapshot(
                material: Fixture.material,
                balanceAtomic: BitcoinFamilyAtomicInteger(Int64(30_000_000)),
                history: []
            ),
            walletID: fixture.walletID
        )
        #expect(try await fixture.fiatValue() == "23670.624")
    }

    #if LIVE_MAINNET_TESTS
    @Test
    func liveColdBitcoinQuoteValuesImportedBalanceBeforeHistory() async throws {
        let fixture = try await Fixture.make()
        try await fixture.saveBalance()
        let client = AssetPriceClient(database: fixture.database)
        let historyRelease = AsyncStream<Void>.makeStream()
        let events = Events()
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await BitcoinWalletValuationSync.run(
            databaseProvider: { fixture.database },
            onProgress: { _ in
                defer { historyRelease.continuation.finish() }
                do {
                let cached = try #require(try await fixture.database.cachedAssetUSDPrice(
                    assetID: "bitcoin:native"
                ))
                #expect(cached.price > 0)
                let fiatText = try await fixture.fiatValue()
                let fiat = try #require(fiatText.flatMap {
                    Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX"))
                })
                #expect(fiat == Decimal(string: "0.2")! * cached.price)
                #expect(await events.historyFinished == false)
                print("Live BTC fiat published after \(started.duration(to: clock.now)); provider=\(cached.provider)")
                await events.didPublish()
                } catch { Issue.record(error) }
            },
            quoteProvider: { asset in
                do { return try await client.usdPrice(for: asset) }
                catch {
                    historyRelease.continuation.finish()
                    throw error
                }
            },
            synchronize: {
                for await _ in historyRelease.stream {}
                await events.didFinishHistory()
                return .success(.bitcoinFamily, didPersistData: true)
            }
        )
        #expect(outcome.failures.isEmpty)
        #expect(await events.publications == 1)
    }
    #endif

    private actor Events {
        var publications = 0
        var historyFinished = false
        func didPublish() { publications += 1 }
        func didFinishHistory() { historyFinished = true }
    }

    private struct Fixture: Sendable {
        let database: WalletDatabase
        let walletID: String
        static let address = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"
        static let material = BitcoinFamilyAccountMaterial(
            chain: .bitcoin, address: address, derivationPath: "m/84'/0'/0'/0/0",
            publicKey: "", scriptPubKey: Data([0x00, 0x14]) + Data(repeating: 3, count: 20)
        )
        static func quote() -> AssetUSDPrice {
            AssetUSDPrice(
                assetID: "bitcoin:native", price: Decimal(string: "78882.08")!,
                provider: "fixture", observedAt: Date()
            )
        }
        func saveBalance() async throws {
            try await database.saveBitcoinFamilyBalance(
                BitcoinFamilyAtomicInteger(Int64(20_000_000)),
                material: Self.material, walletID: walletID
            )
        }
        func fiatValue() async throws -> String? {
            try await database.pool.read { db in
                try DBAccountAssetRecord.fetchOne(
                    db, key: ["accountID": "\(walletID):bitcoin:0", "assetID": "bitcoin:native"]
                )?.fiatUSDValue
            }
        }
        static func make() async throws -> Fixture {
            let database = try WalletDatabase.temporary()
            let walletID = UUID().uuidString
            let now = Date().timeIntervalSince1970
            try await database.pool.write { db in
                try DBWalletRecord(
                    id: walletID, profileID: WalletDatabase.defaultProfileID,
                    name: "Fiat Timing Fixture", kind: DatabaseWalletKind.importedRecoveryPhrase.rawValue,
                    secretKeyReference: nil, isSelected: true, sortOrder: 0,
                    createdAt: now, updatedAt: now, lastOpenedAt: now, archivedAt: nil
                ).insert(db)
                try DBWalletAccountRecord(
                    id: "\(walletID):bitcoin:0", walletID: walletID, networkID: "bitcoin",
                    address: address, normalizedAddress: address, label: nil,
                    derivationPath: "m/84'/0'/0'/0/0", accountIndex: 0, publicKey: nil,
                    isWatchOnly: false, isEnabled: true, createdAt: now,
                    updatedAt: now, lastSyncedAt: nil
                ).insert(db)
                try DBAssetRecord(
                    id: "bitcoin:native", networkID: "bitcoin",
                    assetType: DatabaseAssetType.native.rawValue,
                    contractAddress: "", normalizedContractAddress: "",
                    name: "Bitcoin", symbol: "BTC", decimals: 8,
                    trustWalletBlockchain: WalletBlockchain.bitcoin.rawValue,
                    trustWalletContractAddress: nil, isVerified: true, isSpam: false,
                    createdAt: now, updatedAt: now, metadataUpdatedAt: now
                ).save(db)
            }
            return Fixture(database: database, walletID: walletID)
        }
    }
}
