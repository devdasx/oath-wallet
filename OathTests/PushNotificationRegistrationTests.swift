import Foundation
import GRDB
import Testing
@testable import Aperture

struct PushNotificationRegistrationTests {
    @Test
    func notificationDefaultsEnableReceivedAndDisableSent() throws {
        let database = try WalletDatabase.temporary()
        let settings = try database.applicationSettingsSynchronously()

        #expect(settings.notificationsEnabled == false)
        #expect(
            settings.receivedTransactionNotificationsEnabled == true
        )
        #expect(
            settings.sentTransactionNotificationsEnabled == false
        )
        #expect(settings.adminNotificationsEnabled == true)
        #expect(settings.notificationWelcomeWasPresented == false)
        #expect(settings.notificationsWereExplicitlyDisabled == false)
        #expect(settings.lastPresentedWhatsNewVersion == nil)
    }

    @Test
    func whatsNewVersionPersistsInWalletDatabase() async throws {
        let database = try WalletDatabase.temporary()
        var settings = try database.applicationSettingsSynchronously()
        settings.lastPresentedWhatsNewVersion = "2.40.12"

        try await database.saveApplicationSettings(settings)

        let restored = try database.applicationSettingsSynchronously()
        #expect(restored.lastPresentedWhatsNewVersion == "2.40.12")
    }

    @Test
    func appResetPreservesThePresentedWhatsNewVersion() {
        var settings = WalletApplicationSettings.default
        settings.lastPresentedWhatsNewVersion = "2.40.12"

        let reset = WalletApplicationSettings.resetDefaults(
            preserving: settings.appResetPreservedPreferences
        )

        #expect(reset.lastPresentedWhatsNewVersion == "2.40.12")
    }

    @Test
    func notificationWelcomePresentationPersistsInWalletDatabase()
        async throws {
        let database = try WalletDatabase.temporary()
        var settings = try database.applicationSettingsSynchronously()
        settings.notificationWelcomeWasPresented = true
        settings.notificationsWereExplicitlyDisabled = true

        try await database.saveApplicationSettings(settings)

        let restored = try database.applicationSettingsSynchronously()
        #expect(restored.notificationWelcomeWasPresented == true)
        #expect(restored.notificationsWereExplicitlyDisabled == true)
    }

    @Test
    func notificationMasterPreferenceReconcilesSystemAuthorization() {
        #expect(
            PushNotificationMasterPreferenceAction.resolve(
                authorizationState: .authorized,
                notificationsEnabled: false,
                explicitlyDisabled: false
            ) == .enableFromSystemAuthorization
        )
        #expect(
            PushNotificationMasterPreferenceAction.resolve(
                authorizationState: .authorized,
                notificationsEnabled: false,
                explicitlyDisabled: true
            ) == .none
        )
        #expect(
            PushNotificationMasterPreferenceAction.resolve(
                authorizationState: .denied,
                notificationsEnabled: true,
                explicitlyDisabled: false
            ) == .disableForSystemAuthorization
        )
        #expect(
            PushNotificationMasterPreferenceAction.resolve(
                authorizationState: .unknown,
                notificationsEnabled: false,
                explicitlyDisabled: false
            ) == .none
        )
    }

    @Test
    func changingAPNSContextClearsAPreviouslyStoredToken() {
        var identity = PushInstallationIdentity(
            installationID: UUID().uuidString.lowercased(),
            credential: Data(repeating: 1, count: 32),
            apnsToken: Data(repeating: 2, count: 32)
        )

        let didBind = identity.bindAPNSContext(
            topic: "com.aperture.wallet",
            environment: "sandbox"
        )
        #expect(didBind)
        #expect(identity.apnsToken == nil)
        #expect(identity.apnsTopic == "com.aperture.wallet")
        #expect(identity.apnsEnvironment == "sandbox")
    }

    @Test
    func registrationPreservesCaseSensitiveChainAddresses() async throws {
        let database = try WalletDatabase.temporary()
        let walletID = "wallet-notification-test"
        let now = Date().timeIntervalSince1970

        try await database.pool.write { db in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Test",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: "opaque-reference",
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil
            ).insert(db)

            let accounts = [
                (
                    "account-evm",
                    "eth",
                    "0xAbCd000000000000000000000000000000001234"
                ),
                (
                    "account-tron",
                    "tron",
                    "TQn9Y2khEsLJW1ChVWFMSMeRDow5KcbLSE"
                ),
                (
                    "account-solana",
                    "solana",
                    "A1TMhSGzQxMr1TboBKtgixKz1sS6REASMxPo1qsyTSJd"
                ),
                (
                    "account-bitcoin",
                    "bitcoin",
                    "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
                )
            ]

            for (id, networkID, address) in accounts {
                try DBWalletAccountRecord(
                    id: id,
                    walletID: walletID,
                    networkID: networkID,
                    address: address,
                    normalizedAddress: address.lowercased(),
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

            try db.execute(
                sql: """
                INSERT INTO solanaSyncState (
                    address,
                    accountID,
                    newestSignature,
                    oldestSignature,
                    providerHistoryComplete,
                    updatedAt
                ) VALUES (?, ?, NULL, NULL, 0, ?)
                """,
                arguments: [
                    "8VxKTokenAccountCaseSensitive11111111111111111",
                    "account-solana",
                    now
                ]
            )
        }

        let registration = try await
            PushNotificationRegistrationRepository(database: database)
            .snapshot(
                identity: PushInstallationIdentity(
                    installationID:
                        "00000000-0000-0000-0000-000000000001",
                    credential: Data(repeating: 7, count: 32),
                    apnsToken: Data(repeating: 1, count: 32),
                    remoteUserID:
                        "00000000-0000-4000-8000-000000000101"
                ),
                apnsEnvironment: "sandbox"
            )

        let accounts = registration.wallets
            .flatMap(\.accounts)
        let byNetwork = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.networkID, $0) }
        )

        #expect(
            byNetwork["eth"]?.monitoredAddresses.first?
                .normalizedAddress
                == "0xabcd000000000000000000000000000000001234"
        )
        #expect(byNetwork["eth"]?.chainID == "1")
        #expect(
            byNetwork["tron"]?.monitoredAddresses.first?
                .normalizedAddress
                == "TQn9Y2khEsLJW1ChVWFMSMeRDow5KcbLSE"
        )
        #expect(
            byNetwork["solana"]?.monitoredAddresses.first?
                .normalizedAddress
                == "A1TMhSGzQxMr1TboBKtgixKz1sS6REASMxPo1qsyTSJd"
        )
        #expect(byNetwork["solana"]?.chainID == "-501")
        #expect(
            byNetwork["bitcoin"]?.monitoredAddresses.first?
                .normalizedAddress
                == "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
        )
        #expect(
            byNetwork["solana"]?.monitoredAddresses.contains {
                $0.role == "solana_token_account"
                    && $0.address
                        == "8VxKTokenAccountCaseSensitive11111111111111111"
            } == true
        )
    }

    @Test
    @MainActor
    func importedBitcoinCollectionRegistersEveryPublicAddress()
        async throws {
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(
            service: "push-bitcoin-import-test.\(UUID())"
        )
        defer { try? vault.deleteAll() }
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Fixtures/BitcoinImport/descriptor-clear.dat"
            )
        let material = try BitcoinCoreBackupImporter.parse(
            Data(contentsOf: fixtureURL)
        )
        let identity = try await database.persistImportedWallet(
            draft: material.importDraft(),
            security: .reuseExistingProfile,
            vault: vault
        )
        let expectedAddresses = Set(
            try await database.bitcoinImportedAddresses(
                walletID: identity.walletID,
                material: material
            ).map(\.address)
        )

        let snapshot = try await PushNotificationRegistrationRepository(
            database: database
        ).snapshot(
            identity: PushInstallationIdentity(
                installationID:
                    "00000000-0000-0000-0000-000000000003",
                credential: Data(repeating: 3, count: 32),
                apnsToken: Data(repeating: 4, count: 32),
                remoteUserID:
                    "00000000-0000-4000-8000-000000000103"
            ),
            apnsEnvironment: "sandbox"
        )

        let registeredWallet = try #require(
            snapshot.wallets.first { $0.walletID == identity.walletID }
        )
        let account = try #require(registeredWallet.accounts.first)
        #expect(account.networkID == "bitcoin")
        #expect(
            Set(account.monitoredAddresses.map(\.address))
                == expectedAddresses
        )
        #expect(
            account.monitoredAddresses.allSatisfy {
                $0.role == "utxo_owner"
                    && $0.normalizedAddress == $0.address
            }
        )
        #expect(
            account.monitoredAddresses.count == expectedAddresses.count
        )
    }

    @Test
    func snapshotJSONMatchesServerFieldNamesAndContainsNoSecrets()
        async throws {
        let database = try WalletDatabase.temporary()
        let snapshot = try await
            PushNotificationRegistrationRepository(database: database)
            .snapshot(
                identity: PushInstallationIdentity(
                    installationID:
                        "00000000-0000-0000-0000-000000000002",
                    credential: Data(repeating: 9, count: 32),
                    apnsToken: Data(repeating: 10, count: 32),
                    remoteUserID:
                        "00000000-0000-4000-8000-000000000102"
                ),
                apnsEnvironment: "sandbox"
            )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(
            decoding: try encoder.encode(snapshot),
            as: UTF8.self
        )

        #expect(json.contains("\"environment\":\"sandbox\""))
        #expect(json.contains("\"locale\":"))
        #expect(json.contains("\"master\":false"))
        #expect(!json.contains("bootstrapCredential"))
        #expect(!json.contains("snapshotDigest"))
        #expect(!json.contains("apnsEnvironment"))
        #expect(!json.contains("secretKeyReference"))
        #expect(!json.contains("recoveryPhrase"))
        #expect(!json.contains("privateKey"))
        #expect(!json.contains("derivationPath"))
        #expect(!json.contains("publicKey"))
    }

    @Test
    func backendPayloadUsesCamelCaseKindAndSubtitleContract() throws {
        let notificationID =
            "5d74d64d-9441-5d2b-a513-dbd3b061935a"
        let payload = try #require(
            PushNotificationPayload(userInfo: [
                "notificationID": notificationID,
                "kind": "received",
                "localizationKey": "notification.transaction.received",
                "localizationArguments": [
                    "1.25",
                    "ETH",
                    "ethereum"
                ]
            ])
        )

        #expect(payload.notificationID == notificationID)
        #expect(payload.category == .received)
        #expect(payload.titleKey == "notification.received.title")
        #expect(payload.bodyKey == "notification.received.body")
        #expect(
            payload.localizationArguments
                == ["1.25", "ETH", "ethereum"]
        )
    }

    @Test
    func legacySnakeCasePayloadRemainsReadable() throws {
        let payload = try #require(
            PushNotificationPayload(userInfo: [
                "notification_id":
                    "20c13bef-76f9-537a-b41d-c3418f408fbd",
                "category": "sent",
                "wallet_id": "wallet-1",
                "network_id": "eth",
                "transaction_hash": "0xabc123",
                "title_key": "notification.sent.title",
                "body_key": "notification.sent.body",
                "arguments": [
                    "0.5",
                    "ETH",
                    "Main Wallet",
                    "Ethereum"
                ],
                "created_at": "2026-07-26T12:34:56.789Z"
            ])
        )

        #expect(payload.category == .sent)
        #expect(payload.walletID == "wallet-1")
        #expect(payload.networkID == "eth")
        #expect(payload.transactionHash == "0xabc123")
        #expect(payload.titleKey == "notification.sent.title")
        #expect(payload.bodyKey == "notification.sent.body")
        #expect(
            payload.localizationArguments
                == ["0.5", "ETH", "Main Wallet", "Ethereum"]
        )
        #expect(
            payload.createdAt
                == PushServiceDate.parse(
                    "2026-07-26T12:34:56.789Z"
                )?.timeIntervalSince1970
        )
    }

    @Test
    func apsLocalizationMetadataIsParsedAndConstrained() throws {
        let payload = try #require(
            PushNotificationPayload(userInfo: [
                "notification_id":
                    "02ea650d-adc2-48fd-a39f-f35f0a27ee1a",
                "category": "received",
                "aps": [
                    "alert": [
                        "title-loc-key":
                            "notification.received.title",
                        "loc-key":
                            "notification.received.body.priced"
                    ]
                ]
            ])
        )
        #expect(payload.titleKey == "notification.received.title")
        #expect(
            payload.bodyKey == "notification.received.body.priced"
        )

        let constrained = try #require(
            PushNotificationPayload(userInfo: [
                "notification_id":
                    "ffbf1b35-028d-4c3c-a9f4-b96e44841518",
                "category": "received",
                "title_key": "settings.reset.confirmation.title",
                "body_key": "settings.reset.confirmation.message"
            ])
        )
        #expect(
            constrained.titleKey == "notification.received.title"
        )
        #expect(
            constrained.bodyKey == "notification.received.body"
        )
    }

    @Test
    @MainActor
    func installationChangeRotatesRemoteUserIdentity() async throws {
        let database = try WalletDatabase.temporary()
        var settings = WalletApplicationSettings.default
        settings.currencyCode = "USD"
        settings.currencyRateStorageValue = "1"
        try await database.saveApplicationSettings(settings)
        let repository =
            PushNotificationRegistrationRepository(database: database)
        let firstIdentity = PushInstallationIdentity(
            installationID:
                "6e16eb5e-b66e-43fd-a870-462e992d66c3",
            credential: Data(repeating: 1, count: 32),
            apnsToken: Data(repeating: 2, count: 32),
            remoteUserID:
                "ff02bf98-6eee-48b2-becb-fc0e7ab75bf5"
        )
        let first = try await repository.snapshot(
            identity: firstIdentity,
            apnsEnvironment: "sandbox"
        )
        let attempt = try await repository.markRegistrationAttempt()
        #expect(
            try await repository.markRegistrationSucceeded(
                snapshotDigest: String(repeating: "a", count: 43),
                installationID: firstIdentity.installationID,
                reconciliationGeneration: attempt
            )
        )
        try await PushNotificationPersistence(database: database)
            .setHistoryBackfillCursor("old_identity_cursor")

        let secondIdentity = PushInstallationIdentity(
            installationID:
                "30fc50e6-b70e-448f-8cb2-02058971df2a",
            credential: Data(repeating: 3, count: 32),
            apnsToken: Data(repeating: 4, count: 32),
            remoteUserID:
                "be9dd0e7-b4f2-4a06-b562-d99e0c43852c"
        )
        let second = try await repository.snapshot(
            identity: secondIdentity,
            apnsEnvironment: "sandbox"
        )
        let profile = try await database.pool.read { database in
            try DBNotificationProfileRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            )
        }

        #expect(first.remoteUserID != second.remoteUserID)
        #expect(first.currencyCode == "USD")
        #expect(first.currencyRatePerUSDBase10 == "1")
        #expect(
            profile?.installationID == secondIdentity.installationID
        )
        #expect(profile?.lastRegistrationSuccessAt == nil)
        #expect(profile?.reconciliationNeeded == true)
        #expect(profile?.historyBackfillCursor == nil)
    }

    @Test
    @MainActor
    func deviceMigrationRotatesAnUnboundRemoteIdentity()
        async throws {
        let database = try WalletDatabase.temporary()
        let repository =
            PushNotificationRegistrationRepository(database: database)
        let identity = PushInstallationIdentity(
            installationID:
                "4651d4f1-7bf0-4b75-8585-f334c8716222",
            credential: Data(repeating: 5, count: 32),
            apnsToken: Data(repeating: 6, count: 32),
            remoteUserID:
                "5617dfea-34cc-4306-97f5-11a5ac36c5ea"
        )
        let existingRemoteUserID =
            "649d2729-07a0-493f-9a21-2586ded9a9df"
        let now = Date().timeIntervalSince1970
        try await database.pool.write { database in
            try DBNotificationProfileRecord(
                profileID: WalletDatabase.defaultProfileID,
                remoteUserID: existingRemoteUserID,
                installationID: nil,
                reconciliationNeeded: false,
                reconciliationGeneration: 0,
                lastSnapshotDigest: String(
                    repeating: "b",
                    count: 43
                ),
                lastRegistrationAttemptAt: now,
                lastRegistrationSuccessAt: now,
                lastRegistrationErrorCode: nil,
                updatedAt: now
            ).insert(database)
        }

        #expect(
            await repository.compatibleRemoteUserID(
                installationID: identity.installationID,
                allowsUnboundProfile: true
            ) == existingRemoteUserID
        )
        #expect(
            await repository.compatibleRemoteUserID(
                installationID: identity.installationID,
                allowsUnboundProfile: false
            ) == nil
        )

        let snapshot = try await repository.snapshot(
            identity: identity,
            apnsEnvironment: "sandbox",
            forceRemoteUserRotation: true
        )

        #expect(snapshot.remoteUserID != existingRemoteUserID)
        #expect(
            await repository.hasSuccessfulRegistration(
                installationID: identity.installationID
            ) == false
        )
    }

    @Test
    @MainActor
    func staleRegistrationCompletionCannotClearNewerWork()
        async throws {
        let database = try WalletDatabase.temporary()
        let repository =
            PushNotificationRegistrationRepository(database: database)
        let identity = PushInstallationIdentity(
            installationID:
                "d437198e-1208-47e2-8488-20b9b940cfb7",
            credential: Data(repeating: 7, count: 32),
            apnsToken: Data(repeating: 8, count: 32),
            remoteUserID:
                "1e5916b8-8eaf-45e1-a491-7b8daec39d32"
        )
        _ = try await repository.snapshot(
            identity: identity,
            apnsEnvironment: "sandbox"
        )
        let staleAttempt =
            try await repository.markRegistrationAttempt()
        try await repository.markReconciliationNeeded()

        let didCommit = try await repository
            .markRegistrationSucceeded(
                snapshotDigest: String(repeating: "c", count: 43),
                installationID: identity.installationID,
                reconciliationGeneration: staleAttempt
            )

        #expect(didCommit == false)
        #expect(await repository.isReconciliationNeeded() == true)
    }

    @Test
    func versionOneKeychainIdentityRemainsDecodable() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "installationID":
                "1ca56138-8172-4de7-a64a-10a2948666fd",
            "credential": Data(repeating: 4, count: 32)
                .base64EncodedString(),
            "apnsToken": NSNull()
        ])

        let identity = try JSONDecoder().decode(
            PushInstallationIdentity.self,
            from: data
        )

        #expect(identity.remoteUserID == nil)
        #expect(identity.credential == Data(repeating: 4, count: 32))
    }

    @Test
    func bootstrapRequestsAndBindsARegistrationChallenge()
        async throws {
        let challenge = String(repeating: "a", count: 43)
        let server = PushRegistrationChallengeTestServer(replies: [
            try .challenge(challenge),
            try .registrationSuccess()
        ])
        let client = try Self.challengeClient(server: server)

        _ = try await client.reconcile(
            snapshot: Self.challengeSnapshot,
            identity: Self.challengeIdentity,
            serverRegistrationKnown: false
        )

        let requests = await server.recordedRequests()
        #expect(
            requests.compactMap { $0.url?.path } == [
                "/v1/registration-challenges",
                "/v1/installations"
            ]
        )
        let challengeRequest = try #require(requests.first)
        #expect(challengeRequest.httpMethod == "POST")
        #expect(
            challengeRequest.value(
                forHTTPHeaderField: "X-Aperture-Installation-ID"
            ) == Self.challengeIdentity.installationID
        )
        #expect(
            challengeRequest.value(
                forHTTPHeaderField: "Authorization"
            ) == "Installation \(Self.credentialHeaderValue)"
        )
        #expect(
            challengeRequest.value(
                forHTTPHeaderField:
                    "X-Aperture-Registration-Challenge"
            ) == nil
        )
        let requestID = try #require(
            challengeRequest.value(
                forHTTPHeaderField: "X-Request-ID"
            )
        )
        #expect(UUID(uuidString: requestID) != nil)
        let challengeData = try #require(challengeRequest.httpBody)
        let challengeObject = try JSONSerialization.jsonObject(
            with: challengeData
        )
        let challengeBody = try #require(
            challengeObject as? [String: String]
        )
        #expect(
            Set(challengeBody.keys)
                == Set(["installationID", "apnsToken"])
        )
        #expect(
            challengeBody["installationID"]
                == Self.challengeIdentity.installationID
        )
        #expect(
            challengeBody["apnsToken"]
                == Self.challengeSnapshot.apnsToken
        )

        let registrationRequest = try #require(requests.last)
        #expect(
            registrationRequest.value(
                forHTTPHeaderField:
                    "X-Aperture-Registration-Challenge"
            ) == challenge
        )
        #expect(
            registrationRequest.value(
                forHTTPHeaderField: "Authorization"
            ) == challengeRequest.value(
                forHTTPHeaderField: "Authorization"
            )
        )
    }

    @Test
    func registrationChallengeRejectsInvalidStatusAndMetadata()
        async throws {
        let valid = String(repeating: "a", count: 43)
        let replies = [
            try PushRegistrationChallengeTestServer.Reply.challenge(
                valid,
                status: 200
            ),
            try .challenge(String(repeating: "a", count: 42)),
            try .challenge("\(String(repeating: "a", count: 42))="),
            try .challenge(
                valid,
                expiresAt: "not-a-date"
            ),
            try .challenge(
                valid,
                expiresAt: "2026-07-26T00:00:00.000Z",
                serverTime: "2026-07-26T00:00:01.000Z"
            )
        ]

        for reply in replies {
            let server = PushRegistrationChallengeTestServer(
                replies: [reply]
            )
            let client = try Self.challengeClient(server: server)
            do {
                _ = try await client.reconcile(
                    snapshot: Self.challengeSnapshot,
                    identity: Self.challengeIdentity,
                    serverRegistrationKnown: false
                )
                Issue.record(
                    "Expected invalid registration challenge rejection"
                )
            } catch let error as PushNotificationAPIError {
                #expect(
                    error.diagnosticCode.hasPrefix(
                        "response_invalid_"
                    )
                )
            }
            #expect(await server.recordedRequests().count == 1)
        }
    }

    @Test
    func expiredRegistrationChallengeRetriesExactlyOnce()
        async throws {
        let first = String(repeating: "a", count: 43)
        let replacement = String(repeating: "b", count: 43)
        let server = PushRegistrationChallengeTestServer(replies: [
            try .challenge(first),
            try .error(
                status: 401,
                code: "registration_challenge_invalid_or_expired"
            ),
            try .challenge(replacement),
            try .registrationSuccess()
        ])
        let client = try Self.challengeClient(server: server)

        _ = try await client.reconcile(
            snapshot: Self.challengeSnapshot,
            identity: Self.challengeIdentity,
            serverRegistrationKnown: false
        )

        let requests = await server.recordedRequests()
        #expect(
            requests.compactMap { $0.url?.path } == [
                "/v1/registration-challenges",
                "/v1/installations",
                "/v1/registration-challenges",
                "/v1/installations"
            ]
        )
        let installationRequests = requests.filter {
            $0.url?.path == "/v1/installations"
        }
        #expect(
            installationRequests.map {
                $0.value(
                    forHTTPHeaderField:
                        "X-Aperture-Registration-Challenge"
                )
            } == [first, replacement]
        )
    }

    @Test
    func malformedChallengeFailureDoesNotTriggerExpiryRetry()
        async throws {
        let server = PushRegistrationChallengeTestServer(replies: [
            try .challenge(String(repeating: "a", count: 43)),
            try .error(
                status: 400,
                code: "registration_challenge_required"
            )
        ])
        let client = try Self.challengeClient(server: server)

        do {
            _ = try await client.reconcile(
                snapshot: Self.challengeSnapshot,
                identity: Self.challengeIdentity,
                serverRegistrationKnown: false
            )
            Issue.record("Expected malformed challenge failure")
        } catch let error as PushNotificationAPIError {
            #expect(
                error.diagnosticCode
                    == "server_400_registration_challenge_required"
            )
        }
        #expect(await server.recordedRequests().count == 2)
    }

}
