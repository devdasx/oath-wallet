import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct DeviceMigrationAccountSecretVerificationTests {
    @Test
    func recoveryPhraseVerifiesEveryDerivedNetworkAccount()
        async throws
    {
        let source = try WalletDatabase.temporary()
        let destination = try WalletDatabase.temporary()
        let vault = WalletSecretVault.shared
        let draft = try WalletCoreService.importRecoveryPhrase(
            Self.firstPhrase
        )
        let identity = try await source.persistImportedWallet(
            draft: draft,
            security: .reuseExistingProfile,
            vault: vault
        )
        var references = [
            try await secretReference(
                in: source,
                walletID: identity.walletID
            )
        ]
        references.append(contentsOf: try await bitcoinHDKeyReferences(
            in: source,
            walletID: identity.walletID
        ))
        defer {
            for reference in references {
                try? vault.deleteIfPresent(reference: reference)
            }
        }

        _ = try await source.ensureBitcoinFamilyAccounts(
            walletID: identity.walletID
        )
        _ = try await source.ensureTronAccount(
            walletID: identity.walletID
        )
        _ = try await source.ensureSolanaAccounts(
            walletID: identity.walletID
        )

        let prepared = try await preparedExport(
            from: source,
            vault: vault
        )
        defer {
            try? FileManager.default.removeItem(
                at: prepared.databaseURL.deletingLastPathComponent()
            )
        }
        let result = try await destination.importDeviceMigration(
            incomingPackage(prepared),
            vault: vault
        )
        references.append(
            try await secretReference(
                in: destination,
                walletID: identity.walletID
            )
        )
        let restoredBitcoinKeyReferences = try await bitcoinHDKeyReferences(
            in: destination,
            walletID: identity.walletID
        )
        references.append(contentsOf: restoredBitcoinKeyReferences)
        let accounts = try await destination.pool.read { database in
            try DBWalletAccountRecord
                .filter(Column("walletID") == identity.walletID)
                .fetchAll(database)
        }

        #expect(result.selectedWallet.walletID == identity.walletID)
        #expect(restoredBitcoinKeyReferences.count == BitcoinHDAddressType.allCases.count * 2)
        #expect(
            try await destination.bitcoinHDAddresses(
                walletID: identity.walletID
            ).count == BitcoinHDAddressType.allCases.count * 2 * 20
        )
        #expect(
            Set(accounts.compactMap {
                BitcoinFamilyChain(rawValue: $0.networkID)
            }) == Set(BitcoinFamilyChain.allCases)
        )
        #expect(
            accounts.filter {
                $0.networkID == TronConstants.networkID
            }.count == 1
        )
        #expect(
            Set(
                accounts.compactMap {
                    guard
                        $0.networkID == SolanaConstants.networkID,
                        let label = $0.label
                    else {
                        return nil
                    }
                    return SolanaDerivationKind(rawValue: label)
                }
            ) == Set(SolanaDerivationKind.allCases)
        )
    }

    @Test
    func importedPrivateKeyVerifiesEverySupportedNetworkVector()
        async throws
    {
        let vectors: [
            (PrivateKeyImportNetwork, PrivateKeyImportFormat)
        ] = [
            (.evm, .rawSecp256k1),
            (.bitcoin, .wifCompressed),
            (.bitcoin, .wifUncompressed),
            (.bitcoin, .extendedLegacy),
            (.bitcoin, .extendedNestedSegwit),
            (.bitcoin, .extendedNativeSegwit),
            (.bitcoinCash, .wifCompressed),
            (.bitcoinCash, .wifUncompressed),
            (.bitcoinCash, .extendedLegacy),
            (.litecoin, .wifCompressed),
            (.litecoin, .wifUncompressed),
            (.litecoin, .extendedLegacy),
            (.litecoin, .extendedNestedSegwit),
            (.dogecoin, .wifCompressed),
            (.dogecoin, .wifUncompressed),
            (.dogecoin, .extendedLegacy),
            (.tron, .rawSecp256k1),
            (.solana, .solanaSeed),
            (.solana, .solanaKeypair)
        ]

        for (network, format) in vectors {
            try await verifyPrivateKeyVector(
                network: network,
                format: format
            )
        }
    }

    @Test
    func recoveryPhraseMismatchRejectsBeforePartialImport()
        async throws
    {
        let source = try WalletDatabase.temporary()
        let destination = try WalletDatabase.temporary()
        let vault = WalletSecretVault.shared
        let identity = try await source.persistImportedWallet(
            draft: try WalletCoreService.importRecoveryPhrase(
                Self.firstPhrase
            ),
            security: .reuseExistingProfile,
            vault: vault
        )
        let sourceReference = try await secretReference(
            in: source,
            walletID: identity.walletID
        )
        defer {
            try? vault.deleteIfPresent(reference: sourceReference)
        }
        let prepared = try await preparedExport(
            from: source,
            vault: vault
        )
        defer {
            try? FileManager.default.removeItem(
                at: prepared.databaseURL.deletingLastPathComponent()
            )
        }
        let package = try packageReplacingOnlySecretData(
            prepared,
            with: Data(Self.secondPhrase.utf8)
        )

        try await expectRejectedWithoutPartialImport(
            package,
            by: destination,
            vault: vault,
            expectedError: .invalidWalletSecret
        )
        let expectedCredential = try WalletRecoveryCredential(
            mnemonic: Self.firstPhrase
        ).encodedData()
        #expect(
            try vault.data(reference: sourceReference)
                == expectedCredential
        )
    }

    @Test
    func importedPrivateKeyMismatchRejectsBeforePartialImport()
        async throws
    {
        let source = try WalletDatabase.temporary()
        let destination = try WalletDatabase.temporary()
        let vault = WalletSecretVault.shared
        let sourceKey = WalletCredentialTestFixtures.privateKey()
        let mismatchedKey = WalletCredentialTestFixtures.privateKey()
        let draft = try PrivateKeyImportService.revalidate(
            privateKeyData: sourceKey,
            network: .bitcoin,
            format: .wifCompressed
        )
        let identity = try await source.persistImportedWallet(
            draft: draft,
            security: .reuseExistingProfile,
            vault: vault
        )
        let sourceReference = try await secretReference(
            in: source,
            walletID: identity.walletID
        )
        defer {
            try? vault.deleteIfPresent(reference: sourceReference)
        }
        let prepared = try await preparedExport(
            from: source,
            vault: vault
        )
        defer {
            try? FileManager.default.removeItem(
                at: prepared.databaseURL.deletingLastPathComponent()
            )
        }
        let package = try packageReplacingOnlySecretData(
            prepared,
            with: mismatchedKey
        )

        try await expectRejectedWithoutPartialImport(
            package,
            by: destination,
            vault: vault,
            expectedError: .invalidWalletSecret
        )
    }

    @Test
    func mismatchedStoredPublicKeyRejectsOtherwiseValidAccount()
        async throws
    {
        let source = try WalletDatabase.temporary()
        let destination = try WalletDatabase.temporary()
        let vault = WalletSecretVault.shared
        let identity = try await source.persistImportedWallet(
            draft: try WalletCoreService.importRecoveryPhrase(
                Self.firstPhrase
            ),
            security: .reuseExistingProfile,
            vault: vault
        )
        let sourceReference = try await secretReference(
            in: source,
            walletID: identity.walletID
        )
        defer {
            try? vault.deleteIfPresent(reference: sourceReference)
        }
        try await source.pool.write { database in
            try database.execute(
                sql: """
                UPDATE walletAccounts
                SET publicKey = ?
                WHERE walletID = ?
                """,
                arguments: [
                    "04deadbeef",
                    identity.walletID
                ]
            )
        }
        let prepared = try await preparedExport(
            from: source,
            vault: vault
        )
        defer {
            try? FileManager.default.removeItem(
                at: prepared.databaseURL.deletingLastPathComponent()
            )
        }

        try await expectRejectedWithoutPartialImport(
            incomingPackage(prepared),
            by: destination,
            vault: vault,
            expectedError: .invalidWalletSecret
        )
    }

    @Test
    func mismatchedDisabledSoftwareAccountIsStillRejectedAtomically()
        async throws
    {
        let source = try WalletDatabase.temporary()
        let destination = try WalletDatabase.temporary()
        let vault = WalletSecretVault.shared
        let identity = try await source.persistImportedWallet(
            draft: try WalletCoreService.importRecoveryPhrase(
                Self.firstPhrase
            ),
            security: .reuseExistingProfile,
            vault: vault
        )
        let sourceReference = try await secretReference(
            in: source,
            walletID: identity.walletID
        )
        defer {
            try? vault.deleteIfPresent(reference: sourceReference)
        }
        try await source.pool.write { database in
            let accountID = try #require(
                try String.fetchOne(
                    database,
                    sql: """
                    SELECT id
                    FROM walletAccounts
                    WHERE walletID = ?
                    ORDER BY createdAt, networkID
                    LIMIT 1
                    """,
                    arguments: [identity.walletID]
                )
            )
            try database.execute(
                sql: """
                UPDATE walletAccounts
                SET address = ?,
                    normalizedAddress = ?,
                    publicKey = ?,
                    isEnabled = 0
                WHERE id = ?
                """,
                arguments: [
                    "0x2222222222222222222222222222222222222222",
                    "0x2222222222222222222222222222222222222222",
                    "04deadbeef",
                    accountID
                ]
            )
        }
        let prepared = try await preparedExport(
            from: source,
            vault: vault
        )
        defer {
            try? FileManager.default.removeItem(
                at: prepared.databaseURL.deletingLastPathComponent()
            )
        }

        try await expectRejectedWithoutPartialImport(
            incomingPackage(prepared),
            by: destination,
            vault: vault,
            expectedError: .invalidWalletSecret
        )
    }

    @Test
    func hardwareWatchOnlyAccountNeedsNoTransferredSecret()
        async throws
    {
        let source = try WalletDatabase.temporary()
        let destination = try WalletDatabase.temporary()
        try await insertHardwareWallet(
            into: source,
            accountIsWatchOnly: true
        )
        let prepared = try await preparedExport(
            from: source,
            vault: .shared
        )
        defer {
            try? FileManager.default.removeItem(
                at: prepared.databaseURL.deletingLastPathComponent()
            )
        }

        let result = try await destination.importDeviceMigration(
            incomingPackage(prepared),
            vault: .shared
        )

        #expect(result.walletCount == 1)
        #expect(prepared.secrets.walletSecrets.isEmpty)
        #expect(result.selectedWallet.walletID == Self.hardwareWalletID)
    }

    @Test
    func hardwareSoftwareAccountWithoutSecretIsRejectedAtomically()
        async throws
    {
        let source = try WalletDatabase.temporary()
        let destination = try WalletDatabase.temporary()
        try await insertHardwareWallet(
            into: source,
            accountIsWatchOnly: false
        )
        let prepared = try await preparedExport(
            from: source,
            vault: .shared
        )
        defer {
            try? FileManager.default.removeItem(
                at: prepared.databaseURL.deletingLastPathComponent()
            )
        }

        try await expectRejectedWithoutPartialImport(
            incomingPackage(prepared),
            by: destination,
            vault: .shared,
            expectedError: .invalidDatabase
        )
    }
}

