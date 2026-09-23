import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WalletCore

enum TrustWalletBackupDocumentPickerPolicy {
    static let selectionActionLocalizationKey =
        "trust_wallet.restore.file.action"
    static let selectionDetailLocalizationKey =
        "trust_wallet.restore.file.detail"

    static let allowedContentTypes: [UTType] = [
        .json,
        // Some Trust Wallet exports are surfaced by Files as generic data
        // even though their filename and payload are JSON. The parser remains
        // the authority and rejects every non-Trust-Wallet backup.
        .data,
    ]

    /// Trust Wallet's user-visible Files location is backed by this iCloud
    /// container. `UIDocumentPickerViewController` treats this as a preferred
    /// starting location and safely falls back to its last location when the
    /// container is unavailable on the device.
    static let preferredDirectoryURL = URL(
        fileURLWithPath: """
            /private/var/mobile/Library/Mobile Documents/\
            iCloud~com~sixdays~trust/Documents
            """
            .replacingOccurrences(of: "\n", with: ""),
        isDirectory: true
    )
}

/// A small shared picker primitive. The onboarding and wallet-switcher flows
/// own their selection state and navigation independently.
struct TrustWalletBackupDocumentPicker: UIViewControllerRepresentable {
    let onSelect: @MainActor (URL) -> Void
    let onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onCancel: onCancel)
    }

    func makeUIViewController(
        context: Context
    ) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes:
                TrustWalletBackupDocumentPickerPolicy.allowedContentTypes,
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.directoryURL =
            TrustWalletBackupDocumentPickerPolicy.preferredDirectoryURL
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onSelect: @MainActor (URL) -> Void
        private let onCancel: @MainActor () -> Void

        init(
            onSelect: @escaping @MainActor (URL) -> Void,
            onCancel: @escaping @MainActor () -> Void
        ) {
            self.onSelect = onSelect
            self.onCancel = onCancel
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard urls.count == 1, let selectedURL = urls.first else {
                onCancel()
                return
            }
            onSelect(selectedURL)
        }

        func documentPickerWasCancelled(
            _ controller: UIDocumentPickerViewController
        ) {
            onCancel()
        }
    }
}

struct TrustWalletBackupDescriptor: Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        case recoveryPhrase
        case privateKey

        var titleKey: String {
            switch self {
            case .recoveryPhrase:
                "import.recovery.title"
            case .privateKey:
                "import.private_key.title"
            }
        }
    }

    let id: String
    let walletName: String?
    let fileName: String
    let modifiedAt: Date?
    let kind: Kind
    let encryptedJSON: Data

    var displayName: String? {
        walletName ?? TrustWalletBackupParser.safeLabel(
            URL(fileURLWithPath: fileName)
                .deletingPathExtension()
                .lastPathComponent,
            maximumLength: WalletDefaultName.maximumLength
        )
    }
}

struct TrustWalletBackupRestoreResult: Sendable {
    let draft: WalletImportDraft
    let walletName: String?
}

enum TrustWalletBackupImportError: Error, Equatable, Sendable {
    case folderUnavailable
    case folderTooLarge
    case noBackups
    case invalidBackup
    case invalidPassword
    case unsupportedBackup
    case invalidRecoveredWallet
}

enum TrustWalletBackupParser {
    static let maximumBackupBytes = 5 * 1_024 * 1_024

    static func parse(
        json: Data,
        fileName: String,
        modifiedAt: Date? = nil,
        identity: String? = nil
    ) throws -> TrustWalletBackupDescriptor {
        guard !json.isEmpty,
              json.count <= maximumBackupBytes,
              let storedKey = StoredKey.importJSON(json: json)
        else {
            throw TrustWalletBackupImportError.invalidBackup
        }

        let name = safeLabel(
            storedKey.name,
            maximumLength: WalletDefaultName.maximumLength
        )
        let safeFileName = safeLabel(fileName, maximumLength: 180)
            ?? "\(storedKey.identifier ?? UUID().uuidString).json"
        let kind: TrustWalletBackupDescriptor.Kind = storedKey.isMnemonic
            ? .recoveryPhrase : .privateKey
        guard storedKey.isMnemonic || storedKey.accountCount > 0 else {
            throw TrustWalletBackupImportError.unsupportedBackup
        }

        return TrustWalletBackupDescriptor(
            id: [
                storedKey.identifier ?? "stored-key",
                identity ?? safeFileName,
            ].joined(separator: ":"),
            walletName: name,
            fileName: safeFileName,
            modifiedAt: modifiedAt,
            kind: kind,
            encryptedJSON: json
        )
    }

