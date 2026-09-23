import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct WalletDatabaseResetTests {
    @Test
    func resetDeletesNetworkOwnedNFTGraphAndRecreatesDefaults()
        async throws
    {
        let database = try WalletDatabase.temporary()
        try await seedWalletWithNFT(in: database)

        let before = try await snapshot(database)
        #expect(before.walletCount == 1)
        #expect(before.accountCount == 1)
        #expect(before.nftCollectionCount == 1)
        #expect(before.nftItemCount == 1)
        #expect(before.nftHoldingCount == 1)

        try await database.eraseAllData()

        let after = try await snapshot(database)
        #expect(after.profileCount == 1)
        #expect(after.defaultProfileCount == 1)
        #expect(after.userSettingsCount == 1)
        #expect(after.walletCount == 0)
        #expect(after.accountCount == 0)
        #expect(after.nftCollectionCount == 0)
        #expect(after.nftItemCount == 0)
        #expect(after.nftHoldingCount == 0)
        #expect(after.referenceNetworkCount > 0)
        #expect(
            after.referenceCatalogEntryCount
                == before.referenceCatalogEntryCount
        )
        #expect(after.foreignKeyViolationCount == 0)
    }

    @Test
    func appResetPreservesDurableCurrencyRates() async throws {
        let database = try WalletDatabase.temporary()
        let fetchedAt = Date(timeIntervalSince1970: 1_788_566_400)
        try await database.saveFXRates(
            FXRatesSnapshot(
                fetchedAt: fetchedAt,
                currencies: [
                    FXCurrencyRate(
                        code: "EUR",
                        englishName: "Euro",
                        symbol: "€",
                        ratePerUSD: Decimal(string: "0.91")!,
                        rateDate: "2026-09-04"
                    )
                ]
            )
        )

        try await database.eraseAllData()

        let cachedSnapshot = try await database.cachedFXRates()
        let cached = try #require(cachedSnapshot)
        #expect(cached.fetchedAt == fetchedAt)
        #expect(cached.currency(for: "EUR")?.ratePerUSD == 0.91)
        #expect(cached.currency(for: "USD")?.ratePerUSD == 1)
    }

    @Test
    func residualNFTVerificationRollsBackTheEntireReset()
        async throws
    {
        let database = try WalletDatabase.temporary()
        try await seedWalletWithNFT(in: database)
        try await database.pool.write { database in
            try database.execute(
                sql: """
                CREATE TRIGGER preserve_nft_collection_during_reset
                BEFORE DELETE ON nftCollections
                BEGIN
                    SELECT RAISE(IGNORE);
                END
                """
            )
        }

        var resetFailure: WalletDatabaseResetError?
        do {
            try await database.eraseAllData()
            Issue.record(
                "Reset unexpectedly succeeded with an undeletable NFT graph."
            )
        } catch let error as WalletDatabaseResetError {
            resetFailure = error
        } catch {
            Issue.record(
                "Reset returned an unexpected error type: \(type(of: error))"
            )
        }

        guard case let .verificationFailed(residuals)? = resetFailure else {
            Issue.record(
                "Reset did not return the expected residual-record failure."
            )
            return
        }
        #expect(
            residuals.contains {
                $0.tableName == "nftCollections"
                    && $0.recordCount == 1
            }
        )
        #expect(
            residuals.contains {
                $0.tableName == "nftItems"
                    && $0.recordCount == 1
            }
        )

        // The verification error is thrown inside the same GRDB write
        // transaction. Every earlier cascade and default-profile insert must
        // therefore roll back together.
        let afterFailure = try await snapshot(database)
        #expect(afterFailure.profileCount == 1)
        #expect(afterFailure.defaultProfileCount == 1)
        #expect(afterFailure.userSettingsCount == 1)
        #expect(afterFailure.walletCount == 1)
        #expect(afterFailure.accountCount == 1)
        #expect(afterFailure.nftCollectionCount == 1)
        #expect(afterFailure.nftItemCount == 1)
        #expect(afterFailure.nftHoldingCount == 1)
        #expect(afterFailure.foreignKeyViolationCount == 0)
    }

    @Test
    func stalePreResetSettingsSnapshotCannotResurrectAfterReset()
        async throws
    {
        let database = try WalletDatabase.temporary()
        var staleSettings =
            try database.applicationSettingsSynchronously()
        staleSettings.appearance = .dark
        staleSettings.balancePrivacyEnabled = true
        let staleGeneration =
            database.applicationSettingsPersistenceGeneration()

        try await performGuardedReset(database)

        let result = try await database.saveApplicationSettings(
            staleSettings,
            expectedGeneration: staleGeneration
        )
        #expect(result == .skippedStaleGeneration)
        #expect(
            try database.applicationSettingsSynchronously()
                == WalletApplicationSettings.default
        )
    }

    @Test
    func settingsWritesAreRejectedWhileResetIsInProgress()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let initialSettings =
            try database.applicationSettingsSynchronously()
        var settings = initialSettings
        settings.appearance = .dark

        database.beginAppReset()
        let resetGeneration =
            database.applicationSettingsPersistenceGeneration()
        let result: WalletApplicationSettingsWriteResult
        do {
            result = try await database.saveApplicationSettings(
                settings,
                expectedGeneration: resetGeneration
            )
            database.finishAppReset()
        } catch {
            database.finishAppReset()
            throw error
        }

        #expect(result == .skippedResetInProgress)
        #expect(
            try database.applicationSettingsSynchronously()
                == initialSettings
        )
    }

    @Test
    func freshPostResetSettingsWriteUsesNewGeneration()
        async throws
    {
        let database = try WalletDatabase.temporary()
        try await performGuardedReset(database)

        var settings = try database.applicationSettingsSynchronously()
        settings.appearance = .dark
        settings.balancePrivacyEnabled = true
        let currentGeneration =
            database.applicationSettingsPersistenceGeneration()
        let result = try await database.saveApplicationSettings(
            settings,
            expectedGeneration: currentGeneration
        )

        #expect(result == .persisted)
        #expect(try database.applicationSettingsSynchronously() == settings)
    }

    @Test
    @MainActor
    func sendAmountEntryModePersistsThroughApplicationSettings()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let store = WalletSettingsStore(database: database)

        #expect(store.sendAmountEntryMode == .asset)
        store.setSendAmountEntryMode(.localCurrency)
        #expect(store.sendAmountEntryMode == .localCurrency)
        #expect(await store.flush())

        let restored = try database.applicationSettingsSynchronously()
        #expect(restored.sendAmountEntryMode == .localCurrency)
        let reloadedStore = WalletSettingsStore(database: database)
        #expect(reloadedStore.sendAmountEntryMode == .localCurrency)
    }

    @Test
    @MainActor
    func storeDrainsAndInvalidatesQueuedWritesBeforeReset()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let store = WalletSettingsStore(database: database)
        store.setAppearance(.dark)
        store.setBalancePrivacyEnabled(true)

        await store.prepareForAppReset()
        store.setHapticFeedbackEnabled(false)
        try await performGuardedReset(database)
        store.resetToDatabaseDefaults()
        await Task.yield()

        #expect(store.appearance == .system)
        #expect(store.balancePrivacyEnabled == false)
        #expect(store.hapticFeedbackEnabled == true)
        #expect(
            try database.applicationSettingsSynchronously()
                == WalletApplicationSettings.default
        )
    }

    @Test
    @MainActor
    func appResetPreservesAllowedPreferencesAndWhatsNewVersion()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let store = WalletSettingsStore(database: database)
        defer {
            UniHapticEngine.shared.setEnabled(true)
        }

        store.setAppearance(.dark)
        store.setLanguageIdentifier("fr")
        store.selectCurrency(
            code: "EUR",
            ratePerUSD: Decimal(string: "0.92")!
        )
        store.setHapticFeedbackEnabled(false)
        store.markWhatsNewPresented(version: "3.5.0")

        store.setBalancePrivacyEnabled(true)
        store.setAssetVisibilityPreferencesJSON(
            #"{"ethereum":{"isVisible":false}}"#
        )
        store.setSendAmountEntryMode(.localCurrency)
        store.setCurrencyConverterHomeShortcutEnabled(true)
        store.setNotificationsEnabled(true)
        store.setReceivedTransactionNotificationsEnabled(false)
        store.setSentTransactionNotificationsEnabled(true)
        store.setAdminNotificationsEnabled(false)
        store.markNotificationWelcomePresented()

        let preservedPreferences = await store.prepareForAppReset()
        database.beginAppReset()
        do {
            _ = try await database.commitAppReset(
                cleanupPlan: .empty,
                preservedPreferences: preservedPreferences
            )
            database.finishAppReset()
        } catch {
            database.finishAppReset()
            throw error
        }
        store.resetToDatabaseDefaults(
            preserving: preservedPreferences
        )

        let durable = try database.applicationSettingsSynchronously()
        #expect(durable.appearance == .dark)
        #expect(durable.languageIdentifier == "fr")
        #expect(durable.currencyCode == "EUR")
        #expect(durable.currencyRateStorageValue == "0.92")
        #expect(!durable.hapticFeedbackEnabled)
        #expect(durable.lastPresentedWhatsNewVersion == "3.5.0")

        #expect(!durable.balancePrivacyEnabled)
        #expect(durable.assetVisibilityPreferencesJSON == "{}")
        #expect(durable.sendAmountEntryMode == .asset)
        #expect(!durable.currencyConverterHomeShortcutEnabled)
        #expect(!durable.notificationsEnabled)
        #expect(durable.receivedTransactionNotificationsEnabled)
        #expect(!durable.sentTransactionNotificationsEnabled)
        #expect(durable.adminNotificationsEnabled)
        #expect(!durable.notificationWelcomeWasPresented)
        #expect(!durable.notificationsWereExplicitlyDisabled)

        #expect(store.appearance == durable.appearance)
        #expect(store.languageIdentifier == durable.languageIdentifier)
        #expect(store.currencyCode == durable.currencyCode)
        #expect(
            store.currencyRateStorageValue
                == durable.currencyRateStorageValue
        )
        #expect(
            store.hapticFeedbackEnabled
                == durable.hapticFeedbackEnabled
        )
        #expect(store.lastPresentedWhatsNewVersion == "3.5.0")

        let reloadedStore = WalletSettingsStore(database: database)
        #expect(reloadedStore.appearance == .dark)
        #expect(reloadedStore.languageIdentifier == "fr")
        #expect(reloadedStore.currencyCode == "EUR")
        #expect(reloadedStore.currencyRateStorageValue == "0.92")
        #expect(!reloadedStore.hapticFeedbackEnabled)
        #expect(reloadedStore.lastPresentedWhatsNewVersion == "3.5.0")
    }

    @Test
    @MainActor
    func failedResetRecoveryReloadsDurableSettingsWithoutRewriting()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let store = WalletSettingsStore(database: database)
        store.setAppearance(.dark)
        #expect(await store.flush())

        await store.prepareForAppReset()
        #expect(store.recoverAfterFailedAppReset())
        store.setBalancePrivacyEnabled(true)
        #expect(await store.flush())

        let settings = try database.applicationSettingsSynchronously()
        #expect(settings.appearance == .dark)
        #expect(settings.balancePrivacyEnabled)
    }

    @Test
    func resetProgressStagesAreCompleteAndOrdered() {
        let stages = WalletAppResetProgressStage.allCases

        #expect(
            stages == [
                .preparing,
                .securingCredentials,
                .removingWalletData,
                .clearingLocalData,
                .finishing,
                .complete,
            ]
        )
        #expect(stages.map(\.ordinal) == Array(1...stages.count))
        #expect(stages.allSatisfy { $0.total == stages.count })

        let presentationDurations = stages.map(
            \.minimumPresentationDurationNanoseconds
        )
        #expect(presentationDurations.allSatisfy { $0 > 0 })
        #expect(Set(presentationDurations).count > 1)
    }

    @Test
    func destructiveProgressCompletionTrackerEmitsEachStepOnce() {
        var tracker = WalletDestructiveProgressCompletionTracker<
            WalletAppResetProgressStage
        >()
        var completionCount = 0

        for stage in WalletAppResetProgressStage.allCases {
            if tracker.transition(to: stage) {
                completionCount += 1
            }
            let duplicateTransition = tracker.transition(to: stage)
            #expect(!duplicateTransition)
        }
        if tracker.finish() {
            completionCount += 1
        }

        #expect(
            completionCount == WalletAppResetProgressStage.allCases.count
        )
        let duplicateFinish = tracker.finish()
        let transitionAfterFinish = tracker.transition(to: .complete)
        #expect(!duplicateFinish)
        #expect(!transitionAfterFinish)
    }

    @Test
    func destructiveProgressFailureLeavesActiveStepIncomplete() {
        var tracker = WalletDestructiveProgressCompletionTracker<
            WalletRemovalProgressStage
        >()

        let initialTransition = tracker.transition(to: .preparing)
        let completedPreparing = tracker.transition(
            to: .removingWalletData
        )
        let duplicateActiveStage = tracker.transition(
            to: .removingWalletData
        )
        #expect(!initialTransition)
        #expect(completedPreparing)
        #expect(!duplicateActiveStage)

        // A failure does not call `finish`, so the active removal step does
        // not produce the success event reserved for completed work.
    }

    @Test
    func protectedActionsPreferEnabledAvailableBiometrics() {
        let settings = WalletSecuritySettings(
            appLockEnabled: true,
            biometricEnabled: true,
            autoLockDuration: .minute1,
            privacyShieldEnabled: false
        )
        let availability = WalletBiometricAvailability(
            isAvailable: true,
            kind: .faceID
        )

        #expect(
            WalletAuthenticationRequirementPolicy.requirement(
                settings: settings,
                availability: availability
            ) == .biometrics
        )
    }

    private func seedWalletWithNFT(
        in walletDatabase: WalletDatabase
    ) async throws {
        let timestamp = Date().timeIntervalSince1970
        try await walletDatabase.pool.write { database in
            try DBWalletRecord(
                id: "reset-wallet",
                profileID: WalletDatabase.defaultProfileID,
                name: "Reset Fixture",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: nil,
                isSelected: true,
                sortOrder: 0,
                createdAt: timestamp,
                updatedAt: timestamp,
                lastOpenedAt: timestamp,
                archivedAt: nil
            ).insert(database)
            try DBWalletAccountRecord(
                id: "reset-account",
                walletID: "reset-wallet",
                networkID: "eth",
                address:
                    "0x0000000000000000000000000000000000000001",
                normalizedAddress:
                    "0x0000000000000000000000000000000000000001",
                label: nil,
                derivationPath: "m/44'/60'/0'/0/0",
                accountIndex: 0,
                publicKey: nil,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: timestamp,
                updatedAt: timestamp,
                lastSyncedAt: nil
            ).insert(database)
            try DBNFTCollectionRecord(
                id: "reset-collection",
                networkID: "eth",
                contractAddress:
                    "0x0000000000000000000000000000000000000002",
                normalizedContractAddress:
                    "0x0000000000000000000000000000000000000002",
                name: "Reset Collection",
                symbol: "RESET",
                standard: "erc721",
                imageURL: nil,
                isVerified: true,
                isSpam: false,
                updatedAt: timestamp
            ).insert(database)
            try DBNFTItemRecord(
                id: "reset-item",
                collectionID: "reset-collection",
                tokenID: "1",
                name: "Reset Item",
                description: nil,
                imageURL: nil,
                animationURL: nil,
                metadataURL: nil,
                metadataJSON: nil,
                updatedAt: timestamp
            ).insert(database)
            try DBAccountNFTHoldingRecord(
                accountID: "reset-account",
                nftItemID: "reset-item",
                quantity: "1",
                isHidden: false,
                lastSeenAt: timestamp
            ).insert(database)
        }
    }

    private func performGuardedReset(
        _ database: WalletDatabase
    ) async throws {
        database.beginAppReset()
        do {
            try await database.eraseAllData()
            database.finishAppReset()
        } catch {
            database.finishAppReset()
            throw error
        }
    }

    private func snapshot(
        _ walletDatabase: WalletDatabase
    ) async throws -> ResetDatabaseSnapshot {
        try await walletDatabase.pool.read { database in
            ResetDatabaseSnapshot(
                profileCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM profiles"
                ) ?? 0,
                defaultProfileCount: try Int.fetchOne(
                    database,
                    sql: """
                    SELECT COUNT(*) FROM profiles WHERE id = ?
                    """,
                    arguments: [WalletDatabase.defaultProfileID]
                ) ?? 0,
                userSettingsCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM userSettings"
                ) ?? 0,
                walletCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM wallets"
                ) ?? 0,
                accountCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM walletAccounts"
                ) ?? 0,
                nftCollectionCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM nftCollections"
                ) ?? 0,
                nftItemCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM nftItems"
                ) ?? 0,
                nftHoldingCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM accountNFTHoldings"
                ) ?? 0,
                referenceNetworkCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM networks"
                ) ?? 0,
                referenceCatalogEntryCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM assetCatalogEntries"
                ) ?? 0,
                foreignKeyViolationCount: try Row.fetchAll(
                    database,
                    sql: "PRAGMA foreign_key_check"
                ).count
            )
        }
    }
}

private struct ResetDatabaseSnapshot: Sendable {
    let profileCount: Int
    let defaultProfileCount: Int
    let userSettingsCount: Int
    let walletCount: Int
    let accountCount: Int
    let nftCollectionCount: Int
    let nftItemCount: Int
    let nftHoldingCount: Int
    let referenceNetworkCount: Int
    let referenceCatalogEntryCount: Int
    let foreignKeyViolationCount: Int
}