private extension DeviceMigrationAccountSecretVerificationTests {
    struct DestinationState: Equatable {
        let walletCount: Int
        let accountCount: Int
        let walletReferenceCount: Int
        let appearance: String
        let languageIdentifier: String
    }

    static let firstPhrase = WalletCredentialTestFixtures.recoveryPhrase()
    static let secondPhrase = WalletCredentialTestFixtures.recoveryPhrase()
    static let hardwareWalletID = "migration-hardware-wallet"

    func verifyPrivateKeyVector(
        network: PrivateKeyImportNetwork,
        format: PrivateKeyImportFormat
    ) async throws {
        let source = try WalletDatabase.temporary()
        let destination = try WalletDatabase.temporary()
        let vault = WalletSecretVault.shared
        let key = WalletCredentialTestFixtures.privateKey()
        let draft = try PrivateKeyImportService.revalidate(
            privateKeyData: key,
            network: network,
            format: format
        )
        let identity = try await source.persistImportedWallet(
            draft: draft,
            security: .reuseExistingProfile,
            vault: vault
        )
        var references = [
            try await secretReference(
                in: source,
                walletID: identity.walletID
            )
        ]
        defer {
            for reference in references {
                try? vault.deleteIfPresent(reference: reference)
            }
        }
        let prepared = try await preparedExport(
            from: source,
            vault: vault
        )
        defer {
            try? FileManager.default.removeItem(
                at: prepared.databaseURL.deletingLastPathComponent()
            )
        }

        let result = try await destination.importDeviceMigration(
            incomingPackage(prepared),
            vault: vault
        )
        references.append(
            try await secretReference(
                in: destination,
                walletID: identity.walletID
            )
        )

        #expect(result.selectedWallet.walletID == identity.walletID)
        #expect(result.selectedWallet.address == draft.address)
    }