    static func safeLabel(
        _ value: String,
        maximumLength: Int
    ) -> String? {
        let filtered = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let normalized = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maximumLength))
    }
}

enum TrustWalletBackupFolderReader {
    private static let maximumVisitedItems = 500
    private static let maximumBackups = 100

    fileprivate static func discoverCoordinatedFolder(
        _ folderURL: URL
    ) throws -> [TrustWalletBackupDescriptor] {
        let folderValues = try folderURL.resourceValues(
            forKeys: [.isDirectoryKey]
        )
        guard folderValues.isDirectory == true else {
            throw TrustWalletBackupImportError.folderUnavailable
        }

        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw TrustWalletBackupImportError.folderUnavailable
        }

        var visited = 0
        var hadUnreadableJSON = false
        var backups: [TrustWalletBackupDescriptor] = []
        while let candidate = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            visited += 1
            guard visited <= maximumVisitedItems else {
                throw TrustWalletBackupImportError.folderTooLarge
            }
            guard candidate.pathExtension.caseInsensitiveCompare("json")
                    == .orderedSame else {
                continue
            }
            let values: URLResourceValues
            let data: Data
            do {
                values = try candidate.resourceValues(
                    forKeys: Set(resourceKeys)
                )
                guard values.isRegularFile == true,
                      values.fileSize.map({
                          $0 <= TrustWalletBackupParser.maximumBackupBytes
                      }) ?? true
                else {
                    continue
                }
                data = try boundedJSON(at: candidate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                hadUnreadableJSON = true
                continue
            }
            let relativePath = String(
                candidate.path.dropFirst(folderURL.path.count)
            )
            guard let backup = try? TrustWalletBackupParser.parse(
                json: data,
                fileName: candidate.lastPathComponent,
                modifiedAt: values.contentModificationDate,
                identity: relativePath
            ) else {
                continue
            }
            backups.append(backup)
            guard backups.count <= maximumBackups else {
                throw TrustWalletBackupImportError.folderTooLarge
            }
        }

        guard !backups.isEmpty else {
            if hadUnreadableJSON {
                throw TrustWalletBackupImportError.folderUnavailable
            }
            throw TrustWalletBackupImportError.noBackups
        }
        return backups.sorted {
            switch ($0.modifiedAt, $1.modifiedAt) {
            case let (left?, right?) where left != right:
                left > right
            default:
                $0.fileName.localizedStandardCompare($1.fileName)
                    == .orderedAscending
            }
        }
    }

    fileprivate static func boundedJSON(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let maximum = TrustWalletBackupParser.maximumBackupBytes
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximum else {
            throw TrustWalletBackupImportError.invalidBackup
        }
        return data
    }
}

enum TrustWalletBackupSelectionReader {
    static func selectedBackup(
        at selectedURL: URL
    ) async throws -> TrustWalletBackupDescriptor {
        let backups = try await discover(at: selectedURL)
        guard backups.count == 1, let backup = backups.first else {
            throw TrustWalletBackupImportError.invalidBackup
        }
        return backup
    }

    static func discover(
        at selectedURL: URL
    ) async throws -> [TrustWalletBackupDescriptor] {
        try await Task.detached(priority: .userInitiated) {
            try discoverSynchronously(at: selectedURL)
        }.value
    }

    static func discoverSynchronously(
        at selectedURL: URL
    ) throws -> [TrustWalletBackupDescriptor] {
        let didAccess = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<[TrustWalletBackupDescriptor], Error>?
        coordinator.coordinate(
            readingItemAt: selectedURL,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            result = Result {
                try discoverCoordinatedSelection(at: coordinatedURL)
            }
        }
        if coordinationError != nil {
            throw TrustWalletBackupImportError.folderUnavailable
        }
        guard let result else {
            throw TrustWalletBackupImportError.folderUnavailable
        }
        do {
            return try result.get()
        } catch let error as TrustWalletBackupImportError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TrustWalletBackupImportError.folderUnavailable
        }
    }

    private static func discoverCoordinatedSelection(
        at selectedURL: URL
    ) throws -> [TrustWalletBackupDescriptor] {
        try Task.checkCancellation()
        let values = try selectedURL.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ]
        )
        if values.isDirectory == true {
            return try TrustWalletBackupFolderReader
                .discoverCoordinatedFolder(selectedURL)
        }
        guard values.isRegularFile == true,
              selectedURL.pathExtension.caseInsensitiveCompare("json")
                == .orderedSame,
              values.fileSize.map({
                  $0 <= TrustWalletBackupParser.maximumBackupBytes
              }) ?? true else {
            throw TrustWalletBackupImportError.invalidBackup
        }
        let json = try TrustWalletBackupFolderReader
            .boundedJSON(at: selectedURL)
        return [
            try TrustWalletBackupParser.parse(
                json: json,
                fileName: selectedURL.lastPathComponent,
                modifiedAt: values.contentModificationDate,
                identity: selectedURL.lastPathComponent
            )
        ]
    }
}

