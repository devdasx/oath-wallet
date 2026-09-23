import Foundation
import GRDB
import Testing
import WalletCore
@testable import Aperture

struct BitcoinImportCollectionTests {
    private func data(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BitcoinImport/" + name))
    }

    @Test(arguments: ["descriptor-clear", "descriptor-encrypted", "legacy-clear", "legacy-encrypted"])
    func textExportsRestoreAllCoreAddressesAndHDChildren(name: String) async throws {
        let ext = name.hasPrefix("descriptor") ? ".json" : ".txt"
        let parsed = try await BitcoinImportFileParser.shared.parse(data(name + ext))
        let backup = try BitcoinCoreBackupImporter.parse(data(name + ".dat"), password: "CoreTestPassword")
        func addresses(_ material: BitcoinImportedWalletMaterial) throws -> Set<String> {
            var result = Set<String>()
            for (id, source) in material.sources.enumerated() {
                for branch in 0..<source.descriptor.branchCount {
                    for index in source.rangeStart..<(source.descriptor.isRanged ? 8 : 1) {
                        result.insert(try source.descriptor.address(branch: branch, index: index, sourceID: String(id)).address)
                    }
                }
            }
            return result
        }
        #expect(try addresses(backup).isSubset(of: addresses(parsed)))
        #expect(try await BitcoinImportFileParser.shared.parse(parsed.encoded()) == parsed)
    }

