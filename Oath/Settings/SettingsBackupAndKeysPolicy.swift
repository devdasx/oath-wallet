import Foundation

enum SettingsBackupMaterialChoice: String, Hashable, Sendable {
    case recoveryPhrase
    case privateKeys
}

enum SettingsBackupMethodChoice: String, CaseIterable, Hashable, Sendable {
    case manual
    case iCloud
}

enum SettingsBackupAndKeysPolicy {
    static func includes(_ kind: ManagedWalletKind) -> Bool {
        kind.hasExportableSecret
    }

    static func materialChoices(
        for kind: ManagedWalletKind
    ) -> [SettingsBackupMaterialChoice] {
        if kind.hasRecoveryPhrase {
            return [.recoveryPhrase, .privateKeys]
        }
        if kind == .importedPrivateKey {
            return [.privateKeys]
        }
        return []
    }

    static func methodChoices(
        for kind: ManagedWalletKind,
        material: SettingsBackupMaterialChoice
    ) -> [SettingsBackupMethodChoice] {
        guard material == .recoveryPhrase, kind.hasRecoveryPhrase else {
            return []
        }
        return SettingsBackupMethodChoice.allCases
    }
}
