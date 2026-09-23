import Foundation
import GRDB
import Security
import Testing
@testable import Aperture

@Suite(.serialized)
struct AppLaunchWalletRestorationTests {
    @Test
    func freshDatabaseNeverClaimsProtectionWithoutACredential()
        async throws {
        let database = try WalletDatabase.temporary()

        let settings = try await database.walletSecuritySettings()
        let readiness = try await database
            .passcodeCredentialReadiness()

        #expect(!settings.appLockEnabled)
        #expect(!settings.biometricEnabled)
        #expect(readiness == .protectionDisabled)
    }

    @Test
    func inconsistentProtectedStateNeverBypassesAuthentication()
        async throws {
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(
            service:
                "com.aperture.wallet.tests.empty.\(UUID().uuidString)"
        )
        defer { try? vault.deleteAll() }
        try await database.pool.write { database in
            guard var settings = try DBUserSettingsRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            ) else {
                throw WalletSecurityPersistenceError.missingSettings
            }
            settings.appLockEnabled = true
            settings.updatedAt = Date().timeIntervalSince1970
            try settings.update(database)
        }

        let readiness = try await database
            .passcodeCredentialReadiness(vault: vault)

        #expect(
            readiness == .unavailable(.missingSecurityRecord)
        )
        #expect(
            AppLaunchSecurityRoutingPolicy.route(
                settings: .secureDefault,
                credentialReadiness: readiness
            ) == .unavailable(.missingSecurityRecord)
        )
    }

    @Test
    func emptyDatabaseIsTheOnlyStateReportedAsNoWallets()
        async throws {
        let database = try WalletDatabase.temporary()

        let outcome = await AppLaunchWalletRestorationService(
            database: database
        ).restore()

        guard case .noWallets = outcome else {
            Issue.record(
                "A successful empty-wallet query must be the no-wallet state."
            )
            return
        }
    }

    @Test
    func existingUnselectedWalletNeverFallsThroughToOnboarding()
        async throws {
        let database = try WalletDatabase.temporary()
        try await insertWallet(
            selected: false,
            includesAccount: true,
            into: database
        )

        let outcome = await AppLaunchWalletRestorationService(
            database: database
        ).restore()

        let failure = try requireFailure(outcome)
        #expect(
            failure.messageKey
                == "wallet.launch.restore.error.inconsistent"
        )
        #expect(
            failure.diagnosticCode
                == "selection_missing_selection_active_count_1"
        )
    }

    @Test
    func selectedWalletWithoutEnabledAccountIsNotAFreshInstall()
        async throws {
        let database = try WalletDatabase.temporary()
        try await insertWallet(
            selected: true,
            includesAccount: false,
            into: database
        )

        let outcome = await AppLaunchWalletRestorationService(
            database: database
        ).restore()

        let failure = try requireFailure(outcome)
        #expect(
            failure.diagnosticCode
                == "selection_selected_wallet_missing_enabled_account"
        )
    }

    @Test
    func validSelectedWalletRestoresAllMandatoryLaunchReads()
        async throws {
        let database = try WalletDatabase.temporary()
        try await insertWallet(
            selected: true,
            includesAccount: true,
            into: database
        )

        let outcome = await AppLaunchWalletRestorationService(
            database: database
        ).restore()

        guard case let .wallet(payload) = outcome else {
            Issue.record(
                "A valid selected wallet must restore its launch payload."
            )
            return
        }
        #expect(payload.identity.walletID == Self.walletID)
        #expect(payload.identity.address == Self.walletAddress)
        #expect(payload.walletName == "Launch Wallet")
        #expect(payload.walletAppearanceColor == .purple)
        #expect(payload.capabilities == .fullWallet)
        #expect(payload.cachedSnapshot != nil)
    }

    @Test
    func launchSecurityPolicyRoutesProtectedWalletToAuthentication() {
        let settings = WalletSecuritySettings(
            appLockEnabled: true,
            biometricEnabled: true,
            autoLockDuration: .minute1,
            privacyShieldEnabled: true
        )

        #expect(
            AppLaunchSecurityRoutingPolicy.route(
                settings: settings,
                credentialReadiness: .available
            ) == .authentication
        )
    }

    @Test
    func launchSecurityPolicyRoutesUnprotectedWalletToHome() {
        let settings = WalletSecuritySettings(
            appLockEnabled: false,
            biometricEnabled: false,
            autoLockDuration: .hours4,
            privacyShieldEnabled: false
        )

        #expect(
            AppLaunchSecurityRoutingPolicy.route(
                settings: settings,
                credentialReadiness:
                    .unavailable(.credentialNotFound)
            ) == .wallet
        )
    }

    @Test
    func launchSecurityPolicyNeverStartsPasscodeResetAutomatically() {
        let settings = WalletSecuritySettings.secureDefault

        #expect(
            AppLaunchSecurityRoutingPolicy.route(
                settings: settings,
                credentialReadiness:
                    .unavailable(.invalidCredentialData)
            ) == .unavailable(.invalidCredentialData)
        )
    }

    @Test
    func launchRepairsBuild30KeychainCredentialWithoutRecoveryFlow()
        async throws {
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(
            service:
                "com.aperture.wallet.tests.upgrade.\(UUID().uuidString)"
        )
        defer { try? vault.deleteAll() }

        let passcode = "123456"
        let credential = try WalletPasscodeCredential.make(
            passcode: passcode
        )
        var legacyObject = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(credential)
            ) as? [String: Any]
        )
        legacyObject["version"] = 1
        let legacyData = try JSONSerialization.data(
            withJSONObject: legacyObject,
            options: [.sortedKeys]
        )
        let legacyReference = UUID().uuidString.lowercased()
        _ = try vault.store(
            legacyData,
            kind: .passcodeVerifier,
            reference: legacyReference
        )
        _ = try vault.store(
            legacyData,
            kind: .passcodeVerifier,
            reference:
                legacyReference + ".passcode-verifier-backup-v1"
        )

        try await database.pool.write { database in
            guard var settings = try DBUserSettingsRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            ) else {
                throw WalletSecurityPersistenceError.missingSettings
            }
            settings.appLockEnabled = true
            settings.updatedAt = Date().timeIntervalSince1970
            try settings.update(database)
        }

        let readiness = try await database.passcodeCredentialReadiness(
            vault: vault
        )
        let repairedReference = try await database.pool.read { database in
            try DBProfileSecurityRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            )?.passcodeKeychainReference
        }

        #expect(readiness == .available)
        #expect(repairedReference == legacyReference)
        #expect(
            try await database.authenticatePasscode(
                passcode,
                vault: vault
            ) == .success
        )
        #expect(
            AppLaunchSecurityRoutingPolicy.route(
                settings: .secureDefault,
                credentialReadiness: readiness
            ) == .authentication
        )
    }

    @Test
    func launchRestoresBuild30BackupWhenPrimaryItemIsMissing()
        async throws {
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(
            service:
                "com.aperture.wallet.tests.backup.\(UUID().uuidString)"
        )
        defer { try? vault.deleteAll() }

        let passcode = "654321"
        let credential = try WalletPasscodeCredential.make(
            passcode: passcode
        )
        var legacyObject = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(credential)
            ) as? [String: Any]
        )
        legacyObject["version"] = 1
        let legacyData = try JSONSerialization.data(
            withJSONObject: legacyObject,
            options: [.sortedKeys]
        )
        let legacyReference = UUID().uuidString.lowercased()
        _ = try vault.store(
            legacyData,
            kind: .passcodeVerifier,
            reference:
                legacyReference + ".passcode-verifier-backup-v1"
        )

        try await database.pool.write { database in
            guard var settings = try DBUserSettingsRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            ) else {
                throw WalletSecurityPersistenceError.missingSettings
            }
            let now = Date().timeIntervalSince1970
            settings.appLockEnabled = true
            settings.updatedAt = now
            try settings.update(database)
            try DBProfileSecurityRecord(
                profileID: WalletDatabase.defaultProfileID,
                passcodeKeychainReference: legacyReference,
                failedAttemptCount: 0,
                lockedUntil: nil,
                updatedAt: now
            ).insert(database)
        }

        let readiness = try await database.passcodeCredentialReadiness(
            vault: vault
        )

        #expect(readiness == .available)
        #expect(
            try WalletPasscodeCredential.decodeStoredData(
                vault.data(reference: legacyReference)
            ).matches(passcode: passcode)
        )
        #expect(
            try await database.authenticatePasscode(
                passcode,
                vault: vault
            ) == .success
        )
    }

    @Test
    func launchSecurityPolicyNeverRepairsTemporaryKeychainState() {
        let settings = WalletSecuritySettings.secureDefault
        let issue = WalletPasscodeCredentialIssue
            .keychainTemporarilyUnavailable(errSecInteractionNotAllowed)

        #expect(
            AppLaunchSecurityRoutingPolicy.route(
                settings: settings,
                credentialReadiness: .unavailable(issue)
            ) == .unavailable(issue)
        )
    }

    @Test
    func transientDatabaseFailureRemainsRecoverableUntilRetry()
        async throws {
        let database = try WalletDatabase.temporary()
        let probe = LaunchSelectionProbe()
        let service = AppLaunchWalletRestorationService(
            loadSelection: {
                try await probe.load(from: database)
            },
            loadCapabilities: { walletID in
                try await database.walletCapabilities(
                    walletID: walletID
                )
            },
            loadWallet: { walletID in
                try await database.managedWallet(walletID: walletID)
            },
            loadSnapshot: { walletID in
                try await database.cachedWalletSnapshot(
                    walletID: walletID
                )
            }
        )

        let first = await service.restore()
        let firstFailure = try requireFailure(first)
        #expect(
            firstFailure.messageKey
                == "wallet.launch.restore.error.database_busy"
        )
        #expect(
            firstFailure.diagnosticCode
                == "selection_sqlite_busy_5"
        )

        let retry = await service.restore()
        guard case .noWallets = retry else {
            Issue.record(
                "Retry must reevaluate the database instead of preserving the failure."
            )
            return
        }
    }

    @Test
    func persistentDatabaseFailureNeverBecomesNoWallets()
        async throws {
        let service = failingSelectionService(
            DatabaseError(resultCode: .SQLITE_CORRUPT)
        )

        for _ in 1...3 {
            let outcome = await service.restore()
            let failure = try requireFailure(outcome)
            #expect(
                failure.messageKey
                    == "wallet.launch.restore.error.database_integrity"
            )
            #expect(
                failure.diagnosticCode
                    == "selection_sqlite_integrity_11"
            )
        }
    }

    @Test
    func everyMandatoryPayloadReadPropagatesItsDatabaseFailure()
        async throws {
        let database = try WalletDatabase.temporary()
        try await insertWallet(
            selected: true,
            includesAccount: true,
            into: database
        )

        for failingStage in PayloadStage.allCases {
            let service = AppLaunchWalletRestorationService(
                loadSelection: {
                    try await database.appLaunchWalletSelection()
                },
                loadCapabilities: { walletID in
                    if failingStage == .capabilities {
                        throw DatabaseError(
                            resultCode: .SQLITE_BUSY
                        )
                    }
                    return try await database.walletCapabilities(
                        walletID: walletID
                    )
                },
                loadWallet: { walletID in
                    if failingStage == .walletMetadata {
                        throw DatabaseError(
                            resultCode: .SQLITE_BUSY
                        )
                    }
                    return try await database.managedWallet(
                        walletID: walletID
                    )
                },
                loadSnapshot: { walletID in
                    if failingStage == .cachedSnapshot {
                        throw DatabaseError(
                            resultCode: .SQLITE_BUSY
                        )
                    }
                    return try await database.cachedWalletSnapshot(
                        walletID: walletID
                    )
                }
            )

            let outcome = await service.restore()
            let failure = try requireFailure(outcome)
            #expect(
                failure.diagnosticCode
                    == "\(failingStage.rawValue)_sqlite_busy_5"
            )
        }
    }

    @Test
    func diagnosticsNeverStoreRawProviderOrDatabaseMessages() {
        let rawMessage = "private-wallet-name-and-address"
        let failure = AppLaunchWalletRestorationFailure(
            error: LaunchTestError(rawMessage: rawMessage),
            stage: .selection
        )

        #expect(!failure.diagnosticCode.contains(rawMessage))
        #expect(
            failure.diagnosticCode.hasPrefix(
                "selection_unexpected_"
            )
        )
        #expect(
            failure.diagnosticCode.hasSuffix(
                "_launchtesterror"
            )
        )
        #expect(
            failure.supportURL?.absoluteString.contains(rawMessage)
                == false
        )
    }

    private func failingSelectionService(
        _ error: any Error & Sendable
    ) -> AppLaunchWalletRestorationService {
        AppLaunchWalletRestorationService(
            loadSelection: { throw error },
            loadCapabilities: { _ in .fullWallet },
            loadWallet: { _ in
                throw WalletManagementError.walletNotFound
            },
            loadSnapshot: { _ in nil }
        )
    }

    private func requireFailure(
        _ outcome: AppLaunchWalletRestorationOutcome
    ) throws -> AppLaunchWalletRestorationFailure {
        guard case let .failed(failure) = outcome else {
            Issue.record(
                "Database and record failures must remain explicit launch failures."
            )
            throw LaunchTestError(rawMessage: "expected_failure")
        }
        return failure
    }

    private func insertWallet(
        selected: Bool,
        includesAccount: Bool,
        into database: WalletDatabase
    ) async throws {
        try await database.pool.write { db in
            let now = Date().timeIntervalSince1970
            try DBWalletRecord(
                id: Self.walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Launch Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: "opaque-launch-reference",
                isSelected: selected,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil,
                appearanceColorID: WalletAppearanceColor.purple.rawValue
            ).insert(db)

            guard includesAccount else { return }
            try DBWalletAccountRecord(
                id: Self.accountID,
                walletID: Self.walletID,
                networkID: "eth",
                address: Self.walletAddress,
                normalizedAddress: Self.walletAddress.lowercased(),
                label: nil,
                derivationPath: nil,
                accountIndex: 0,
                publicKey: "public",
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(db)
        }
    }

    private static let walletID = "launch-wallet"
    private static let accountID = "launch-account"
    private static let walletAddress =
        "0x1111111111111111111111111111111111111111"
}

private enum PayloadStage: String, CaseIterable, Sendable {
    case capabilities
    case walletMetadata = "wallet_metadata"
    case cachedSnapshot = "cached_snapshot"
}

private actor LaunchSelectionProbe {
    private var shouldFail = true

    func load(
        from database: WalletDatabase
    ) async throws -> AppLaunchWalletSelection {
        if shouldFail {
            shouldFail = false
            throw DatabaseError(resultCode: .SQLITE_BUSY)
        }
        return try await database.appLaunchWalletSelection()
    }
}

private struct LaunchTestError: Error, Sendable {
    let rawMessage: String
}
