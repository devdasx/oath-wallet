import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct WalletDatabaseInitializationTests {
    @Test
    func firstRunSettingsUseDeviceLanguageRegionCurrencyAndSystemAppearance() {
        let israel = WalletFirstRunSettings.resolve(
            locale: Locale(identifier: "he_IL"),
            preferredLanguages: ["he-IL", "en-US"]
        )

        #expect(israel.languageIdentifier == "he")
        #expect(israel.currencyCode == "ILS")
        #expect(israel.appearance == .system)

        let englishInIsrael = WalletFirstRunSettings.resolve(
            locale: Locale(identifier: "en_IL"),
            preferredLanguages: ["en-IL", "he-IL"]
        )
        #expect(englishInIsrael.languageIdentifier == "en")
        #expect(englishInIsrael.currencyCode == "ILS")
        #expect(englishInIsrael.appearance == .system)
    }

    @Test
    func everyShippedLanguageCanBeResolvedAsTheFirstRunLanguage() {
        for identifier in WalletAppLanguage.supportedIdentifiers {
            let settings = WalletFirstRunSettings.resolve(
                locale: Locale(identifier: "en_US"),
                preferredLanguages: [identifier]
            )
            #expect(settings.languageIdentifier == identifier)
        }
    }

    @Test
    @MainActor
    func everyAppearanceSelectionPersistsAcrossRelaunch() async throws {
        let database = try WalletDatabase.temporary()

        for appearance in WalletAppearancePreference.allCases {
            let store = WalletSettingsStore(database: database)
            store.setAppearance(appearance)
            #expect(await store.flush())

            let reloaded = WalletSettingsStore(database: database)
            #expect(reloaded.appearance == appearance)
        }
    }

    @Test
    @MainActor
    func currencyConverterHomeShortcutStartsOffAndPersists() async throws {
        let database = try WalletDatabase.temporary()
        let store = WalletSettingsStore(database: database)

        #expect(!store.currencyConverterHomeShortcutEnabled)

        store.setCurrencyConverterHomeShortcutEnabled(true)
        #expect(store.currencyConverterHomeShortcutEnabled)
        #expect(await store.flush())

        let reloaded = WalletSettingsStore(database: database)
        #expect(reloaded.currencyConverterHomeShortcutEnabled)
    }

    @Test
    @MainActor
    func explicitSelectionsSurviveReseedingRelaunchAndReturningToLocal()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let israel = WalletFirstRunSettings.resolve(
            locale: Locale(identifier: "he_IL"),
            preferredLanguages: ["he-IL"]
        )
        try await database.pool.write { database in
            _ = try DBUserSettingsRecord.deleteOne(
                database,
                key: WalletDatabase.defaultProfileID
            )
        }
        try WalletDatabase.seedReferenceData(
            in: database.pool,
            firstRunSettings: israel
        )

        let firstLaunch = WalletSettingsStore(database: database)
        #expect(firstLaunch.languageIdentifier == "he")
        #expect(firstLaunch.currencyCode == "ILS")
        #expect(firstLaunch.appearance == .system)

        firstLaunch.setLanguageIdentifier("fr")
        firstLaunch.selectCurrency(
            code: "EUR",
            ratePerUSD: Decimal(string: "0.92")!
        )
        firstLaunch.setAppearance(.dark)
        #expect(await firstLaunch.flush())

        let japan = WalletFirstRunSettings.resolve(
            locale: Locale(identifier: "ja_JP"),
            preferredLanguages: ["ja-JP"]
        )
        try WalletDatabase.seedReferenceData(
            in: database.pool,
            firstRunSettings: japan
        )

        let afterRelaunch = WalletSettingsStore(database: database)
        #expect(afterRelaunch.languageIdentifier == "fr")
        #expect(afterRelaunch.currencyCode == "EUR")
        #expect(afterRelaunch.currencyRateStorageValue == "0.92")
        #expect(afterRelaunch.appearance == .dark)

        afterRelaunch.setLanguageIdentifier("he")
        afterRelaunch.selectCurrency(
            code: "ILS",
            ratePerUSD: Decimal(string: "3.72")!
        )
        afterRelaunch.setAppearance(.system)
        #expect(await afterRelaunch.flush())

        let returnedToLocal = WalletSettingsStore(database: database)
        #expect(returnedToLocal.languageIdentifier == "he")
        #expect(returnedToLocal.currencyCode == "ILS")
        #expect(returnedToLocal.currencyRateStorageValue == "3.72")
        #expect(returnedToLocal.appearance == .system)
    }

    @Test
    func applicationDatabaseOpensMigratesAndSeedsNonCatalogReferenceData()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try WalletDatabase.applicationDatabase(
            at: directory
        )
        let snapshot = try await database.pool.read { database in
            (
                networkCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM networks"
                ) ?? 0,
                profileCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM profiles"
                ) ?? 0,
                settingsCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM userSettings"
                ) ?? 0,
                catalogEntryCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM assetCatalogEntries"
                ) ?? 0,
                catalogMetadataCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM assetCatalogMetadata"
                ) ?? 0,
                catalogSyncStateCount: try Int.fetchOne(
                    database,
                    sql: """
                    SELECT COUNT(*)
                    FROM assetCatalogSyncState
                    """
                ) ?? 0
            )
        }

        #expect(snapshot.networkCount > 0)
        #expect(snapshot.profileCount == 1)
        #expect(snapshot.settingsCount == 1)
        #expect(snapshot.catalogEntryCount == 0)
        #expect(snapshot.catalogMetadataCount == 0)
        #expect(snapshot.catalogSyncStateCount == 0)
    }

    @Test
    func freshCatalogCacheStartsEmptyWithoutBundledSeeding()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let snapshot = try await database.pool.read { database in
            (
                tokens: try WalletAssetCatalogPersistence.loadCachedTokens(
                    in: database
                ),
                state: try WalletAssetCatalogPersistence.cacheState(
                    in: database
                )
            )
        }

        #expect(snapshot.tokens.isEmpty)
        #expect(snapshot.state.revision == 0)
        #expect(!snapshot.state.didCompleteInitialSync)
    }

    @Test
    func persistedCatalogReloadUsesTheDeterministicOrderIndex()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let queryPlan = try await database.pool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                EXPLAIN QUERY PLAN
                SELECT *
                FROM assetCatalogEntries
                ORDER BY tokenOrder ASC, variantOrder ASC, assetIdentity ASC
                """
            ).map { row -> String in
                row["detail"]
            }
        }

        #expect(
            queryPlan.contains {
                $0.contains("assetCatalogEntries_order")
            }
        )
        #expect(!queryPlan.contains { $0.contains("TEMP B-TREE") })
    }

    @Test
    func remoteCatalogUpdatePreservesNonCatalogUserData()
        async throws
    {
        let database = try WalletDatabase.temporary()
        try await database.pool.write { database in
            try database.execute(
                sql: """
                UPDATE userSettings
                SET currencyCode = 'EUR'
                WHERE profileID = ?
                """,
                arguments: [WalletDatabase.defaultProfileID]
            )
            try WalletAssetCatalogPersistence.applyRemoteEntries(
                [
                    AssetCatalogRemoteEntry(
                        assetIdentity: "eth:native",
                        tokenID: "native-eth",
                        networkID: "eth",
                        contractAddress: nil,
                        name: "Ethereum",
                        symbol: "ETH",
                        decimals: 18,
                        globalRank: -1_000_000_000,
                        networkRank: 0,
                        isStablecoin: false,
                        logoURL: nil,
                        marketDataID: "ethereum",
                        tokenOrder: 0,
                        variantOrder: 0,
                        source: .curated,
                        isVerified: true,
                        isActive: true,
                        revision: 1
                    )
                ],
                nextRevision: 1,
                in: database
            )
            try WalletAssetCatalogPersistence.finishRemoteSync(
                revision: 1,
                in: database
            )
        }

        let snapshot = try await database.pool.read { database in
            (
                entryCount: try DBAssetCatalogEntryRecord
                    .fetchCount(database),
                version: try DBAssetCatalogMetadataRecord.fetchOne(
                    database,
                    key: WalletAssetCatalogPersistence.metadataID
                )?.version,
                currency: try String.fetchOne(
                    database,
                    sql: """
                    SELECT currencyCode
                    FROM userSettings
                    WHERE profileID = ?
                    """,
                    arguments: [WalletDatabase.defaultProfileID]
                )
            )
        }

        #expect(snapshot.entryCount == 1)
        #expect(snapshot.version == "oath-bundled-v4")
        #expect(snapshot.currency == "EUR")
    }

    @Test
    func retiredCrossAppStateIsRemovedWithoutChangingCurrentData()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WalletDatabase.applicationDatabase(
            at: directory
        )

        try await database.pool.write { database in
            try database.execute(
                sql: """
                CREATE TABLE legacyWalletImports (value TEXT);
                CREATE TABLE legacyWalletMigrationRuns (value TEXT);

                INSERT OR IGNORE INTO grdb_migrations (identifier)
                VALUES
                    ('v34_legacy_wallet_import_journal'),
                    ('v38_legacy_wallet_import_completion');

                DELETE FROM grdb_migrations
                WHERE identifier = 'v41_retired_cross_app_storage';

                UPDATE userSettings
                SET currencyCode = 'EUR'
                WHERE profileID = ?;
                """,
                arguments: [WalletDatabase.defaultProfileID]
            )
        }

        try WalletDatabase.migrator.migrate(database.pool)

        let snapshot = try await database.pool.read { database in
            let retiredTableCount = try Int.fetchOne(
                database,
                sql: """
                SELECT COUNT(*)
                FROM sqlite_master
                WHERE type = 'table'
                  AND name IN (
                      'legacyWalletImports',
                      'legacyWalletMigrationRuns'
                  )
                """
            ) ?? 0
            let retiredHistoryCount = try Int.fetchOne(
                database,
                sql: """
                SELECT COUNT(*)
                FROM grdb_migrations
                WHERE identifier IN (
                    'v34_legacy_wallet_import_journal',
                    'v38_legacy_wallet_import_completion'
                )
                """
            ) ?? 0
            let currencyCode = try String.fetchOne(
                database,
                sql: """
                SELECT currencyCode
                FROM userSettings
                WHERE profileID = ?
                """,
                arguments: [WalletDatabase.defaultProfileID]
            )
            return (
                retiredTableCount,
                retiredHistoryCount,
                currencyCode
            )
        }

        #expect(snapshot.0 == 0)
        #expect(snapshot.1 == 0)
        #expect(snapshot.2 == "EUR")
    }

    @Test
    func regularFileAtDatabaseDirectoryReturnsDirectoryStageFailure()
        throws
    {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let fileURL = parent.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: fileURL)

        let error = initializationError {
            _ = try WalletDatabase.applicationDatabase(at: fileURL)
        }

        #expect(error?.stage == .databaseDirectory)
    }

    @Test
    func directoryAtDatabaseFileReturnsOpenStageFailure() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("wallet.sqlite"),
            withIntermediateDirectories: false
        )

        let error = initializationError {
            _ = try WalletDatabase.applicationDatabase(at: directory)
        }

        #expect(error?.stage == .databaseOpen)
    }

    @Test
    func incompatibleSchemaReturnsMigrationStageFailure() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent(
            "wallet.sqlite"
        )

        do {
            let incompatiblePool = try DatabasePool(path: databaseURL.path)
            try incompatiblePool.write { database in
                try database.execute(
                    sql: """
                    CREATE TABLE profiles (
                        id TEXT PRIMARY KEY NOT NULL
                    )
                    """
                )
            }
        }

        let error = initializationError {
            _ = try WalletDatabase.applicationDatabase(at: directory)
        }

        #expect(error?.stage == .migration)
    }

    @Test
    func diagnosticsDoNotExposeDatabasePaths() {
        let sensitivePath =
            "/private/var/mobile/Containers/Data/wallet.sqlite"
        let underlying = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileNoSuchFile.rawValue,
            userInfo: [NSFilePathErrorKey: sensitivePath]
        )
        let failure = WalletDatabaseInitializationFailure(
            error: WalletDatabaseInitializationError(
                stage: .databaseOpen,
                underlyingError: underlying
            )
        )

        #expect(failure.diagnosticCode.hasPrefix("database_open_"))
        #expect(!failure.diagnosticCode.contains(sensitivePath))
        #expect(!failure.diagnosticCode.contains("Containers"))
    }

    @Test
    func runtimeNeverProvidesAnEmptyFallbackDatabase() throws {
        WalletDatabaseRuntime.clear()
        defer { WalletDatabaseRuntime.clear() }

        #expect(throws: WalletDatabaseRuntimeError.unavailable) {
            _ = try WalletDatabaseRuntime.require()
        }
        #expect(!WalletDatabaseRuntime.isReady)

        let database = try WalletDatabase.temporary()
        WalletDatabaseRuntime.install(database)

        #expect(try WalletDatabaseRuntime.require() === database)
        #expect(WalletDatabaseRuntime.isReady)
    }

    @Test
    @MainActor
    func failedBootstrapCanRetryWithoutInstallingFailedRuntime()
        async throws
    {
        WalletDatabaseRuntime.clear()
        defer { WalletDatabaseRuntime.clear() }
        let attempts = InitializationAttemptCounter()
        let controller = WalletDatabaseBootstrapController {
            let attempt = await attempts.next()
            if attempt == 1 {
                throw WalletDatabaseInitializationError(
                    stage: .migration,
                    underlyingError: DatabaseError(
                        resultCode: .SQLITE_ERROR,
                        message: "injected migration failure"
                    )
                )
            }
            return try WalletDatabase.temporary()
        }

        await controller.startIfNeeded()

        switch controller.state {
        case let .failed(failure):
            #expect(failure.diagnosticCode.hasPrefix("migration_sqlite_"))
        default:
            Issue.record(
                "The first injected initialization failure was not surfaced."
            )
        }
        #expect(!WalletDatabaseRuntime.isReady)
        #expect(throws: WalletDatabaseRuntimeError.unavailable) {
            _ = try WalletDatabaseRuntime.require()
        }

        await controller.retry()

        switch controller.state {
        case let .ready(database):
            #expect(try WalletDatabaseRuntime.require() === database)
        default:
            Issue.record(
                "Retry did not install the successfully initialized database."
            )
        }
        #expect(WalletDatabaseRuntime.isReady)
        #expect(await attempts.current == 2)
    }

    @Test
    func spendReservationAtomicallySerializesOneAccount()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let materials = try await seedReservationWallet(
            in: database,
            walletID: "reservation-race-wallet",
            accounts: [
                ("reservation-race-eth", "eth"),
                ("reservation-race-polygon", "polygon")
            ]
        )
        let firstMaterial = materials[0]

        async let first = reservationAttempt(
            database: database,
            material: firstMaterial,
            reservationID: "reservation-race-a"
        )
        async let second = reservationAttempt(
            database: database,
            material: firstMaterial,
            reservationID: "reservation-race-b"
        )
        let attempts = await [first, second]
        let acquired: [SendSpendReservation] = attempts.compactMap {
            attempt -> SendSpendReservation? in
            guard case let .acquired(reservation) = attempt else {
                return nil
            }
            return reservation
        }
        let conflicts: [SendSpendReservationEvidence] = attempts.compactMap {
            attempt -> SendSpendReservationEvidence? in
            guard case let .conflict(evidence) = attempt else {
                return nil
            }
            return evidence
        }
        for case let .unexpected(description) in attempts {
            Issue.record("Unexpected reservation error: \(description)")
        }

        #expect(acquired.count == 1)
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.accountID == firstMaterial.account.id)
        #expect(conflicts.first?.state == .preparing)
        #expect(
            conflicts.first?.reservationID
                == acquired.first?.reservationID
        )

        let independent = try await database.acquireSendSpendReservation(
            material: materials[1],
            reservationID: "reservation-independent"
        )
        #expect(independent.accountID == materials[1].account.id)
        let storedCount = try await database.pool.read { rawDatabase in
            try Int.fetchOne(
                rawDatabase,
                sql: "SELECT COUNT(*) FROM sendSpendReservations"
            ) ?? 0
        }
        #expect(storedCount == 2)
    }

    @Test
    func submissionEvidenceIsDurableAndPreparationRecoveryIsSelective()
        async throws
    {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let submittedMaterial: SendResolvedSigningMaterial
        let submittedReceipt: SendTransactionReceipt
        do {
            let database = try WalletDatabase.applicationDatabase(
                at: directory
            )
            let materials = try await seedReservationWallet(
                in: database,
                walletID: "reservation-relaunch-wallet",
                accounts: [
                    ("reservation-relaunch-eth", "eth"),
                    ("reservation-relaunch-polygon", "polygon")
                ]
            )
            submittedMaterial = materials[0]
            let submitted = try await database
                .acquireSendSpendReservation(
                    material: submittedMaterial,
                    reservationID: "reservation-submitted"
                )
            _ = try await database.acquireSendSpendReservation(
                material: materials[1],
                reservationID: "reservation-preparing"
            )
            submittedReceipt = reservationReceipt(
                material: submittedMaterial,
                transactionHash: "0x" + String(repeating: "ab", count: 32)
            )
            try await database.markSendSpendSubmissionStarted(
                reservation: submitted,
                receipt: submittedReceipt
            )
            try await database.markSendSpendSubmissionStarted(
                reservation: submitted,
                receipt: submittedReceipt
            )
        }

        let reopened = try WalletDatabase.applicationDatabase(at: directory)
        let submittedEvidence = try await reopened
            .sendSpendReservationEvidence(
                accountID: submittedMaterial.account.id
            )
        let abandonedEvidence = try await reopened
            .sendSpendReservationEvidence(
                accountID: "reservation-relaunch-polygon"
            )

        #expect(submittedEvidence?.state == .submissionStarted)
        #expect(
            submittedEvidence?.transactionHash
                == submittedReceipt.transactionHash
        )
        #expect(
            submittedEvidence?.fromAddress
                == submittedReceipt.fromAddress
        )
        #expect(abandonedEvidence == nil)

        #expect(
            try await reopened.updateSubmittedSendStatus(
                receipt: submittedReceipt,
                status: .pending
            ) == false
        )
        #expect(
            try await reopened.sendSpendReservationEvidence(
                accountID: submittedMaterial.account.id
            ) != nil
        )

        #expect(
            try await reopened.updateSubmittedSendStatus(
                receipt: submittedReceipt,
                status: .confirmed
            ) == false
        )
        #expect(
            try await reopened.sendSpendReservationEvidence(
                accountID: submittedMaterial.account.id
            ) == nil
        )
        let next = try await reopened.acquireSendSpendReservation(
            material: submittedMaterial,
            reservationID: "reservation-after-terminal"
        )
        #expect(next.accountID == submittedMaterial.account.id)
    }

    @Test
    func spendReservationRejectsMismatchedSubmissionEvidence()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let material = try await seedReservationWallet(
            in: database,
            walletID: "reservation-binding-wallet",
            accounts: [("reservation-binding-account", "eth")]
        )[0]
        let reservation = try await database.acquireSendSpendReservation(
            material: material,
            reservationID: "reservation-binding"
        )
        let mismatched = SendTransactionReceipt(
            transactionHash: "0x" + String(repeating: "cd", count: 32),
            accountID: "different-account",
            networkID: material.account.networkID,
            fromAddress: material.account.address,
            toAddress: "",
            assetID: "",
            assetSymbol: "",
            amount: "0",
            amountAtomic: "0",
            networkFee: nil,
            networkFeeAtomic: nil,
            networkFeeSymbol: "",
            submittedAt: Date()
        )

        do {
            try await database.markSendSpendSubmissionStarted(
                reservation: reservation,
                receipt: mismatched
            )
            Issue.record("Mismatched reservation evidence was accepted.")
        } catch let error as WalletDataStoreError {
            #expect(error == .invalidState)
        } catch {
            Issue.record(
                "Unexpected evidence binding error: \(type(of: error))"
            )
        }
        #expect(
            try await database.sendSpendReservationEvidence(
                accountID: material.account.id
            )?.state == .preparing
        )
    }

    @Test
    func deletingWalletCascadesItsSpendReservation() async throws {
        let database = try WalletDatabase.temporary()
        let walletID = "reservation-cascade-wallet"
        let material = try await seedReservationWallet(
            in: database,
            walletID: walletID,
            accounts: [("reservation-cascade-account", "eth")]
        )[0]
        _ = try await database.acquireSendSpendReservation(
            material: material,
            reservationID: "reservation-cascade"
        )

        try await database.pool.write { rawDatabase in
            _ = try DBWalletRecord.deleteOne(
                rawDatabase,
                key: walletID
            )
        }

        #expect(
            try await database.sendSpendReservationEvidence(
                accountID: material.account.id
            ) == nil
        )
    }

    private func seedReservationWallet(
        in database: WalletDatabase,
        walletID: String,
        accounts: [(id: String, networkID: String)]
    ) async throws -> [SendResolvedSigningMaterial] {
        let timestamp = Date().timeIntervalSince1970
        let records = accounts.enumerated().map { index, specification in
            let address = "0x" + String(
                format: "%040llx",
                UInt64(index + 1)
            )
            return DBWalletAccountRecord(
                id: specification.id,
                walletID: walletID,
                networkID: specification.networkID,
                address: address,
                normalizedAddress: address.lowercased(),
                label: nil,
                derivationPath: "m/44'/60'/0'/0/0",
                accountIndex: 0,
                publicKey: nil,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: timestamp,
                updatedAt: timestamp,
                lastSyncedAt: nil
            )
        }
        try await database.pool.write { rawDatabase in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Reservation Fixture",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: nil,
                isSelected: true,
                sortOrder: 0,
                createdAt: timestamp,
                updatedAt: timestamp,
                lastOpenedAt: timestamp,
                archivedAt: nil
            ).insert(rawDatabase)
            for record in records {
                try record.insert(rawDatabase)
            }
        }
        return records.enumerated().map { index, account in
            SendResolvedSigningMaterial(
                walletID: walletID,
                account: account,
                privateKey: Data(
                    repeating: UInt8(index + 1),
                    count: 32
                )
            )
        }
    }

    private func reservationAttempt(
        database: WalletDatabase,
        material: SendResolvedSigningMaterial,
        reservationID: String
    ) async -> SpendReservationAttempt {
        do {
            return .acquired(
                try await database.acquireSendSpendReservation(
                    material: material,
                    reservationID: reservationID
                )
            )
        } catch let error as SendSpendReservationStoreError {
            switch error {
            case let .conflict(evidence):
                return .conflict(evidence)
            case .staleReservation:
                return .unexpected("stale_reservation")
            }
        } catch {
            return .unexpected(String(reflecting: type(of: error)))
        }
    }

    private func reservationReceipt(
        material: SendResolvedSigningMaterial,
        transactionHash: String
    ) -> SendTransactionReceipt {
        SendTransactionReceipt(
            transactionHash: transactionHash,
            accountID: material.account.id,
            networkID: material.account.networkID,
            fromAddress: material.account.address,
            toAddress: "",
            assetID: "",
            assetSymbol: "",
            amount: "0",
            amountAtomic: "0",
            networkFee: nil,
            networkFeeAtomic: nil,
            networkFeeSymbol: "",
            submittedAt: Date()
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "wallet-database-initialization-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private func initializationError(
        from operation: () throws -> Void
    ) -> WalletDatabaseInitializationError? {
        do {
            try operation()
            Issue.record("Database initialization unexpectedly succeeded.")
            return nil
        } catch let error as WalletDatabaseInitializationError {
            return error
        } catch {
            Issue.record(
                "Initialization returned an untyped error: \(type(of: error))"
            )
            return nil
        }
    }
}

private enum SpendReservationAttempt: Sendable {
    case acquired(SendSpendReservation)
    case conflict(SendSpendReservationEvidence)
    case unexpected(String)
}

private actor InitializationAttemptCounter {
    private(set) var current = 0

    func next() -> Int {
        current += 1
        return current
    }
}
