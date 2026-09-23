import Foundation
import GRDB
import Security
import Testing
@testable import Aperture

struct WalletSetupPersistenceVisibilityTests {
    @Test
    func retiredDeveloperStorageCleanupRemovesPreparationLogs() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let cache = root.appendingPathComponent(
            "Caches",
            isDirectory: true
        )
        let preparationLogs = cache.appendingPathComponent(
            "WalletPreparationDiagnostics",
            isDirectory: true
        )
        let unrelated = cache.appendingPathComponent(
            "UnrelatedCache",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: preparationLogs,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: unrelated,
            withIntermediateDirectories: true
        )
        try Data("retired diagnostics".utf8).write(
            to: preparationLogs.appendingPathComponent(
                "wallet-preparation-events.log"
            )
        )

        let performanceExports = root.appendingPathComponent(
            "Aperture-Performance-Exports", isDirectory: true
        )
        try fileManager.createDirectory(
            at: performanceExports, withIntermediateDirectories: true
        )
        try Data("retired timing data".utf8).write(
            to: performanceExports.appendingPathComponent("performance.json")
        )
        let oldExport = root.appendingPathComponent("Aperture-Sync-Diagnostics-old.txt")
        let unrelatedExport = root.appendingPathComponent("wallet-backup.json")
        try Data("retired sync data".utf8).write(to: oldExport)
        let retainedData = Data("unrelated user export".utf8)
        try retainedData.write(to: unrelatedExport)

        WalletRetiredDeveloperStorageCleanup.removeArtifacts(
            using: fileManager,
            cacheDirectories: [cache],
            temporaryDirectory: root
        )

        #expect(!fileManager.fileExists(atPath: performanceExports.path))
        #expect(!fileManager.fileExists(atPath: oldExport.path))
        #expect(try Data(contentsOf: unrelatedExport) == retainedData)
        #expect(!fileManager.fileExists(atPath: preparationLogs.path))
        #expect(fileManager.fileExists(atPath: unrelated.path))
    }

    @Test
    func simulatorKeychainQueriesUseTheDefaultAppNamespace() {
        let query = WalletKeychainConfiguration.scopedQuery([
            kSecClass as String: kSecClassGenericPassword
        ])

#if targetEnvironment(simulator)
        #expect(query[kSecAttrAccessGroup as String] == nil)
#else
        #expect(
            query[kSecAttrAccessGroup as String] as? String
                == WalletKeychainConfiguration.accessGroup
        )
