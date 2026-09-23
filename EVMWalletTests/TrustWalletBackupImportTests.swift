import Foundation
import GRDB
import Testing
import UniformTypeIdentifiers
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct TrustWalletBackupImportTests {
    private static let mnemonic =
        WalletCredentialTestFixtures.recoveryPhrase()
    private static let password = "Trust Wallet fixture password"

    @Test
    func documentPickerSelectsBackupFilesAndStartsInTrustFolder() {
        let identifiers = Set(
            TrustWalletBackupDocumentPickerPolicy
                .allowedContentTypes
                .map(\.identifier)
        )

        #expect(identifiers.contains(UTType.json.identifier))
        #expect(identifiers.contains(UTType.data.identifier))
        #expect(!identifiers.contains(UTType.folder.identifier))
        #expect(
            TrustWalletBackupDocumentPickerPolicy.preferredDirectoryURL
                .path.hasSuffix(
                    "Mobile Documents/"
                        + "iCloud~com~sixdays~trust/Documents"
                )
        )
    }

    @Test
    func documentPickerExplainsTheExpectedExportInEveryLocale() throws {
        let actionKey = TrustWalletBackupDocumentPickerPolicy
            .selectionActionLocalizationKey
        let detailKey = TrustWalletBackupDocumentPickerPolicy
            .selectionDetailLocalizationKey
        let english = WalletAppLanguage.localizedBundle(for: "en")

        #expect(
            english.localizedString(
                forKey: actionKey,
                value: nil,
                table: nil
            ) == "Choose a Trust Wallet Backup"
        )
        #expect(
            english.localizedString(
                forKey: detailKey,
                value: nil,
                table: nil
            ) == "Select the encrypted JSON file exported by Trust Wallet."
        )

        for language in Bundle.main.localizations where language != "Base" {
            let path = try #require(
                Bundle.main.path(forResource: language, ofType: "lproj")
            )
            let bundle = try #require(Bundle(path: path))
            let action = bundle.localizedString(
                forKey: actionKey,
                value: "MISSING",
                table: nil
            )
            let detail = bundle.localizedString(
                forKey: detailKey,
                value: "MISSING",
                table: nil
            )

            #expect(action != "MISSING", "Missing action in \(language)")
            #expect(detail != "MISSING", "Missing detail in \(language)")
            #expect(action.contains("Trust Wallet"))
            #expect(detail.contains("Trust Wallet"))
            #expect(detail.localizedCaseInsensitiveContains("JSON"))
        }
    }

    @Test
    func mnemonicBackupRestoresAndPersistsTheOriginalWallet() async throws {
        let backup = try mnemonicBackup()
        #expect(backup.kind == .recoveryPhrase)
        #expect(backup.walletName == "Trust Fixture")

        let restored = try TrustWalletBackupImporter.restoreSynchronously(
            backup,
            password: Self.password
        )
        let expected = try WalletCoreService.importRecoveryPhrase(
            Self.mnemonic
        )
        #expect(restored.draft == expected)
        #expect(restored.walletName == "Trust Fixture")

        let database = try WalletDatabase.temporary()
        let identity = try await database.persistImportedWallet(
            draft: restored.draft,
            security: .reuseExistingProfile,
            preferredWalletName: restored.walletName
        )
        let record = try await database.pool.read { database in
            let fetched = try DBWalletRecord.fetchOne(
                database,
                key: identity.walletID
            )
            return try #require(fetched)
        }
        let secretReference = try #require(record.secretKeyReference)
        defer {
            try? WalletSecretVault.shared.deleteIfPresent(
                reference: secretReference
            )
        }

        #expect(record.name == "Trust Fixture")
        #expect(
            record.kind
                == DatabaseWalletKind.importedRecoveryPhrase.rawValue
        )
    }

    @Test
    func wrongPasswordReturnsTheSpecificPasswordError() throws {
        let backup = try mnemonicBackup()
        do {
            _ = try TrustWalletBackupImporter.restoreSynchronously(
                backup,
                password: "wrong password"
            )
            Issue.record("The encrypted backup accepted a wrong password")
        } catch {
            #expect(
                error as? TrustWalletBackupImportError
                    == .invalidPassword
            )
        }
    }

    @Test
    func folderDiscoveryFindsOnlyValidStoredKeyBackups() throws {
        let backup = try mnemonicBackup()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = folder.appendingPathComponent(
            "Trust",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let olderURL = nested.appendingPathComponent("Older Wallet.json")
        let newerURL = nested.appendingPathComponent("Newer Wallet.json")
        try backup.encryptedJSON.write(
            to: olderURL,
            options: .atomic
        )
        try backup.encryptedJSON.write(to: newerURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: olderURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newerURL.path
        )
        try Data("{\"not\":\"a stored key\"}".utf8).write(
            to: nested.appendingPathComponent("Other.json"),
            options: .atomic
        )
        try Data("ignored".utf8).write(
            to: nested.appendingPathComponent("Notes.txt"),
            options: .atomic
        )

        let discovered = try TrustWalletBackupSelectionReader
            .discoverSynchronously(at: folder)
        #expect(discovered.count == 2)
        #expect(discovered.map(\.fileName) == [
            "Newer Wallet.json",
            "Older Wallet.json",
        ])
        #expect(discovered[0].kind == .recoveryPhrase)
    }

    @Test
    func individualJSONBackupSelectionLoadsTheSelectedWallet() async throws {
        let backup = try mnemonicBackup()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(UUID().uuidString).json",
                isDirectory: false
            )
        try backup.encryptedJSON.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let selected = try await TrustWalletBackupSelectionReader
            .selectedBackup(at: fileURL)

        #expect(selected.walletName == backup.walletName)
        #expect(selected.kind == backup.kind)
        #expect(selected.encryptedJSON == backup.encryptedJSON)
    }

    @Test
    func rawPrivateKeyBackupRestoresTheMatchingAccount() throws {
        let keyData = Data(repeating: 7, count: 32)
        let passwordData = Data(Self.password.utf8)
        let storedKey = try #require(
            StoredKey.importPrivateKeyWithEncryption(
                privateKey: keyData,
                name: "Trust Private Key",
                password: passwordData,
                coin: .ethereum,
                encryption: .aes128Ctr
            )
        )
        let json = try #require(storedKey.exportJSON())
        let backup = try TrustWalletBackupParser.parse(
            json: json,
            fileName: "Private Key.json"
        )

        let restored = try TrustWalletBackupImporter.restoreSynchronously(
            backup,
            password: Self.password
        )
        let expected = try PrivateKeyImportService.revalidate(
            privateKeyData: keyData,
            network: .evm,
            format: .rawSecp256k1
        )

        #expect(backup.kind == .privateKey)
        #expect(restored.draft == expected)
        #expect(restored.walletName == "Trust Private Key")
    }

    @Test
    func encodedPrivateKeyBackupUsesWalletCoreEncodedDecryption() throws {
        let encodedKey = String(repeating: "08", count: 32)
        let storedKey = try #require(
            StoredKey.importPrivateKeyEncodedWithEncryption(
                privateKey: encodedKey,
                name: "Trust Encoded Key",
                password: Data(Self.password.utf8),
                coin: .ethereum,
                encryption: .aes128Ctr
            )
        )
        #expect(storedKey.hasPrivateKeyEncoded)
        let backup = try TrustWalletBackupParser.parse(
            json: try #require(storedKey.exportJSON()),
            fileName: "Encoded Key.json"
        )

        let restored = try TrustWalletBackupImporter.restoreSynchronously(
            backup,
            password: Self.password
        )
        let expected = try PrivateKeyImportService.importKey(
            encodedKey,
            network: .evm
        )
        #expect(restored.draft == expected)
    }

    @Test
    func malformedAndOversizedFilesAreRejected() {
        #expect(throws: TrustWalletBackupImportError.invalidBackup) {
            _ = try TrustWalletBackupParser.parse(
                json: Data("{}".utf8),
                fileName: "Invalid.json"
            )
        }
        #expect(throws: TrustWalletBackupImportError.invalidBackup) {
            _ = try TrustWalletBackupParser.parse(
                json: Data(
                    repeating: 0,
                    count: TrustWalletBackupParser.maximumBackupBytes + 1
                ),
                fileName: "Oversized.json"
            )
        }
    }

    private func mnemonicBackup() throws -> TrustWalletBackupDescriptor {
        let storedKey = try #require(
            StoredKey.importHDWalletWithEncryption(
                mnemonic: Self.mnemonic,
                name: "Trust Fixture",
                password: Data(Self.password.utf8),
                coin: .ethereum,
                encryption: .aes128Ctr
            )
        )
        return try TrustWalletBackupParser.parse(
            json: try #require(storedKey.exportJSON()),
            fileName: "Trust Fixture.json"
        )
    }
}
