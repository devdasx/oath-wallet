import Foundation

enum WalletSwitcherSetupRoute: Hashable, Sendable {
    case recovery
    case creationPassphrase
    case wordList(BIP39Language)
    case importOptions
    case importRecoveryPhrase
    case privateKeyNetworks
    case privateKeyCredential(PrivateKeyImportNetwork)
    case muunRecoveryMethods
    case muunEmergencyKit
    case muunEncryptedKeys
    case trustWalletPassword
    case physicalEntropy
    case restoreICloud
    case restoreBackup(WalletCloudBackupDescriptor)
    case duplicateImport
    case success

    static func entry(for action: HomeWalletAddAction) -> Self {
        switch action {
        case .create: .recovery
        case .importWallet: .importOptions
        case .restoreICloud: .restoreICloud
        }
    }
}

enum WalletSwitcherImportPreparation: Equatable, Sendable {
    case readyToPersist
    case duplicateImport

    var destination: WalletSwitcherSetupRoute {
        switch self {
        case .readyToPersist: .success
        case .duplicateImport: .duplicateImport
        }
    }
}
