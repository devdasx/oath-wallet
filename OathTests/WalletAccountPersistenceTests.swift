import Foundation
import GRDB
import Testing
@testable import Aperture

struct WalletAccountPersistenceTests {
    private static let phrase =
        WalletCredentialTestFixtures.recoveryPhrase()

    @Test
    func fullWalletDerivationCoversEverySupportedMainnet() throws {
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.phrase,
            passphrase: "account-persistence-test"
        )
        let evm = try WalletCoreService.importRecoveryPhrase(
            credential.mnemonic,
            passphrase: credential.passphrase
        )
        let accounts = try WalletAccountDerivationService.deriveFullWallet(
            credential: credential,
            expectedEVMAddress: evm.address,
            expectedEVMPublicKey: evm.publicKey
        )

        #expect(
            accounts.count
                == WalletAccountDerivationService.requiredAccountCount
        )
        #expect(
            Set(accounts.map(\.networkID))
                == WalletAccountDerivationService.requiredNetworkIDs
        )
        #expect(
            accounts.filter {
                $0.networkID == SolanaConstants.networkID
            }.count == SolanaDerivationKind.allCases.count
        )

        let evmAccounts = accounts.filter { account in
            ReceiveNetworkCatalog.network(for: account.networkID)?
                .blockchain.isEVM == true
        }
        #expect(!evmAccounts.isEmpty)
        #expect(Set(evmAccounts.map(\.normalizedAddress)).count == 1)
        #expect(
            evmAccounts.allSatisfy {
                $0.address.caseInsensitiveCompare(evm.address)
                    == .orderedSame
            }
        )

        let records = accounts.map {
            $0.record(walletID: "derivation-test", now: 1)
        }
        #expect(
            WalletAccountDerivationService.isStructurallyComplete(
                accounts: records
            )
        )
    }

    @Test
    func concurrentFullWalletMaterialMatchesCanonicalDerivation()
        async throws
    {
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.phrase,
            passphrase: "parallel-account-persistence-test"
        )
        let evm = try WalletCoreService.importRecoveryPhrase(
            credential.mnemonic,
            passphrase: credential.passphrase
        )
        let canonical = try WalletAccountDerivationService.deriveFullWallet(
            credential: credential,
            expectedEVMAddress: evm.address,
            expectedEVMPublicKey: evm.publicKey
        )
        let material = try await Task.detached(priority: .userInitiated) {
            try await WalletAccountDerivationService
                .deriveFullWalletMaterial(
                    credential: credential,
                    expectedEVMAddress: evm.address,
                    expectedEVMPublicKey: evm.publicKey
                )
        }.value

        #expect(material.accounts == canonical)
    }

    @Test
    func derivationVersionMigrationLeavesExistingWalletsForOneTimeRepair()
        throws
    {
        let queue = try DatabaseQueue()
        try WalletDatabase.migrator.migrate(
            queue,
            upTo: "v42_normalized_send_receive_asset_catalog"
        )
        try queue.write { database in
            try database.execute(
                sql: """
                INSERT INTO profiles (
                    id, displayName, createdAt, updatedAt, lastActiveAt
                ) VALUES (?, NULL, 1, 1, 1);

                INSERT INTO wallets (
                    id, profileID, name, kind, isSelected,
                    sortOrder, createdAt, updatedAt
                ) VALUES (
                    'legacy-wallet', ?, 'Legacy Wallet',
                    'importedRecoveryPhrase', 1, 0, 1, 1
                );
                """,
                arguments: [
                    WalletDatabase.defaultProfileID,
                    WalletDatabase.defaultProfileID
                ]
            )
        }

        try WalletDatabase.migrator.migrate(queue)

        let version = try queue.read { database in
            try Int.fetchOne(
                database,
                sql: """
                SELECT accountDerivationVersion
                FROM wallets
                WHERE id = 'legacy-wallet'
                """
            )
        }
        #expect(version == 0)
    }

    @Test
    func creationAndRecoveryImportPersistCompleteAccountSets()
        async throws
    {
        let database = try WalletDatabase.temporary()
        var references: [String] = []
        defer {
            for reference in references {
                try? WalletSecretVault.shared.deleteIfPresent(
                    reference: reference
                )
            }
        }

        let creationDraft = try WalletCoreService.generateEVMWallet(
            entropy: Data((0..<32).map(UInt8.init))
        )
        let created = try await database.persistCreatedWallet(
            draft: creationDraft,
            security: .reuseExistingProfile
        )
        references.append(
            try await secretReference(
                walletID: created.walletID,
                database: database
            )
        )
        try await assertCompleteAccountSet(
            walletID: created.walletID,
            evmAddress: creationDraft.address,
            database: database
        )
        #expect(
            try await accountDerivationVersion(
                walletID: created.walletID,
                database: database
            ) == WalletAccountDerivationService.currentPersistenceVersion
        )

        let importDraft = try WalletCoreService.importRecoveryPhrase(
            Self.phrase,
            passphrase: "imported-account-persistence-test"
        )
        let imported = try await database.persistImportedWallet(
            draft: importDraft,
            security: .reuseExistingProfile
        )
        references.append(
            try await secretReference(
                walletID: imported.walletID,
                database: database
            )
        )
        try await assertCompleteAccountSet(
            walletID: imported.walletID,
            evmAddress: importDraft.address,
            database: database
        )
        #expect(
            try await accountDerivationVersion(
                walletID: imported.walletID,
                database: database
            ) == WalletAccountDerivationService.currentPersistenceVersion
        )
    }

    @Test
    func completeWalletAccountCheckNeverReadsTheRecoveryPhraseAgain()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let draft = try WalletCoreService.importRecoveryPhrase(Self.phrase)
        let identity = try await database.persistImportedWallet(
            draft: draft,
            security: .reuseExistingProfile
        )
        let reference = try await secretReference(
            walletID: identity.walletID,
            database: database
        )
        defer {
            try? WalletSecretVault.shared.deleteIfPresent(
                reference: reference
            )
        }

        let emptyVault = WalletSecretVault(
            service: "com.aperture.tests.empty.\(UUID().uuidString)"
        )
        try await database.ensureFullWalletAccountsPersisted(
            walletID: identity.walletID,
            vault: emptyVault
        )
    }

    @Test
    func everyChainResolverUsesPersistedAccountsWithoutTheRecoveryPhrase()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let draft = try WalletCoreService.importRecoveryPhrase(Self.phrase)
        let identity = try await database.persistImportedWallet(
            draft: draft,
            security: .reuseExistingProfile
        )
        let reference = try await secretReference(
            walletID: identity.walletID,
            database: database
        )
        try WalletSecretVault.shared.deleteIfPresent(reference: reference)

        let before = try await accountRecords(
            walletID: identity.walletID,
            database: database
        )
        let emptyVault = WalletSecretVault(
            service: "com.aperture.tests.empty.\(UUID().uuidString)"
        )
        _ = try await database.ensureAptosAccount(
            walletID: identity.walletID,
            vault: emptyVault
        )
        _ = try await database.ensureBitcoinFamilyAccounts(
            walletID: identity.walletID
        )
        _ = try await database.ensureNEARAccount(walletID: identity.walletID)
        _ = try await database.ensureSolanaAccounts(
            walletID: identity.walletID
        )
        _ = try await database.ensureStellarAccount(
            walletID: identity.walletID
        )
        _ = try await database.ensureSuiAccount(walletID: identity.walletID)
        _ = try await database.ensureTONAccount(walletID: identity.walletID)
        _ = try await database.ensureTronAccount(walletID: identity.walletID)
        _ = try await database.ensureXRPAccount(walletID: identity.walletID)

        let after = try await accountRecords(
            walletID: identity.walletID,
            database: database
        )
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after.map(\.address) == before.map(\.address))
        #expect(after.map(\.updatedAt) == before.map(\.updatedAt))
    }

    @Test
    func legacyEVMOnlyWalletIsRepairedOnceThenUsesDatabaseOnly()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let draft = try WalletCoreService.importRecoveryPhrase(Self.phrase)
        let identity = try await database.persistImportedWallet(
            draft: draft,
            security: .reuseExistingProfile
        )
        let reference = try await secretReference(
            walletID: identity.walletID,
            database: database
        )
        defer {
            try? WalletSecretVault.shared.deleteIfPresent(
                reference: reference
            )
        }

        _ = try await database.pool.write { database in
            try DBWalletAccountRecord
                .filter(Column("walletID") == identity.walletID)
                .filter(Column("networkID") != "eth")
                .deleteAll(database)
            try database.execute(
                sql: """
                UPDATE wallets
                SET accountDerivationVersion = 0
                WHERE id = ?
                """,
                arguments: [identity.walletID]
            )
        }
        #expect(
            !(try await completeAccountSet(
                walletID: identity.walletID,
                database: database
            ))
        )

        try await database.ensureFullWalletAccountsPersisted(
            walletID: identity.walletID
        )
        #expect(
            try await completeAccountSet(
                walletID: identity.walletID,
                database: database
            )
        )
        #expect(
            try await accountDerivationVersion(
                walletID: identity.walletID,
                database: database
            ) == WalletAccountDerivationService.currentPersistenceVersion
        )

        let emptyVault = WalletSecretVault(
            service: "com.aperture.tests.empty.\(UUID().uuidString)"
        )
        try await database.ensureFullWalletAccountsPersisted(
            walletID: identity.walletID,
            vault: emptyVault
        )
    }

    @Test(arguments: BitcoinHDAddressType.allCases)
    func legacyRepairPreservesFundedBitcoinHDReceiveProjection(
        addressType: BitcoinHDAddressType
    )
        async throws
    {
        let database = try WalletDatabase.temporary()
        let passphrase = "bitcoin-projection-\(addressType.rawValue)"
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.phrase,
            passphrase: passphrase
        )
        let draft = try WalletCoreService.importRecoveryPhrase(
            Self.phrase,
            passphrase: passphrase
        )
        let identity = try await database.persistImportedWallet(
            draft: draft,
            security: .reuseExistingProfile
        )
        let reference = try await secretReference(
            walletID: identity.walletID,
            database: database
        )
        defer {
            try? WalletSecretVault.shared.deleteIfPresent(
                reference: reference
            )
        }

        _ = try await database.ensureBitcoinHDWallet(
            walletID: identity.walletID
        )
        _ = try await database.ensureBitcoinFamilyAccounts(
            walletID: identity.walletID
        )
        let wallet = try #require(credential.makeHDWallet())
        let derivation = BitcoinHDDerivationService()
        let descriptor = try #require(
            derivation.accountDescriptors(wallet: wallet).first {
                $0.addressType == addressType
            }
        )
        let projected = try derivation.deriveAddress(
            descriptor: descriptor,
            branch: .external,
            index: 1
        )
        let accountID = "\(identity.walletID):bitcoin:0"
        try await database.pool.write { rawDatabase in
            try rawDatabase.execute(
                sql: """
                UPDATE walletAccounts
                SET address = ?, normalizedAddress = ?, derivationPath = ?,
                    publicKey = ?, updatedAt = 2
                WHERE id = ?
                """,
                arguments: [
                    projected.address,
                    projected.address.lowercased(),
                    projected.derivationPath,
                    projected.publicKey.hexString,
                    accountID,
                ]
            )
            try rawDatabase.execute(
                sql: """
                UPDATE accountAssets
                SET balance = '0.00006281', balanceAtomic = '6281',
                    fiatUSDValue = '3.46', updatedAt = 2
                WHERE accountID = ? AND assetID = 'bitcoin:native'
                """,
                arguments: [accountID]
            )
            try rawDatabase.execute(
                sql: """
                UPDATE wallets
                SET accountDerivationVersion = 0
                WHERE id = ?
                """,
                arguments: [identity.walletID]
            )
        }

        let projectedState = try await database.pool.read { rawDatabase in
            (
                accounts: try DBWalletAccountRecord
                    .filter(Column("walletID") == identity.walletID)
                    .fetchAll(rawDatabase),
                addresses: try DBBitcoinHDAddressRecord
                    .filter(Column("walletID") == identity.walletID)
                    .filter(Column("address") == projected.address)
                    .fetchAll(rawDatabase)
            )
        }
        let canonicalBitcoin = try #require(
            WalletAccountDerivationService.deriveFullWallet(
                credential: credential
            ).first {
                $0.networkID == BitcoinFamilyChain.bitcoin.networkID
            }
        )
        let projectedAccount = try #require(
            projectedState.accounts.first {
                $0.networkID == BitcoinFamilyChain.bitcoin.networkID
            }
        )
        #expect(!canonicalBitcoin.matches(projectedAccount))
        #expect(
            BitcoinHDReceiveAccountProjection.matches(
                projectedAccount,
                addresses: projectedState.addresses
            )
        )
        #expect(
            WalletAccountDerivationService.isStructurallyComplete(
                accounts: projectedState.accounts,
                bitcoinHDAddresses: projectedState.addresses
            )
        )

        try await database.ensureFullWalletAccountsPersisted(
            walletID: identity.walletID
        )

        let persisted = try await database.pool.read { rawDatabase in
            (
                account: try DBWalletAccountRecord.fetchOne(
                    rawDatabase,
                    key: accountID
                ),
                holding: try DBAccountAssetRecord.fetchOne(
                    rawDatabase,
                    key: [
                        "accountID": accountID,
                        "assetID": "bitcoin:native",
                    ]
                )
            )
        }
        #expect(persisted.account?.address == projected.address)
        #expect(persisted.account?.derivationPath == projected.derivationPath)
        #expect(persisted.holding?.balanceAtomic == "6281")
        #expect(persisted.holding?.fiatUSDValue == "3.46")

        // Once repaired, a legitimate mutable Bitcoin Receive projection must
        // stay on the database-only fast path. Requiring the recovery secret
        // here would make the same destructive repair recur on every launch.
        let emptyVault = WalletSecretVault(
            service: "com.aperture.tests.empty.\(UUID().uuidString)"
        )
        try await database.ensureFullWalletAccountsPersisted(
            walletID: identity.walletID,
            vault: emptyVault
        )
        _ = try await database.ensureBitcoinFamilyAccounts(
            walletID: identity.walletID
        )
        #expect(
            try await database.bitcoinFamilyPersistedBalance(
                walletID: identity.walletID
            )?.decimalText == "6281"
        )
    }

    @Test
    func privateKeyImportPersistsOnlyItsCryptographicScope()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let draft = try PrivateKeyImportService.revalidate(
            privateKeyData: WalletCredentialTestFixtures.privateKey(),
            network: .bitcoin,
            format: .wifCompressed
        )
        let identity = try await database.persistImportedWallet(
            draft: draft,
            security: .reuseExistingProfile
        )
        let reference = try await secretReference(
            walletID: identity.walletID,
            database: database
        )
        defer {
            try? WalletSecretVault.shared.deleteIfPresent(
                reference: reference
            )
        }

        let accounts = try await accountRecords(
            walletID: identity.walletID,
            database: database
        )
        #expect(accounts.count == 1)
        #expect(accounts.first?.networkID == BitcoinFamilyChain.bitcoin.networkID)
        #expect(accounts.first?.address == draft.address)
    }

    @Test
    func remoteCatalogWalletActionPreparationUsesPersistedAccountsOnly()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let draft = try WalletCoreService.importRecoveryPhrase(Self.phrase)
        let identity = try await database.persistImportedWallet(
            draft: draft,
            security: .reuseExistingProfile
        )
        let reference = try await secretReference(
            walletID: identity.walletID,
            database: database
        )
        try WalletSecretVault.shared.deleteIfPresent(reference: reference)

        let accountAddresses = try await database.accountAddressIndex(
            walletID: identity.walletID
        )
        #expect(
            accountAddresses.accountCount
                == WalletAccountDerivationService.requiredAccountCount
        )
        #expect(
            accountAddresses.solanaAccounts?.all.count
                == SolanaDerivationKind.allCases.count
        )

        let eligibleSolanaTokenMints = Set([
            "So11111111111111111111111111111111111111112"
        ])
        // A fresh empty wallet has no catalog until sync completes. Supply
        // that snapshot explicitly while keeping the wallet secret unavailable.
        let previousCatalog = ReceiveAssetCatalogRuntime.snapshot
        defer {
            ReceiveAssetCatalogRuntime.install(previousCatalog.tokens, revision: previousCatalog.revision)
        }
        let catalog = try AssetNetworkSelectorOption.allSupported.map { option in
            let network = try #require(ReceiveNetworkCatalog.catalogNetwork(for: option.id))
            if let chain = BitcoinFamilyChain.allCases.first(where: { $0.networkID == option.id }) {
                return ReceiveToken(
                    id: "native-\(chain.networkID)", name: network.localizedName,
                    symbol: chain.symbol, rank: .min, isStablecoin: false,
                    variants: [ReceiveTokenVariant(networkID: chain.networkID,
                        contractAddress: nil, decimals: 8, networkRank: 0, logoURL: nil)]
                )
            }
            return ReceiveToken.nativeAsset(for: network)
        }
        ReceiveAssetCatalogRuntime.install(catalog)
        let preparation =
            await WalletActionPresentationPreparationBuilder.make(
                snapshot: .empty,
                capabilities: .fullWallet,
                walletAddress: identity.address,
                visibilityPreferencesJSON: "{}",
                accountAddresses: accountAddresses,
                eligibleSolanaTokenMints:
                    eligibleSolanaTokenMints
            )
        #expect(
            preparation.receive.eligibleSolanaTokenMints
                == eligibleSolanaTokenMints
        )
        #expect(
            preparation.send.eligibleSolanaTokenMints
                == eligibleSolanaTokenMints
        )

        let independentOptions =
            AssetNetworkSelectorOption.allSupported.filter {
                ReceiveAddressResolver.requiresIndependentAddress(
                    for: $0.blockchain
                )
            }
        for option in independentOptions {
            let nativeIdentity = AssetIdentityKey.make(
                networkID: option.id,
                contractAddress: nil
            )
            let receiveAsset = preparation.receive.walletAssets.first {
                AssetIdentityKey.canonical($0.id)
                    == AssetIdentityKey.canonical(nativeIdentity)
            }
            let sendAsset = preparation.send.walletAssets.first {
                AssetIdentityKey.canonical($0.id)
                    == AssetIdentityKey.canonical(nativeIdentity)
            }
            let expectedAddress = accountAddresses.address(
                for: option.blockchain
            )

            #expect(expectedAddress != nil)
            #expect(receiveAsset?.receiveAddress == expectedAddress)
            #expect(sendAsset?.receiveAddress == expectedAddress)
        }

        let resolutionPlan = ReceiveDirectAccountResolutionPlan(
            capabilities: .fullWallet,
            availableAssets:
                preparation.receive.baseDirectWalletAssets
        )
        #expect(!resolutionPlan.bitcoinFamily)
        #expect(!resolutionPlan.tron)
        #expect(!resolutionPlan.solana)
        #expect(!resolutionPlan.ton)
        #expect(!resolutionPlan.sui)
        #expect(!resolutionPlan.xrp)
        #expect(!resolutionPlan.near)
        #expect(!resolutionPlan.aptos)
        #expect(!resolutionPlan.stellar)
    }

    private func assertCompleteAccountSet(
        walletID: String,
        evmAddress: String,
        database: WalletDatabase
    ) async throws {
        let accounts = try await accountRecords(
            walletID: walletID,
            database: database
        )
        #expect(
            accounts.count
                == WalletAccountDerivationService.requiredAccountCount
        )
        #expect(
            WalletAccountDerivationService.isStructurallyComplete(
                accounts: accounts
            )
        )

        let evmNetworkIDs = Set(
            ReceiveNetworkCatalog.all
                .filter { $0.blockchain.isEVM }
                .map(\.id)
        )
        let evmAccounts = accounts.filter {
            evmNetworkIDs.contains($0.networkID)
        }
        #expect(evmAccounts.count == evmNetworkIDs.count)
        #expect(
            evmAccounts.allSatisfy {
                $0.address.caseInsensitiveCompare(evmAddress) == .orderedSame
            }
        )
        #expect(
            accounts.first {
                $0.networkID == AptosConstants.networkID
            }?.address.caseInsensitiveCompare(evmAddress) != .orderedSame
        )
    }

    private func completeAccountSet(
        walletID: String,
        database: WalletDatabase
    ) async throws -> Bool {
        WalletAccountDerivationService.isStructurallyComplete(
            accounts: try await accountRecords(
                walletID: walletID,
                database: database
            )
        )
    }

    private func accountRecords(
        walletID: String,
        database: WalletDatabase
    ) async throws -> [DBWalletAccountRecord] {
        try await database.pool.read { database in
            try DBWalletAccountRecord
                .filter(Column("walletID") == walletID)
                .order(Column("networkID"), Column("label"))
                .fetchAll(database)
        }
    }

    private func secretReference(
        walletID: String,
        database: WalletDatabase
    ) async throws -> String {
        try await database.pool.read { database in
            guard let reference = try DBWalletRecord.fetchOne(
                database,
                key: walletID
            )?.secretKeyReference else {
                throw WalletCreationPersistenceError.missingSecret
            }
            return reference
        }
    }

    private func accountDerivationVersion(
        walletID: String,
        database: WalletDatabase
    ) async throws -> Int {
        try await database.pool.read { database in
            guard let version = try DBWalletRecord.fetchOne(
                database,
                key: walletID
            )?.accountDerivationVersion else {
                throw WalletCreationPersistenceError.missingSecret
            }
            return version
        }
    }
}