enum TrustWalletBackupImporter {
    static func restore(
        _ backup: TrustWalletBackupDescriptor,
        password: String
    ) async throws -> TrustWalletBackupRestoreResult {
        try await Task.detached(priority: .userInitiated) {
            try restoreSynchronously(backup, password: password)
        }.value
    }

    static func restoreSynchronously(
        _ backup: TrustWalletBackupDescriptor,
        password: String
    ) throws -> TrustWalletBackupRestoreResult {
        guard let storedKey = StoredKey.importJSON(
            json: backup.encryptedJSON
        ) else {
            throw TrustWalletBackupImportError.invalidBackup
        }

        var passwordData = Data(password.utf8)
        defer {
            passwordData.resetBytes(in: 0..<passwordData.count)
        }
        let draft: WalletImportDraft
        if storedKey.isMnemonic {
            var decrypted = try decryptedPrivateKey(
                storedKey,
                password: passwordData
            )
            defer { decrypted.resetBytes(in: 0..<decrypted.count) }
            guard let mnemonic = String(
                data: decrypted,
                encoding: .ascii
            ), Mnemonic.isValid(mnemonic: mnemonic) else {
                throw TrustWalletBackupImportError.invalidRecoveredWallet
            }
            do {
                draft = try WalletCoreService.importRecoveryPhrase(mnemonic)
            } catch {
                throw TrustWalletBackupImportError.invalidRecoveredWallet
            }
            try validateMnemonicAccount(storedKey, draft: draft)
        } else if storedKey.hasPrivateKeyEncoded {
            guard let encoded = storedKey.decryptPrivateKeyEncoded(
                password: passwordData
            ) else {
                throw TrustWalletBackupImportError.invalidPassword
            }
            draft = try privateKeyDraft(
                encoded,
                storedKey: storedKey
            )
        } else {
            var decrypted = try decryptedPrivateKey(
                storedKey,
                password: passwordData
            )
            defer { decrypted.resetBytes(in: 0..<decrypted.count) }
            draft = try privateKeyDraft(
                decrypted,
                storedKey: storedKey
            )
        }

        let preferredName = backup.walletName.flatMap(
            WalletDefaultName.normalizedCustomName
        )
        return TrustWalletBackupRestoreResult(
            draft: draft,
            walletName: preferredName
        )
    }

    private static func decryptedPrivateKey(
        _ storedKey: StoredKey,
        password: Data
    ) throws -> Data {
        guard let decrypted = storedKey.decryptPrivateKey(
            password: password
        ) else {
            throw TrustWalletBackupImportError.invalidPassword
        }
        return decrypted
    }

    private static func validateMnemonicAccount(
        _ storedKey: StoredKey,
        draft: WalletImportDraft
    ) throws {
        let expectedEVMAddress = (0..<storedKey.accountCount)
            .compactMap { storedKey.account(index: $0) }
            .first { isSupportedEVM($0.coin) }?
            .address
        guard expectedEVMAddress.map({
            $0.caseInsensitiveCompare(draft.address) == .orderedSame
        }) ?? true else {
            throw TrustWalletBackupImportError.invalidRecoveredWallet
        }
    }