#endif
    }

    @Test
    func persistenceSupportEmailTargetsTheCareMailbox() throws {
        let failure = WalletPersistenceFailure(
            error: WalletSecretVaultError.unexpectedStatus(
                errSecMissingEntitlement
            )
        )
        let url = try #require(failure.supportURL)
        let components = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )

        #expect(components.scheme == "mailto")
        #expect(components.path == "care@aperturex.io")
        let body = components.queryItems?
            .first { $0.name == "body" }?
            .value
        #expect(
            body?.contains(failure.diagnosticCode) == true
        )
    }

    @Test
    func createdAndRestoredWalletsImmediatelyAppearInManagement()
        async throws
    {
        let database = try WalletDatabase.temporary()
        var secretReferences: [String] = []
        defer {
            for reference in secretReferences {
                try? WalletSecretVault.shared.deleteIfPresent(
                    reference: reference
                )
            }
        }

        let createdIdentity = try await database.persistCreatedWallet(
            draft: WalletCoreService.generateEVMWallet(),
            security: .reuseExistingProfile
        )
        secretReferences.append(
            try await secretReference(
                walletID: createdIdentity.walletID,
                database: database
            )
        )

        let importDraft = try WalletCoreService.importRecoveryPhrase(
            WalletCredentialTestFixtures.recoveryPhrase()
        )
        let restoredIdentity = try await database.persistImportedWallet(
            draft: importDraft,
            security: .reuseExistingProfile,
            preferredWalletName: "Restored Wallet"
        )
        secretReferences.append(
            try await secretReference(
                walletID: restoredIdentity.walletID,
                database: database
            )
        )

        let wallets = try await database.managedWallets()
        let selectedIdentity =
            try await database.selectedWalletIdentity()

        #expect(wallets.map(\.id) == [
            createdIdentity.walletID,
            restoredIdentity.walletID,
        ])
        #expect(
            wallets.first {
                $0.id == restoredIdentity.walletID
            }?.name == "Restored Wallet"
        )
        #expect(
            wallets.first {
                $0.id == restoredIdentity.walletID
            }?.isSelected == true
        )
        #expect(selectedIdentity == restoredIdentity)
    }

    @Test
    func privateKeyWalletNamesUseTheirChainAndIndependentSequence()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let imports: [PrivateKeyImportNetwork] = [
            .bitcoin,
            .evm,
            .bitcoin,
        ]
        var secretReferences: [String] = []
        defer {
            for reference in secretReferences {
                try? WalletSecretVault.shared.deleteIfPresent(
                    reference: reference
                )
            }
        }

        for network in imports {
            let draft = try PrivateKeyImportService.revalidate(
                privateKeyData: WalletCredentialTestFixtures.privateKey(),
                network: network,
                format: network == .bitcoin
                    ? .wifCompressed
                    : .rawSecp256k1
            )
            let identity = try await database.persistImportedWallet(
                draft: draft,
                security: .reuseExistingProfile
            )
            secretReferences.append(
                try await secretReference(
                    walletID: identity.walletID,
                    database: database
                )
            )
        }

        let names = try await database.managedWallets().map(\.name)
        #expect(names == [
            "Bitcoin Wallet",
            "Ethereum Wallet",
            "Bitcoin Wallet 2",
        ])
    }

    @Test
    func importedRecoveryPhraseWalletsUseImportedDefaultName()
        async throws
    {
        let englishName = WalletAppLanguage.localizedBundle(
            for: "en"
        ).localizedString(
            forKey: "wallet.name.imported",
            value: "",
            table: nil
        )

        #expect(englishName == "Imported Wallet")
        #expect(
            WalletDefaultName.baseName(
                for: .importedRecoveryPhrase
            ) == WalletLocalization.string("wallet.name.imported")
        )
    }

    @Test
    func legacyGeneratedRestoredNamesMigrateWithoutChangingCustomNames()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let now = Date().timeIntervalSince1970
        let legacyNames = [
            "Restored Wallet",
            "Restored Wallet 2",
            "My Restored Wallet",
        ]

        try await database.pool.write { database in
            for (index, name) in legacyNames.enumerated() {
                try DBWalletRecord(
                    id: "legacy-import-\(index)",
                    profileID: WalletDatabase.defaultProfileID,
                    name: name,
                    kind: DatabaseWalletKind
                        .importedRecoveryPhrase.rawValue,
                    secretKeyReference: nil,
                    isSelected: false,
                    sortOrder: index,
                    createdAt: now + Double(index),
                    updatedAt: now,
                    lastOpenedAt: nil,
                    archivedAt: nil
                ).insert(database)
            }

            try WalletDefaultName.migrateLegacyImportedNames(
                in: database
            )
        }

        let names = try await database.pool.read { database in
            try DBWalletRecord
                .order(Column("sortOrder"))
                .fetchAll(database)
                .map(\.name)
        }
        let importedName = WalletDefaultName.baseName(
            for: .importedRecoveryPhrase
        )

        #expect(names == [
            importedName,
            "\(importedName) 2",
            "My Restored Wallet",
        ])
    }

    private func secretReference(
        walletID: String,
        database: WalletDatabase
    ) async throws -> String {
        try await database.pool.read { database in
            guard
                let reference = try DBWalletRecord.fetchOne(
                    database,
                    key: walletID
                )?.secretKeyReference
            else {
                throw WalletManagementError.walletNotFound
            }
            return reference
        }
    }
}