    func preparedExport(
        from source: WalletDatabase,
        vault: WalletSecretVault
    ) async throws -> DeviceMigrationPreparedExport {
        let authorization =
            try await source.authorizeUnprotectedDeviceMigration()
        return try await source.prepareDeviceMigrationExport(
            authorization: authorization,
            vault: vault
        )
    }

    func incomingPackage(
        _ prepared: DeviceMigrationPreparedExport
    ) -> DeviceMigrationIncomingPackage {
        DeviceMigrationIncomingPackage(
            databaseURL: prepared.databaseURL,
            manifest: prepared.manifest,
            secrets: prepared.secrets
        )
    }

    func packageReplacingOnlySecretData(
        _ prepared: DeviceMigrationPreparedExport,
        with data: Data
    ) throws -> DeviceMigrationIncomingPackage {
        let original = try #require(
            prepared.secrets.walletSecrets.only
        )
        let secrets = DeviceMigrationSecretsBundle(
            protocolVersion: prepared.secrets.protocolVersion,
            walletSecrets: [
                DeviceMigrationWalletSecret(
                    walletID: original.walletID,
                    kind: original.kind,
                    data: data
                )
            ]
        )
        return DeviceMigrationIncomingPackage(
            databaseURL: prepared.databaseURL,
            manifest: prepared.manifest,
            secrets: secrets
        )
    }

    func expectRejectedWithoutPartialImport(
        _ package: DeviceMigrationIncomingPackage,
        by destination: WalletDatabase,
        vault: WalletSecretVault,
        expectedError: DeviceMigrationError
    ) async throws {
        let before = try await destinationState(destination)

        do {
            _ = try await destination.importDeviceMigration(
                package,
                vault: vault
            )
            Issue.record("Expected migration verification to fail.")
        } catch let error as DeviceMigrationError {
            #expect(error == expectedError)
        } catch {
            Issue.record(
                "Unexpected migration error type: \(type(of: error))"
            )
        }

        let after = try await destinationState(destination)
        #expect(after == before)
        #expect(after.walletCount == 0)
        #expect(after.accountCount == 0)
        #expect(after.walletReferenceCount == 0)
    }

    func destinationState(
        _ database: WalletDatabase
    ) async throws -> DestinationState {
        try await database.pool.read { connection in
            let settings = try #require(
                try DBUserSettingsRecord.fetchOne(
                    connection,
                    key: WalletDatabase.defaultProfileID
                )
            )
            return DestinationState(
                walletCount:
                    try DBWalletRecord.fetchCount(connection),
                accountCount:
                    try DBWalletAccountRecord.fetchCount(connection),
                walletReferenceCount: try Int.fetchOne(
                    connection,
                    sql: """
                    SELECT COUNT(*)
                    FROM wallets
                    WHERE secretKeyReference IS NOT NULL
                    """
                ) ?? 0,
                appearance: settings.appearance,
                languageIdentifier: settings.languageIdentifier
            )
        }
    }

    func secretReference(
        in database: WalletDatabase,
        walletID: String
    ) async throws -> String {
        try await database.pool.read { connection in
            try #require(
                try DBWalletRecord.fetchOne(
                    connection,
                    key: walletID
                )?.secretKeyReference
            )
        }
    }

    func bitcoinHDKeyReferences(
        in database: WalletDatabase,
        walletID: String
    ) async throws -> [String] {
        try await database.pool.read { connection in
            try String.fetchAll(
                connection,
                sql: """
                SELECT keychainReference
                FROM bitcoinHDKeyCaches
                WHERE walletID = ?
                ORDER BY addressType, branch
                """,
                arguments: [walletID]
            )
        }
    }

    func insertHardwareWallet(
        into walletDatabase: WalletDatabase,
        accountIsWatchOnly: Bool
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await walletDatabase.pool.write { database in
            try DBWalletRecord(
                id: Self.hardwareWalletID,
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
                id: "migration-hardware-account",
                walletID: Self.hardwareWalletID,
                networkID: "eth",
                address:
                    "0x1111111111111111111111111111111111111111",
                normalizedAddress:
                    "0x1111111111111111111111111111111111111111",
                label: nil,
                derivationPath: nil,
                accountIndex: 0,
                publicKey: nil,
                isWatchOnly: accountIsWatchOnly,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(database)
        }
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
