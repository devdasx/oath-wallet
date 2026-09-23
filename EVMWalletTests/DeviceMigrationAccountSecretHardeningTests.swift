import Foundation
import GRDB
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct DeviceMigrationAccountSecretHardeningTests {
    @Test
    func bitcoinFamilyDerivationRejectsInvalidScalarBoundaries() throws {
        let service = BitcoinFamilyDerivationService()
        let invalidKeys = [
            Data(),
            Data(repeating: 0, count: 32),
            Data(repeating: 1, count: 31),
            Data(repeating: 1, count: 33),
            Self.secp256k1Order,
            Self.secp256k1OrderPlusOne
        ]

        for key in invalidKeys {
            #expect(throws: BitcoinFamilyDerivationError.self) {
                try service.derive(
                    privateKey: key,
                    chain: .bitcoin,
                    format: .wifCompressed
                )
            }
        }

        let material = try service.derive(
            privateKey: Self.secp256k1OrderMinusOne,
            chain: .bitcoin,
            format: .wifCompressed
        )
        #expect(!material.address.isEmpty)
        #expect(!material.publicKey.isEmpty)
    }

    @Test
    func migrationVerifierRejectsCurveInvalidBitcoinSecret()
        async throws {
        let fixture = try await privateKeyFixture(
            network: .bitcoin,
            format: .wifCompressed
        )
        defer { fixture.deleteSecret() }

        #expect(throws: DeviceMigrationError.invalidWalletSecret) {
            try DeviceMigrationAccountSecretVerifier.validate(
                source: fixture.database.pool,
                secrets: [
                    DeviceMigrationWalletSecret(
                        walletID: fixture.walletID,
                        kind: .privateKey,
                        data: Self.secp256k1Order
                    )
                ]
            )
        }
    }

    @Test
    func softwareAccountRequiresStoredPublicKey() async throws {
        for replacement: String? in [nil, ""] {
            let fixture = try await recoveryPhraseFixture()
            defer { fixture.deleteSecret() }
            try await fixture.database.pool.write { database in
                try database.execute(
                    sql: """
                    UPDATE walletAccounts
                    SET publicKey = ?
                    WHERE walletID = ?
                    """,
                    arguments: [replacement, fixture.walletID]
                )
            }

            #expect(throws: DeviceMigrationError.invalidDatabase) {
                try verifyRecoveryPhraseFixture(fixture)
            }
        }
    }

    @Test
    func emptyWalletWithoutLocalSecretIsRejected() async throws {
        for kind in [
            DatabaseWalletKind.hardware,
            DatabaseWalletKind.watchOnly
        ] {
            let database = try WalletDatabase.temporary()
            try await insertWalletWithoutAccount(
                kind: kind,
                into: database
            )

            #expect(throws: DeviceMigrationError.invalidDatabase) {
                try DeviceMigrationAccountSecretVerifier.validate(
                    source: database.pool,
                    secrets: []
                )
            }
        }
    }

    @Test
    func hardwarePublicKeyMustMatchStoredAddress() async throws {
        let database = try WalletDatabase.temporary()
        let addressDraft = try WalletCoreService.importRecoveryPhrase(
            Self.firstPhrase
        )
        let mismatchedDraft = try WalletCoreService.importRecoveryPhrase(
            Self.secondPhrase
        )
        try await insertHardwareAccount(
            address: addressDraft.address,
            normalizedAddress: addressDraft.normalizedAddress,
            publicKey: mismatchedDraft.publicKey,
            into: database
        )

        #expect(throws: DeviceMigrationError.invalidDatabase) {
            try DeviceMigrationAccountSecretVerifier.validate(
                source: database.pool,
                secrets: []
            )
        }
    }

    @Test
    func offCurveHardwarePublicKeyIsRejectedBeforeAddressBinding()
        async throws {
        var encodedPoint = Data([0x04])
        encodedPoint.append(Data(repeating: 0, count: 64))
        let shapedKey = try #require(
            PublicKey(
                data: encodedPoint,
                type: .secp256k1Extended
            )
        )
        let address = CoinType.tron.deriveAddressFromPublicKey(
            publicKey: shapedKey
        )
        #expect(CoinType.tron.validate(address: address))

        let database = try WalletDatabase.temporary()
        try await insertHardwareAccount(
            address: address,
            normalizedAddress: address,
            publicKey: encodedPoint.map {
                String(format: "%02x", $0)
            }.joined(),
            networkID: TronConstants.networkID,
            into: database
        )

        #expect(throws: DeviceMigrationError.invalidDatabase) {
            try DeviceMigrationAccountSecretVerifier.validate(
                source: database.pool,
                secrets: []
            )
        }
    }

    @Test
    func impossibleBitcoinFamilyFormatIsRejected() async throws {
        let fixture = try await privateKeyFixture(
            network: .bitcoinCash,
            format: .extendedLegacy
        )
        defer { fixture.deleteSecret() }
        try await fixture.database.pool.write { database in
            try database.execute(
                sql: """
                UPDATE walletAccounts
                SET derivationPath = ?
                WHERE walletID = ?
                """,
                arguments: [
                    PrivateKeyImportFormat.extendedNativeSegwit
                        .accountMarker,
                    fixture.walletID
                ]
            )
        }

        #expect(throws: DeviceMigrationError.invalidWalletSecret) {
            try verifyPrivateKeyFixture(fixture)
        }
    }

    @Test
    func recordedMnemonicWordCountMustMatchSecret() async throws {
        let fixture = try await recoveryPhraseFixture()
        defer { fixture.deleteSecret() }
        try await fixture.database.pool.write { database in
            try database.execute(
                sql: """
                UPDATE wallets
                SET mnemonicWordCount = 24
                WHERE id = ?
                """,
                arguments: [fixture.walletID]
            )
        }

        #expect(throws: DeviceMigrationError.invalidDatabase) {
            try verifyRecoveryPhraseFixture(fixture)
        }
    }

    @Test
    func emptySoftwareWalletIsDatabaseError() async throws {
        let database = try WalletDatabase.temporary()
        try await insertWalletWithoutAccount(
            kind: .created,
            into: database
        )

        #expect(throws: DeviceMigrationError.invalidDatabase) {
            try DeviceMigrationAccountSecretVerifier.validate(
                source: database.pool,
                secrets: [
                    DeviceMigrationWalletSecret(
                        walletID: "empty-created",
                        kind: .recoveryPhrase,
                        data: Data(Self.firstPhrase.utf8)
                    )
                ]
            )
        }
    }

    @Test
    func softwareWatchOnlyRoleIsDatabaseError() async throws {
        let fixture = try await recoveryPhraseFixture()
        defer { fixture.deleteSecret() }
        try await fixture.database.pool.write { database in
            try database.execute(
                sql: """
                UPDATE walletAccounts
                SET isWatchOnly = 1
                WHERE walletID = ?
                """,
                arguments: [fixture.walletID]
            )
        }

        #expect(throws: DeviceMigrationError.invalidDatabase) {
            try verifyRecoveryPhraseFixture(fixture)
        }
    }

    @Test
    func privateKeyMnemonicMetadataIsDatabaseError() async throws {
        let fixture = try await privateKeyFixture(
            network: .evm,
            format: .rawSecp256k1
        )
        defer { fixture.deleteSecret() }
        try await fixture.database.pool.write { database in
            try database.execute(
                sql: """
                UPDATE wallets
                SET mnemonicWordCount = 12
                WHERE id = ?
                """,
                arguments: [fixture.walletID]
            )
        }

        #expect(throws: DeviceMigrationError.invalidDatabase) {
            try verifyPrivateKeyFixture(fixture)
        }
    }

    @Test
    func accountIndexMustMatchProductionAccount() async throws {
        let fixture = try await recoveryPhraseFixture()
        defer { fixture.deleteSecret() }
        try await fixture.database.pool.write { database in
            try database.execute(
                sql: """
                UPDATE walletAccounts
                SET accountIndex = -1
                WHERE walletID = ?
                """,
                arguments: [fixture.walletID]
            )
        }

        #expect(throws: DeviceMigrationError.invalidDatabase) {
            try verifyRecoveryPhraseFixture(fixture)
        }
    }

    @Test
    func recordedRecoveryDerivationPathMustMatchAccount() async throws {
        let fixture = try await recoveryPhraseFixture()
        defer { fixture.deleteSecret() }
        try await fixture.database.pool.write { database in
            try database.execute(
                sql: """
                UPDATE walletAccounts
                SET derivationPath = ?
                WHERE walletID = ?
                """,
                arguments: [
                    "m/44'/60'/1'/0/0",
                    fixture.walletID
                ]
            )
        }

        #expect(throws: DeviceMigrationError.invalidWalletSecret) {
            try verifyRecoveryPhraseFixture(fixture)
        }
    }

    @Test
    func importedSolanaAccountRequiresPhantomLabel() async throws {
        let fixture = try await privateKeyFixture(
            network: .solana,
            format: .solanaSeed
        )
        defer { fixture.deleteSecret() }
        try await fixture.database.pool.write { database in
            try database.execute(
                sql: """
                UPDATE walletAccounts
                SET label = ?
                WHERE walletID = ?
                """,
                arguments: [
                    SolanaDerivationKind.trustWallet.rawValue,
                    fixture.walletID
                ]
            )
        }

        #expect(throws: DeviceMigrationError.invalidDatabase) {
            try verifyPrivateKeyFixture(fixture)
        }
    }

    @Test
    func solanaKeypairNormalizesToSeedAndVerifies() async throws {
        let seed = Self.validPrivateKey
        let seedDraft = try PrivateKeyImportService.revalidate(
            privateKeyData: seed,
            network: .solana,
            format: .solanaSeed
        )
        let publicKey = try #require(
            Data(base64Encoded: seedDraft.publicKey)
        )
        var keypair = seed
        keypair.append(publicKey)
        let encoded = try #require(
            String(
                data: JSONEncoder().encode([UInt8](keypair)),
                encoding: .utf8
            )
        )
        let keypairDraft = try PrivateKeyImportService.importKey(
            encoded,
            network: .solana
        )
        guard case let .privateKey(data, network, format) =
            keypairDraft.secret else {
            Issue.record("Expected a normalized private-key draft.")
            return
        }
        #expect(data == seed)
        #expect(network == .solana)
        #expect(format == .solanaKeypair)

        let fixture = try await persist(
            draft: keypairDraft,
            secretData: seed
        )
        defer { fixture.deleteSecret() }
        try verifyPrivateKeyFixture(fixture)
    }
}