    @Test
    func coordinatedFileReadUsesTheSameValidatedBackupPath() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BitcoinImport/descriptor-encrypted.dat")
        await #expect(throws: BitcoinImportError.passwordRequired) { try await BitcoinImportFileParser.shared.read(url: url) }
        let draft = try await BitcoinImportFileParser.shared.read(url: url, password: "CoreTestPassword")
        #expect(draft == (try BitcoinCoreBackupImporter.parse(data("descriptor-encrypted.dat"), password: "CoreTestPassword").importDraft()))
    }

    @Test
    func fileFormatsAreAllOrNothing() async throws {
        let wif = try BitcoinImportKeyEncoding.encode(.init(key: Data(repeating: 0x12, count: 32), compressed: true))
        let fixtures = ["private_key,label\n\"\(wif)\",\"a,b\"", "[\"\(wif)\"]", "# header\n\(wif)\n"]
        for text in fixtures {
            let parsed = try await BitcoinImportFileParser.shared.parse(Data(text.utf8))
            #expect(parsed.sources.count == 4)
        }
        for text in [wif + "\ninvalid", "[\"\(wif)\",\"invalid\"]", "private_key,label\n\(wif),a\ninvalid,b", "{\"keys\":[]}"] {
            await #expect(throws: (any Error).self) { try await BitcoinImportFileParser.shared.parse(Data(text.utf8)) }
        }
        #expect(BitcoinImportFileParser.isCollectionInput(" wpkh(\(wif))"))
        #expect(BitcoinImportFileParser.isCollectionInput("{\"sources\":[]}"))
        #expect(!BitcoinImportFileParser.isCollectionInput(wif))
    }

    @Test
    func persistsCollectionReservesChangeAndRestoresBackupsWithoutLosingKeys() async throws {
        let material = try BitcoinCoreBackupImporter.parse(data("descriptor-clear.dat"))
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(service: "bitcoin-collection-test.\(UUID())")
        defer { try? vault.deleteAll() }
        let draft = try material.importDraft()
        let identity = try await database.persistImportedWallet(draft: draft, security: .reuseExistingProfile, vault: vault)
        #expect(try await database.bitcoinImportedMaterial(walletID: identity.walletID, vault: vault) == material)
        let addresses = try await database.bitcoinImportedAddresses(walletID: identity.walletID, material: material)
        #expect(addresses.count > 4)
        #expect(Set(addresses.map(\.scriptHash)).count == addresses.count)
        let first = try await database.bitcoinImportedReceiveAddress(walletID: identity.walletID, material: material, type: .bip84, reserveChange: true)
        let second = try await database.bitcoinImportedReceiveAddress(walletID: identity.walletID, material: material, type: .bip84, reserveChange: true)
        #expect(first.address != second.address && second.index == first.index + 1)
        #expect(try await database.bitcoinImportedWalletOwnsAddress(walletID: identity.walletID, address: second.address, vault: vault))
        let authorization = try await database.authorizeUnprotectedSecretExport(walletID: identity.walletID)
        let exports = try await database.privateKeyExportItems(walletID: identity.walletID, authorization: authorization, vault: vault)
        #expect(exports.count == 1)
        let export = try #require(exports.first)
        #expect(try await BitcoinImportFileParser.shared.parse(Data(try #require(export.privateKeys.first).value.utf8)) == material)
        let payload = WalletCloudBackupPayload(version: 2, walletName: "Core", walletKind: ManagedWalletKind.importedPrivateKey.rawValue,
            address: draft.address, secret: try material.encoded(), hasPassphrase: nil,
            privateKeyNetwork: "bitcoin", privateKeyFormat: BitcoinImportedWalletMaterial.accountMarker, createdAt: 0, backedUpAt: 0)
        #expect(try ICloudWalletRestoreValidator.validate(payload).draft == draft)
        try WalletDatabase.validateWalletSecret(material.encoded(), kind: .bitcoinImportedWallet)
        try DeviceMigrationAccountSecretVerifier.validate(source: database.pool,
            secrets: [.init(walletID: identity.walletID, kind: .bitcoinImportedWallet, data: try material.encoded())])
        let wallets = try await database.pool.read { try DBWalletRecord.fetchAll($0) }
        try WalletDatabase.validateSecretCoverage(wallets: wallets, muunRecoveryWalletIDs: [],
            bitcoinImportedWalletIDs: [identity.walletID],
            secrets: [.init(walletID: identity.walletID, kind: .bitcoinImportedWallet, data: try material.encoded())])
        // Database rows hold public identities only, never serialized secret material.
        let records = try await database.pool.read { database in
            try Data.fetchAll(database, sql: "SELECT publicAddress FROM bitcoinImportedAddresses")
        }
        for record in records {
            let text = String(decoding: record, as: UTF8.self)
            #expect(!text.contains("privateKey") && !text.contains("chainCode") && !text.contains("xprv"))
        }
    }

    @Test
    @MainActor
    func encryptedCloudDocumentRestoresTheWholeCollection() async throws {
        let material = try BitcoinCoreBackupImporter.parse(data("descriptor-clear.dat"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WalletAutomaticCloudBackupService(passkeyAuthorizer: ICloudBackupPasskeyAuthorizerProbe(),
            dataKeyStore: ICloudBackupDataKeyStoreProbe(), documentStore: WalletICloudDriveBackupStore(containerURLProvider: { root }))
        let address = try material.primaryAddress().address
        let wallet = ManagedWallet(id: UUID().uuidString, name: "Core backup", kind: .importedPrivateKey,
            address: address, fiatUSDBalance: 0, isSelected: true, notificationsEnabledWhenInactive: false,
            backupState: .notVerified, backupVerifiedAt: nil, iCloudBackupUpdatedAt: nil,
            mnemonicWordCount: nil, createdAt: Date())
        _ = try await service.backup(wallet: wallet, material: .bitcoinImportedWallet(material),
            privateKeyMetadata: WalletImportedPrivateKeyMetadata(network: .bitcoin, format: .wifCompressed, address: address))
        let payload = try await service.restore(walletID: wallet.id)
        #expect(try ICloudWalletRestoreValidator.validate(payload).draft == material.importDraft())
    }

    @Test
    func duplicateDetectionNeverDropsAdditionalBackupKeys() async throws {
        let material = try BitcoinCoreBackupImporter.parse(data("descriptor-clear.dat"))
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(service: "bitcoin-duplicate-test.\(UUID())")
        defer { try? vault.deleteAll() }
        let identity = try await database.persistImportedWallet(draft: material.importDraft(), security: .reuseExistingProfile, vault: vault)
        #expect(try await database.existingBitcoinImportedWallet(matching: material, vault: vault)?.id == identity.walletID)
        var expanded = material
        expanded.sources += try BitcoinImportedWalletMaterial.fixed(.init(key: Data(repeating: 0x34, count: 32), compressed: true))
        #expect(try expanded.primaryAddress() == material.primaryAddress())
        #expect(try await database.existingBitcoinImportedWallet(matching: expanded, vault: vault) == nil)
    }

    @Test
    func duplicateDetectionWorksAcrossBitcoinFamilyNetworks() async throws {
        let material = try BitcoinCoreBackupImporter.parse(data("descriptor-clear.dat"))
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(service: "bitcoin-network-scope-test.\(UUID())")
        defer { try? vault.deleteAll() }
        let identity = try await database.persistImportedWallet(
            draft: material.importDraft(),
            security: .reuseExistingProfile,
            vault: vault
        )
        let alternateNetwork = BitcoinFamilyChain.bitcoinCash.networkID
        try await database.pool.write { database in
            try database.execute(
                sql: "UPDATE walletAccounts SET networkID = ? WHERE walletID = ?",
                arguments: [alternateNetwork, identity.walletID]
            )
        }
        let existing = try await database.existingWallet(
            matching: material.importDraft(),
            vault: vault
        )
        #expect(existing?.id == identity.walletID)
        #expect((try await database.bitcoinImportedMaterial(
            walletID: identity.walletID,
            vault: vault
        )) != nil)
    }

    @Test
    func discoveryExtendsUsedGapAndDoesNotReallocateCompletedRanges() async throws {
        let parsed = try await BitcoinImportFileParser.shared.parse(data("descriptor-clear.json"))
        let source = try #require(parsed.sources.first)
        let material = try BitcoinImportedWalletMaterial(sources: [.init(descriptor: source.descriptor)]).validated()
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(service: "bitcoin-gap-test.\(UUID())")
        defer { try? vault.deleteAll() }
        let identity = try await database.persistImportedWallet(draft: material.importDraft(), security: .reuseExistingProfile, vault: vault)
        let initial = try await database.bitcoinImportedAddresses(walletID: identity.walletID, material: material)
        #expect(initial.count == 20)
        let boundary = try #require(initial.last)
        try await database.markBitcoinImportedUsage(walletID: identity.walletID, states: [BitcoinHDAddressState(derived: boundary,
            isUsed: true, isReserved: false, confirmedBalanceAtomic: .zero, unconfirmedBalanceAtomic: .zero)])
        let next = try await database.bitcoinImportedAddresses(walletID: identity.walletID, material: material, includesExisting: false)
        #expect(next.count == 20 && next.first?.index == 20 && next.last?.index == 39)
        #expect(try await database.bitcoinImportedAddresses(walletID: identity.walletID, material: material, includesExisting: false).isEmpty)
        #expect(try await database.bitcoinImportedAddressCount(walletID: identity.walletID) == 40)
    }
}
