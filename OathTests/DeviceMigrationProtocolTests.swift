import Foundation
import GRDB
import Testing
@testable import Aperture
@Suite(.serialized)
struct DeviceMigrationProtocolTests {
    @Test
    func invitationRoundTripsThroughQRCodePayload() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let source = try DeviceMigrationCryptography
            .makeSourceHandshake(now: now)

        let decoded = try DeviceMigrationInvitation.parse(
            source.invitation.qrPayload,
            now: now
        )

        #expect(
            decoded.protocolVersion
                == DeviceMigrationProtocol.version
        )
        #expect(decoded.sessionID == source.invitation.sessionID)
        #expect(
            decoded.sourcePublicKey
                == source.invitation.sourcePublicKey
        )
        #expect(
            Int64(decoded.expiresAt.timeIntervalSince1970)
                == Int64(
                    source.invitation.expiresAt
                        .timeIntervalSince1970
                )
        )
    }

    @Test
    func expiredInvitationIsRejected() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let source = try DeviceMigrationCryptography
            .makeSourceHandshake(
                now: now.addingTimeInterval(
                    -DeviceMigrationProtocol.invitationLifetime - 1
                )
            )

        #expect(throws: DeviceMigrationError.expiredInvitation) {
            try DeviceMigrationInvitation.parse(
                source.invitation.qrPayload,
                now: now
            )
        }
    }

    @Test
    func scannedInvitationAuthenticatesKeyAgreement() throws {
        let source = try DeviceMigrationCryptography
            .makeSourceHandshake()
        let scanned = try DeviceMigrationInvitation.parse(
            source.invitation.qrPayload
        )
        let receiver = try DeviceMigrationCryptography
            .makeReceiverHandshake(invitation: scanned)
        let sourceKey = try DeviceMigrationCryptography.accept(
            joinRequest: receiver.joinRequest,
            sourceHandshake: source
        )
        let completion = DeviceMigrationTransferComplete(
            transferID: UUID().uuidString.lowercased()
        )

        let sealed = try DeviceMigrationCryptography.seal(
            completion,
            domain: "transfer-complete",
            sessionID: scanned.sessionID,
            using: sourceKey
        )
        let opened = try DeviceMigrationCryptography.open(
            DeviceMigrationTransferComplete.self,
            sealedData: sealed,
            domain: "transfer-complete",
            sessionID: scanned.sessionID,
            using: receiver.encryptionKey
        )

        #expect(opened.transferID == completion.transferID)
    }

    @Test
    func modifiedJoinAuthenticationTagIsRejected() throws {
        let source = try DeviceMigrationCryptography
            .makeSourceHandshake()
        let receiver = try DeviceMigrationCryptography
            .makeReceiverHandshake(invitation: source.invitation)
        var alteredTag = receiver.joinRequest.authenticationTag
        alteredTag[alteredTag.startIndex] ^= 0x01
        let alteredRequest = DeviceMigrationJoinRequest(
            protocolVersion: receiver.joinRequest.protocolVersion,
            sessionID: receiver.joinRequest.sessionID,
            receiverPublicKey: receiver.joinRequest.receiverPublicKey,
            authenticationTag: alteredTag
        )

        #expect(throws: DeviceMigrationError.authenticationFailed) {
            try DeviceMigrationCryptography.accept(
                joinRequest: alteredRequest,
                sourceHandshake: source
            )
        }
    }

    @Test
    func sealedPayloadRejectsTamperingAndWrongDomain() throws {
        let source = try DeviceMigrationCryptography
            .makeSourceHandshake()
        let receiver = try DeviceMigrationCryptography
            .makeReceiverHandshake(invitation: source.invitation)
        var sealed = try DeviceMigrationCryptography.seal(
            DeviceMigrationTransferComplete(transferID: "transfer"),
            domain: "transfer-complete",
            sessionID: source.invitation.sessionID,
            using: receiver.encryptionKey
        )
        sealed[sealed.index(before: sealed.endIndex)] ^= 0x01

        #expect(
            throws: DeviceMigrationError.transferIntegrityFailed
        ) {
            try DeviceMigrationCryptography.open(
                DeviceMigrationTransferComplete.self,
                sealedData: sealed,
                domain: "transfer-complete",
                sessionID: source.invitation.sessionID,
                using: receiver.encryptionKey
            )
        }

        let intact = try DeviceMigrationCryptography.seal(
            DeviceMigrationTransferComplete(transferID: "transfer"),
            domain: "transfer-complete",
            sessionID: source.invitation.sessionID,
            using: receiver.encryptionKey
        )
        #expect(
            throws: DeviceMigrationError.transferIntegrityFailed
        ) {
            try DeviceMigrationCryptography.open(
                DeviceMigrationTransferComplete.self,
                sealedData: intact,
                domain: "manifest",
                sessionID: source.invitation.sessionID,
                using: receiver.encryptionKey
            )
        }
    }

    @Test
    func secretBundleContainsWalletMaterialOnly() throws {
        let bundle = DeviceMigrationSecretsBundle(
            protocolVersion: DeviceMigrationProtocol.version,
            walletSecrets: [
                DeviceMigrationWalletSecret(
                    walletID: "wallet",
                    kind: .privateKey,
                    data: Data(repeating: 0x01, count: 32)
                )
            ]
        )

        let encoded = try DeviceMigrationCryptography.encode(bundle)

        #expect(
            encoded.range(
                of: Data("passcodeCredential".utf8)
            ) == nil
        )
    }

    @Test
    func portableSnapshotRemovesSecurityAndDeviceBindingsOnly()
        async throws
    {
        let walletDatabase = try WalletDatabase.temporary()
        let now = Date().timeIntervalSince1970

        try await walletDatabase.pool.write { database in
            guard var settings = try DBUserSettingsRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            ) else {
                throw DeviceMigrationError.invalidDatabase
            }
            settings.appearance = "dark"
            settings.languageIdentifier = "fr"
            settings.currencyCode = "EUR"
            settings.currencyRatePerUSD = "0.92"
            settings.balancePrivacyEnabled = true
            settings.appLockEnabled = true
            settings.biometricEnabled = true
            settings.autoLockSeconds = 300
            settings.privacyShieldEnabled = true
            settings.notificationsEnabled = true
            try settings.update(database)

            try DBWalletRecord(
                id: "portable-wallet",
                profileID: WalletDatabase.defaultProfileID,
                name: "Portable Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: "source-keychain-reference",
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil
            ).insert(database)
            try DBProfileSecurityRecord(
                profileID: WalletDatabase.defaultProfileID,
                passcodeKeychainReference:
                    "source-passcode-reference",
                failedAttemptCount: 3,
                lockedUntil: now + 60,
                updatedAt: now
            ).insert(database)
            try DBPreferenceRecord(
                profileID: WalletDatabase.defaultProfileID,
                key: "portable.preference",
                valueType: "string",
                value: "preserved",
                updatedAt: now
            ).insert(database)
            try DBNotificationProfileRecord(
                profileID: WalletDatabase.defaultProfileID,
                remoteUserID: "source-remote-user",
                installationID: "source-installation",
                reconciliationNeeded: false,
                reconciliationGeneration: 4,
                lastSnapshotDigest: "digest",
                lastRegistrationAttemptAt: now,
                lastRegistrationSuccessAt: now,
                lastRegistrationErrorCode: nil,
                updatedAt: now
            ).insert(database)
            try DBNotificationOpenAuditRecord(
                notificationID: "source-open-audit",
                createdAt: now,
                attemptCount: 1,
                lastAttemptAt: now,
                nextAttemptAt: now,
                lastErrorCode: nil
            ).insert(database)

            let silentAddress = try BitcoinSilentPaymentAddress(
                "sp1qqgste7k9hx0qftg6qmwlkqtwuy6cycyavzmzj85c6qdfhjdpdjtdgqjuex"
                    + "zk6murw56suy3e0rd2cgqvycxttddwsvgxe2usfpxumr70xc9pkqwv"
            )
            try DBBitcoinSilentPaymentAccountRecord(
                walletID: "portable-wallet",
                address: silentAddress.encoded,
                scanPublicKey: silentAddress.scanPublicKey,
                spendPublicKey: silentAddress.spendPublicKey,
                keychainReference: "source-silent-account-reference",
                birthHeight: 709_632,
                lastScanHeight: 800_000,
                balanceIsAuthoritative: true,
                createdAt: now,
                updatedAt: now
            ).insert(database)
            let oneTimePublicKey = Data(repeating: 1, count: 32)
            try DBBitcoinSilentPaymentOutputRecord(
                walletID: "portable-wallet",
                transactionHash: String(repeating: "ab", count: 32),
                outputIndex: 0,
                valueAtomic: "1000",
                scriptPubKey: Data([0x51, 0x20]) + oneTimePublicKey,
                outputPublicKey: oneTimePublicKey,
                keychainReference: "source-silent-output-reference",
                blockHeight: 800_000,
                blockTimestamp: now,
                isSpent: false,
                spentByTransactionHash: nil,
                createdAt: now,
                updatedAt: now
            ).insert(database)

            #expect(throws: DeviceMigrationError.silentPaymentRecoveryRequired) {
                try DeviceMigrationTransferPolicy.sanitizeExportDatabase(database)
            }
            #expect(try DBBitcoinSilentPaymentOutputRecord.fetchCount(database) == 1)
            try DBBitcoinSilentPaymentOutputRecord.deleteAll(database)

            try DeviceMigrationTransferPolicy
                .sanitizeExportDatabase(database)
            try DeviceMigrationTransferPolicy
                .validatePortableDatabase(database)
        }

        try await walletDatabase.pool.read { database in
            let wallet = try #require(
                try DBWalletRecord.fetchOne(
                    database,
                    key: "portable-wallet"
                )
            )
            let preference = try #require(
                try DBPreferenceRecord
                    .filter(
                        Column("profileID")
                            == WalletDatabase.defaultProfileID
                    )
                    .filter(
                        Column("key") == "portable.preference"
                    )
                    .fetchOne(database)
            )
            let settings = try #require(
                try DBUserSettingsRecord.fetchOne(
                    database,
                    key: WalletDatabase.defaultProfileID
                )
            )

            #expect(wallet.name == "Portable Wallet")
            #expect(wallet.secretKeyReference == nil)
            #expect(preference.value == "preserved")
            #expect(settings.appearance == "dark")
            #expect(settings.languageIdentifier == "fr")
            #expect(settings.currencyCode == "EUR")
            #expect(settings.currencyRatePerUSD == "0.92")
            #expect(settings.balancePrivacyEnabled)
            #expect(settings.notificationsEnabled)
            #expect(
                try DBBitcoinSilentPaymentAccountRecord
                    .fetchCount(database) == 0
            )
            #expect(
                try DBBitcoinSilentPaymentOutputRecord
                    .fetchCount(database) == 0
            )
        }
    }

    @Test
    func portableSnapshotExcludesLegacyWatchOnlyWallets()
        async throws
    {
        let walletDatabase = try WalletDatabase.temporary()
        let now = Date().timeIntervalSince1970

        try await walletDatabase.pool.write { database in
            try DBWalletRecord(
                id: "watch-only-wallet",
                profileID: WalletDatabase.defaultProfileID,
                name: "Watch-only Wallet",
                kind: DatabaseWalletKind.watchOnly.rawValue,
                secretKeyReference: nil,
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil
            ).insert(database)
            try DeviceMigrationTransferPolicy
                .sanitizeExportDatabase(database)
            try DeviceMigrationTransferPolicy
                .validatePortableDatabase(database)
            #expect(
                try DBWalletRecord.fetchOne(
                    database,
                    key: "watch-only-wallet"
                ) == nil
            )
        }
    }

    @Test
    func destinationWithoutPasscodeStaysUnlockedAfterRestore()
        async throws
    {
        let walletDatabase = try WalletDatabase.temporary()
        let destination = try await walletDatabase.pool.write {
            database in
            guard var settings = try DBUserSettingsRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            ) else {
                throw DeviceMigrationError.invalidDatabase
            }
            settings.appLockEnabled = true
            settings.biometricEnabled = true
            settings.autoLockSeconds = 60
            settings.privacyShieldEnabled = false
            try settings.update(database)
            return try DeviceMigrationTransferPolicy
                .captureDestinationSecurity(in: database)
        }

        #expect(destination.passcodeKeychainReference == nil)
        #expect(!destination.appLockEnabled)
        #expect(!destination.biometricEnabled)

        try await walletDatabase.pool.write { database in
            try DBProfileSecurityRecord(
                profileID: WalletDatabase.defaultProfileID,
                passcodeKeychainReference:
                    "untrusted-source-passcode",
                failedAttemptCount: 5,
                lockedUntil: Date().timeIntervalSince1970 + 600,
                updatedAt: Date().timeIntervalSince1970
            ).insert(database)
            guard var settings = try DBUserSettingsRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            ) else {
                throw DeviceMigrationError.invalidDatabase
            }
            settings.appLockEnabled = true
            settings.biometricEnabled = true
            settings.autoLockSeconds = 900
            settings.privacyShieldEnabled = true
            try settings.update(database)

            try DeviceMigrationTransferPolicy
                .restoreDestinationSecurity(
                    destination,
                    in: database
                )
        }

        let restored = try await walletDatabase.pool.read {
            database in
            try DeviceMigrationTransferPolicy
                .captureDestinationSecurity(in: database)
        }
        #expect(restored == destination)
    }

    @Test
    func destinationSecurityReplacesSourceSecurityState()
        async throws
    {
        let walletDatabase = try WalletDatabase.temporary()
        let now = Date().timeIntervalSince1970
        let destination = try await walletDatabase.pool.write {
            database in
            try DBProfileSecurityRecord(
                profileID: WalletDatabase.defaultProfileID,
                passcodeKeychainReference:
                    "destination-passcode-reference",
                failedAttemptCount: 2,
                lockedUntil: now + 45,
                updatedAt: now
            ).insert(database)
            guard var settings = try DBUserSettingsRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            ) else {
                throw DeviceMigrationError.invalidDatabase
            }
            settings.appLockEnabled = true
            settings.biometricEnabled = true
            settings.autoLockSeconds = 300
            settings.privacyShieldEnabled = true
            try settings.update(database)
            return try DeviceMigrationTransferPolicy
                .captureDestinationSecurity(in: database)
        }

        try await walletDatabase.pool.write { database in
            try DBProfileSecurityRecord.deleteAll(database)
            try DBProfileSecurityRecord(
                profileID: WalletDatabase.defaultProfileID,
                passcodeKeychainReference:
                    "source-passcode-reference",
                failedAttemptCount: 0,
                lockedUntil: nil,
                updatedAt: now + 10
            ).insert(database)
            guard var settings = try DBUserSettingsRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            ) else {
                throw DeviceMigrationError.invalidDatabase
            }
            settings.appLockEnabled = false
            settings.biometricEnabled = false
            settings.autoLockSeconds = nil
            settings.privacyShieldEnabled = false
            try settings.update(database)

            try DeviceMigrationTransferPolicy
                .restoreDestinationSecurity(
                    destination,
                    in: database
                )
        }

        let restored = try await walletDatabase.pool.read {
            database in
            try DeviceMigrationTransferPolicy
                .captureDestinationSecurity(in: database)
        }
        #expect(restored == destination)
        #expect(
            restored.passcodeKeychainReference
                == "destination-passcode-reference"
        )
    }

    @Test
    @MainActor
    func resourceCompletionBridgesFrameworkQueueToMainActor()
        async
    {
        let delivery = await withCheckedContinuation {
            continuation in
            let completion =
                DeviceMigrationResourceSendCompletion { result in
                    continuation.resume(
                        returning: (
                            result.wasCalledOnMainThread,
                            Thread.isMainThread
                        )
                    )
                }
            DispatchQueue.global(qos: .userInitiated).async {
                completion.handler(nil)
            }
        }

        #expect(!delivery.0)
        #expect(delivery.1)
    }

    @Test
    func receivedResourceIsOwnedBeforeFrameworkCallbackReturns()
        async throws
    {
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "migration-framework-resource-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let sourceURL = sourceDirectory.appendingPathComponent(
            "temporary.sqlite"
        )
        let payload = Data("portable-database".utf8)
        try payload.write(to: sourceURL, options: .atomic)

        let staged = await withCheckedContinuation {
            continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let staged =
                    DeviceMigrationReceivedResourceStager.stage(
                        localURL: sourceURL,
                        frameworkError: nil
                    )
                try? FileManager.default.removeItem(
                    at: sourceDirectory
                )
                continuation.resume(returning: staged)
            }
        }
        defer {
            staged.removeOwnedFile()
        }

        #expect(staged.errorType == nil)
        #expect(staged.byteCount == payload.count)
        let ownedURL = try #require(staged.ownedURL)
        #expect(FileManager.default.fileExists(atPath: ownedURL.path))
        #expect(try Data(contentsOf: ownedURL) == payload)
    }

    @Test
    func repositoryRestoreMovesPortableDatabaseAndWalletSecrets()
        async throws
    {
        let source = try WalletDatabase.temporary()
        let destination = try WalletDatabase.temporary()
        let vault = WalletSecretVault.shared
        let phrase = """
            abandon abandon abandon abandon abandon abandon abandon abandon \
            abandon abandon abandon about
            """
        let derived = try WalletCoreService.restoreEVMWallet(
            mnemonic: phrase
        )
        var referencesToDelete: [String] = []
        let sourceReference = try vault.store(
            Data(phrase.utf8),
            kind: .recoveryPhrase
        )
        referencesToDelete.append(sourceReference)
        var exportedDirectory: URL?
        defer {
            for reference in referencesToDelete {
                try? vault.deleteIfPresent(reference: reference)
            }
            if let exportedDirectory {
                try? FileManager.default.removeItem(
                    at: exportedDirectory
                )
            }
        }

        let now = Date().timeIntervalSince1970
        try await source.pool.write { database in
            guard var settings = try DBUserSettingsRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            ) else {
                throw DeviceMigrationError.invalidDatabase
            }
            settings.appearance = "dark"
            settings.languageIdentifier = "fr"
            settings.currencyCode = "EUR"
            settings.currencyRatePerUSD = "0.92"
            settings.appLockEnabled = false
            settings.biometricEnabled = false
            settings.autoLockSeconds = nil
            settings.privacyShieldEnabled = false
            settings.notificationsEnabled = true
            try settings.update(database)

            try DBWalletRecord(
                id: "migration-wallet",
                profileID: WalletDatabase.defaultProfileID,
                name: "Migration Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: sourceReference,
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil,
                backupState:
                    DatabaseWalletBackupState.verified.rawValue,
                backupVerifiedAt: now,
                mnemonicWordCount: 12,
                iCloudBackupUpdatedAt: now,
                notificationsEnabledWhenInactive: true
            ).insert(database)
            try DBWalletAccountRecord(
                id: "migration-account",
                walletID: "migration-wallet",
                networkID: "eth",
                address: derived.address,
                normalizedAddress: derived.normalizedAddress,
                label: "Primary",
                derivationPath: derived.derivationPath,
                accountIndex: 0,
                publicKey: derived.publicKey,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: now
            ).insert(database)
            try DBPreferenceRecord(
                profileID: WalletDatabase.defaultProfileID,
                key: "migration.preference",
                valueType: "string",
                value: "portable-value",
                updatedAt: now
            ).insert(database)
            try DBAPICacheRecord(
                cacheKey: "migration-cache",
                provider: "test-provider",
                endpoint: "test-endpoint",
                payload: Data("cached".utf8),
                createdAt: now,
                expiresAt: now + 3_600,
                etag: "etag",
                lastModified: nil
            ).insert(database)
            try DBContactRecord(
                id: "migration-contact",
                profileID: WalletDatabase.defaultProfileID,
                name: "Contact",
                note: "Portable",
                createdAt: now,
                updatedAt: now
            ).insert(database)
            try DBContactAddressRecord(
                id: "migration-contact-address",
                contactID: "migration-contact",
                networkID: "eth",
                address:
                    "0x2222222222222222222222222222222222222222",
                normalizedAddress:
                    "0x2222222222222222222222222222222222222222",
                label: "Ethereum",
                isFavorite: true,
                createdAt: now
            ).insert(database)
            try DBConnectedDAppRecord(
                id: "migration-dapp",
                profileID: WalletDatabase.defaultProfileID,
                origin: "https://example.com",
                name: "Example",
                iconURL: nil,
                sessionTopic: "portable-session",
                createdAt: now,
                lastUsedAt: now,
                expiresAt: nil
            ).insert(database)
            try DBNotificationRecord(
                id: "migration-notification",
                profileID: WalletDatabase.defaultProfileID,
                category: "transfer",
                titleKey: "title",
                bodyKey: "body",
                argumentsJSON: nil,
                relatedTransactionID: nil,
                createdAt: now,
                readAt: nil,
                deliveredAt: now,
                titleText: "Received",
                bodyText: "Portable notification",
                walletID: "migration-wallet",
                networkID: "eth"
            ).insert(database)
        }

        let authorization =
            try await source.authorizeUnprotectedDeviceMigration()
        let prepared = try await source.prepareDeviceMigrationExport(
            authorization: authorization,
            vault: vault
        )
        exportedDirectory =
            prepared.databaseURL.deletingLastPathComponent()
        let portableCounts = try databaseRowCounts(
            at: prepared.databaseURL
        )
        let package = DeviceMigrationIncomingPackage(
            databaseURL: prepared.databaseURL,
            manifest: prepared.manifest,
            secrets: prepared.secrets
        )
        let verified = try WalletDatabase.verifyDeviceMigration(
            package,
            against: destination.pool
        )
        // Seed stale installation-bound references only after the empty
        // destination safety gate, then prove restore deletes them.
        let staleSilentReferences = try await seedSilentPaymentSecrets(
            in: destination,
            vault: vault
        )
        referencesToDelete.append(contentsOf: staleSilentReferences)
        let result = try WalletDatabase.restoreDeviceMigration(
            verified,
            into: destination.pool,
            vault: vault
        )
        try await destination.prepareAllBitcoinHDWallets(vault: vault)
        try await destination.prepareAllBitcoinSilentPaymentAccounts(
            vault: vault
        )
        await PushNotificationCoordinator.shared
            .preparePersistentStateForDeviceMigrationImport(
                database: destination
            )

        let restoredCounts = try await destination.pool.read {
            database in
            try databaseRowCounts(in: database)
        }
        let restored = try await destination.pool.read {
            database -> (DBWalletRecord, [String]) in
            let wallet = try #require(
                try DBWalletRecord.fetchOne(
                    database,
                    key: "migration-wallet"
                )
            )
            let references = try String.fetchAll(
                database,
                sql: """
                SELECT secretKeyReference
                FROM wallets
                WHERE secretKeyReference IS NOT NULL
                """
            )
            return (wallet, references)
        }
        referencesToDelete.append(contentsOf: restored.1)

        let regeneratedTableNames = [
            "bitcoinHDAccounts",
            "bitcoinHDAddresses",
            "bitcoinHDKeyCaches",
            "bitcoinHDPreferences",
            "bitcoinSilentPaymentAccounts",
            "notificationProfiles",
        ]
        var portableDataCounts = portableCounts
        var restoredDataCounts = restoredCounts
        for tableName in regeneratedTableNames {
            portableDataCounts[tableName] = nil
            restoredDataCounts[tableName] = nil
        }
        #expect(portableDataCounts == restoredDataCounts)
        // Four standard accounts plus the two supported BRD address types.
        #expect(restoredCounts["bitcoinHDAccounts"] == 6)
        #expect(restoredCounts["bitcoinHDAddresses"] == 240)
        #expect(restoredCounts["bitcoinHDKeyCaches"] == 12)
        #expect(restoredCounts["bitcoinHDPreferences"] == 1)
        #expect(restoredCounts["bitcoinSilentPaymentAccounts"] == 1)
        #expect(restoredCounts["bitcoinSilentPaymentOutputs"] == 0)
        #expect(restoredCounts["notificationProfiles"] == 1)
        #expect(result.walletCount == 1)
        #expect(result.selectedWallet.walletID == "migration-wallet")
        #expect(restored.0.name == "Migration Wallet")
        #expect(restored.0.secretKeyReference != sourceReference)
        #expect(restored.1.count == 1)
        #expect(secretReferencesAreMissing(staleSilentReferences, vault: vault))
        #expect(
            try vault.data(reference: restored.1[0])
                == Data(phrase.utf8)
        )

        let restoredSecurity = try await destination.pool.read {
            database in
            try DeviceMigrationTransferPolicy
                .captureDestinationSecurity(in: database)
        }
        #expect(restoredSecurity.passcodeKeychainReference == nil)
        #expect(!restoredSecurity.appLockEnabled)
        #expect(!restoredSecurity.biometricEnabled)
    }

    @Test
    @MainActor
    func rejectedAccountSecretPreservesDestinationNotificationState()
        async throws
    {
        let source = try WalletDatabase.temporary()
        let destination = try WalletDatabase.temporary()
        let vault = WalletSecretVault.shared
        let sourcePhrase = WalletCredentialTestFixtures.recoveryPhrase()
        let mismatchedPhrase = WalletCredentialTestFixtures.recoveryPhrase()
        let identity = try await source.persistImportedWallet(
            draft: try WalletCoreService.importRecoveryPhrase(
                sourcePhrase
            ),
            security: .reuseExistingProfile,
            vault: vault
        )
        let sourceReference = try await source.pool.read { database in
            try #require(
                try DBWalletRecord.fetchOne(
                    database,
                    key: identity.walletID
                )?.secretKeyReference
            )
        }
        defer {
            try? vault.deleteIfPresent(reference: sourceReference)
        }
        let authorization =
            try await source.authorizeUnprotectedDeviceMigration()
        let prepared = try await source.prepareDeviceMigrationExport(
            authorization: authorization,
            vault: vault
        )
        defer {
            try? FileManager.default.removeItem(
                at: prepared.databaseURL.deletingLastPathComponent()
            )
        }

        let now = Date().timeIntervalSince1970
        try await destination.pool.write { database in
            try DBNotificationProfileRecord(
                profileID: WalletDatabase.defaultProfileID,
                remoteUserID:
                    "b19f39f1-b78b-4946-9191-9fc865e77984",
                installationID: nil,
                reconciliationNeeded: false,
                reconciliationGeneration: 17,
                lastSnapshotDigest: String(repeating: "d", count: 43),
                lastRegistrationAttemptAt: now - 20,
                lastRegistrationSuccessAt: now - 10,
                lastRegistrationErrorCode: "preserved_error",
                historyBackfillCursor: "preserved_cursor",
                updatedAt: now
            ).insert(database)
            try DBNotificationOpenAuditRecord(
                notificationID: "preserved-open-audit",
                createdAt: now,
                attemptCount: 2,
                lastAttemptAt: now,
                nextAttemptAt: now + 60,
                lastErrorCode: "preserved_audit_error"
            ).insert(database)
        }
        let before = try await notificationMigrationState(
            in: destination
        )
        let originalSecret = try #require(
            prepared.secrets.walletSecrets.first
        )
        #expect(prepared.secrets.walletSecrets.count == 1)
        let package = DeviceMigrationIncomingPackage(
            databaseURL: prepared.databaseURL,
            manifest: prepared.manifest,
            secrets: DeviceMigrationSecretsBundle(
                protocolVersion: prepared.secrets.protocolVersion,
                walletSecrets: [
                    DeviceMigrationWalletSecret(
                        walletID: originalSecret.walletID,
                        kind: originalSecret.kind,
                        data: Data(mismatchedPhrase.utf8)
                    )
                ]
            )
        )
        let pushIdentityBefore =
            try PushInstallationVault.shared.currentIdentity()

        do {
            _ = try await destination.importDeviceMigration(
                package,
                vault: vault
            )
            Issue.record("Expected account-secret verification to fail.")
        } catch let error as DeviceMigrationError {
            #expect(error == .invalidWalletSecret)
        } catch {
            Issue.record(
                "Unexpected migration error type: \(type(of: error))"
            )
        }

        let after = try await notificationMigrationState(
            in: destination
        )
        #expect(after == before)
        #expect(
            try PushInstallationVault.shared.currentIdentity()
                == pushIdentityBefore
        )
    }

    private struct NotificationMigrationState: Equatable {
        let remoteUserID: String
        let installationID: String?
        let reconciliationNeeded: Bool
        let reconciliationGeneration: Int64
        let lastSnapshotDigest: String?
        let lastRegistrationAttemptAt: Double?
        let lastRegistrationSuccessAt: Double?
        let lastRegistrationErrorCode: String?
        let historyBackfillCursor: String?
        let updatedAt: Double
        let openAuditCount: Int
    }

    private func notificationMigrationState(
        in walletDatabase: WalletDatabase
    ) async throws -> NotificationMigrationState {
        try await walletDatabase.pool.read { database in
            let profile = try #require(
                try DBNotificationProfileRecord.fetchOne(
                    database,
                    key: WalletDatabase.defaultProfileID
                )
            )
            return NotificationMigrationState(
                remoteUserID: profile.remoteUserID,
                installationID: profile.installationID,
                reconciliationNeeded: profile.reconciliationNeeded,
                reconciliationGeneration:
                    profile.reconciliationGeneration,
                lastSnapshotDigest: profile.lastSnapshotDigest,
                lastRegistrationAttemptAt:
                    profile.lastRegistrationAttemptAt,
                lastRegistrationSuccessAt:
                    profile.lastRegistrationSuccessAt,
                lastRegistrationErrorCode:
                    profile.lastRegistrationErrorCode,
                historyBackfillCursor: profile.historyBackfillCursor,
                updatedAt: profile.updatedAt,
                openAuditCount:
                    try DBNotificationOpenAuditRecord.fetchCount(
                        database
                    )
            )
        }
    }

}