private extension DeviceMigrationAccountSecretHardeningTests {
    struct Fixture {
        let database: WalletDatabase
        let walletID: String
        let sourceReference: String
        let secretData: Data

        func deleteSecret() {
            try? WalletSecretVault.shared.deleteIfPresent(
                reference: sourceReference
            )
        }
    }

    static let firstPhrase = WalletCredentialTestFixtures.recoveryPhrase()
    static let secondPhrase = WalletCredentialTestFixtures.recoveryPhrase()
    static let validPrivateKey = WalletCredentialTestFixtures.privateKey()
    static let secp256k1Order = Data([
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
        0xba, 0xae, 0xdc, 0xe6, 0xaf, 0x48, 0xa0, 0x3b,
        0xbf, 0xd2, 0x5e, 0x8c, 0xd0, 0x36, 0x41, 0x41
    ])
    static let secp256k1OrderMinusOne: Data = {
        var value = secp256k1Order
        value[value.index(before: value.endIndex)] = 0x40
        return value
    }()
    static let secp256k1OrderPlusOne: Data = {
        var value = secp256k1Order
        value[value.index(before: value.endIndex)] = 0x42
        return value
    }()

    func recoveryPhraseFixture() async throws -> Fixture {
        let database = try WalletDatabase.temporary()
        let draft = try WalletCoreService.importRecoveryPhrase(
            Self.firstPhrase
        )
        let identity = try await database.persistImportedWallet(
            draft: draft,
            security: .reuseExistingProfile,
            vault: .shared
        )
        return try await fixture(
            database: database,
            walletID: identity.walletID,
            secretData: Data(Self.firstPhrase.utf8)
        )
    }