    private static func privateKeyDraft(
        _ keyData: Data,
        storedKey: StoredKey
    ) throws -> WalletImportDraft {
        var foundSupportedAccount = false
        for index in 0..<storedKey.accountCount {
            guard let account = storedKey.account(index: index),
                  let network = network(for: account.coin)
            else {
                continue
            }
            foundSupportedAccount = true
            for format in candidateFormats(for: network) {
                guard let draft = try? PrivateKeyImportService.revalidate(
                    privateKeyData: keyData,
                    network: network,
                    format: format
                ) else {
                    continue
                }
                if addressesMatch(
                    draft: draft,
                    expected: account.address,
                    network: network,
                    keyData: keyData,
                    format: format
                ) {
                    return draft
                }
            }
        }
        guard foundSupportedAccount else {
            throw TrustWalletBackupImportError.unsupportedBackup
        }
        throw TrustWalletBackupImportError.invalidRecoveredWallet
    }

    private static func privateKeyDraft(
        _ encodedKey: String,
        storedKey: StoredKey
    ) throws -> WalletImportDraft {
        var foundSupportedAccount = false
        for index in 0..<storedKey.accountCount {
            guard let account = storedKey.account(index: index),
                  let network = network(for: account.coin)
            else {
                continue
            }
            foundSupportedAccount = true
            guard let draft = try? PrivateKeyImportService.importKey(
                encodedKey,
                network: network
            ) else {
                continue
            }
            let matches = network == .evm
                ? draft.address.caseInsensitiveCompare(account.address)
                    == .orderedSame
                : draft.address == account.address
            if matches {
                return draft
            }
        }
        guard foundSupportedAccount else {
            throw TrustWalletBackupImportError.unsupportedBackup
        }
        throw TrustWalletBackupImportError.invalidRecoveredWallet
    }

    private static func addressesMatch(
        draft: WalletImportDraft,
        expected: String,
        network: PrivateKeyImportNetwork,
        keyData: Data,
        format: PrivateKeyImportFormat
    ) -> Bool {
        if network == .evm {
            return draft.address.caseInsensitiveCompare(expected)
                == .orderedSame
        }
        if network == .bitcoin,
           format == .wifCompressed,
           let addresses = try? BitcoinHDDerivationService()
            .singleKeyAddresses(
                privateKeyData: keyData,
                format: format
            ) {
            return addresses.contains { $0.address == expected }
        }
        return draft.address == expected
    }

    private static func candidateFormats(
        for network: PrivateKeyImportNetwork
    ) -> [PrivateKeyImportFormat] {
        switch network {
        case .bitcoin, .litecoin, .dogecoin, .bitcoinCash:
            [.wifCompressed, .wifUncompressed]
        case .solana:
            [.solanaSeed]
        case .aptos, .stellar, .ton, .sui, .near:
            [.rawEd25519]
        case .evm, .tron, .xrp:
            [.rawSecp256k1]
        }
    }

    private static func network(
        for coin: CoinType
    ) -> PrivateKeyImportNetwork? {
        switch coin {
        case .aptos: .aptos
        case .stellar: .stellar
        case .near: .near
        case .xrp: .xrp
        case .sui: .sui
        case .ton: .ton
        case .tron: .tron
        case .solana: .solana
        case .bitcoin: .bitcoin
        case .bitcoinCash: .bitcoinCash
        case .litecoin: .litecoin
        case .dogecoin: .dogecoin
        case let coin where isSupportedEVM(coin): .evm
        default: nil
        }
    }

    private static func isSupportedEVM(_ coin: CoinType) -> Bool {
        switch coin {
        case .ethereum,
             .smartChain,
             .smartChainLegacy,
             .polygon,
             .arbitrum,
             .avalancheCChain,
             .optimism,
             .base,
             .xdai,
             .scroll,
             .linea:
            true
        default:
            false
        }
    }
}

enum TrustWalletBackupImportPresentation {
    static func folderErrorKey(for error: Error) -> String {
        guard let error = error as? TrustWalletBackupImportError else {
            return "import.icloud.load.error"
        }
        return switch error {
        case .noBackups:
            "import.icloud.empty.title"
        case .folderUnavailable,
             .folderTooLarge,
             .invalidBackup,
             .invalidPassword,
             .unsupportedBackup,
             .invalidRecoveredWallet:
            "import.icloud.load.error"
        }
    }

    static func restoreErrorKey(for error: Error) -> String {
        guard let error = error as? TrustWalletBackupImportError else {
            return "import.icloud.restore.error"
        }
        return switch error {
        case .invalidPassword:
            "import.icloud.password.error"
        case .folderUnavailable,
             .folderTooLarge,
             .noBackups,
             .invalidBackup,
             .unsupportedBackup,
             .invalidRecoveredWallet:
            "import.icloud.restore.error"
        }
    }
}