    func privateKeyFixture(
        network: PrivateKeyImportNetwork,
        format: PrivateKeyImportFormat
    ) async throws -> Fixture {
        let draft = try PrivateKeyImportService.revalidate(
            privateKeyData: Self.validPrivateKey,
            network: network,
            format: format
        )
        return try await persist(
            draft: draft,
            secretData: Self.validPrivateKey
        )
    }

    func persist(
        draft: WalletImportDraft,
        secretData: Data
    ) async throws -> Fixture {
        let database = try WalletDatabase.temporary()
        let identity = try await database.persistImportedWallet(
            draft: draft,
            security: .reuseExistingProfile,
            vault: .shared
        )
        return try await fixture(
            database: database,
            walletID: identity.walletID,
            secretData: secretData
        )
    }

    func fixture(
        database: WalletDatabase,
        walletID: String,
        secretData: Data
    ) async throws -> Fixture {
        let reference = try await database.pool.read { connection in
            try #require(
                try DBWalletRecord.fetchOne(
                    connection,
                    key: walletID
                )?.secretKeyReference
            )
        }
        return Fixture(
            database: database,
            walletID: walletID,
            sourceReference: reference,
            secretData: secretData
        )
    }

    func verifyRecoveryPhraseFixture(_ fixture: Fixture) throws {
        try DeviceMigrationAccountSecretVerifier.validate(
            source: fixture.database.pool,
            secrets: [
                DeviceMigrationWalletSecret(
                    walletID: fixture.walletID,
                    kind: .recoveryPhrase,
                    data: fixture.secretData
                )
            ]
        )
    }

    func verifyPrivateKeyFixture(_ fixture: Fixture) throws {
        try DeviceMigrationAccountSecretVerifier.validate(
            source: fixture.database.pool,
            secrets: [
                DeviceMigrationWalletSecret(
                    walletID: fixture.walletID,
                    kind: .privateKey,
                    data: fixture.secretData
                )
            ]
        )
    }

    func insertWalletWithoutAccount(
        kind: DatabaseWalletKind,
        into walletDatabase: WalletDatabase
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await walletDatabase.pool.write { database in
            try DBWalletRecord(
                id: "empty-\(kind.rawValue)",
                profileID: WalletDatabase.defaultProfileID,
                name: "Empty",
                kind: kind.rawValue,
                secretKeyReference: nil,
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil
            ).insert(database)
        }
    }

    func insertHardwareAccount(
        address: String,
        normalizedAddress: String,
        publicKey: String,
        networkID: String = "eth",
        into walletDatabase: WalletDatabase
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await walletDatabase.pool.write { database in
            let walletID = "hardware-public-key"
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Hardware",
                kind: DatabaseWalletKind.hardware.rawValue,
                secretKeyReference: nil,
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil
            ).insert(database)
            try DBWalletAccountRecord(
                id: "hardware-public-key:eth:0",
                walletID: walletID,
                networkID: networkID,
                address: address,
                normalizedAddress: normalizedAddress,
                label: nil,
                derivationPath: nil,
                accountIndex: 0,
                publicKey: publicKey,
                isWatchOnly: true,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(database)
        }
    }
}
