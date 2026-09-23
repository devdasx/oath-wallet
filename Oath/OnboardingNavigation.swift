import SwiftUI

struct PendingWalletImportEligibility: Sendable {
    let draft: WalletImportDraft
    let walletName: String?
    let cloudBackupIdentity: WalletCloudBackupRemoteIdentity?
}

enum OnboardingWalletPreparation: Sendable {
    case creation
    case imported
}

enum WalletRoute: String, Identifiable {
    case create
    case existing

    var id: String { rawValue }
}

enum OnboardingStartAction: String, Sendable {
    case createWallet
    case physicalEntropy
    case importWallet
    case restoreICloud
}

enum OnboardingDestination: Hashable {
    case creationPasscode
    case creationFailure(WalletPersistenceFailure)
    case physicalEntropy(OnboardingPhysicalEntropyDestination)
    case importPasscode
    case importFailure(WalletPersistenceFailure)
    case importOptions
    case importCredential(WalletImportCredential)
    case privateKeyNetworkSelection
    case privateKeyCredential(PrivateKeyImportNetwork)
    case muunRecoveryMethods
    case muunEmergencyKit
    case muunEncryptedKeys
    case trustWalletPassword
    case restoreICloud
    case deviceMigrationImport(DeviceMigrationInvitation)
    case walletReady

    var isPhysicalEntropyDestination: Bool {
        if case .physicalEntropy = self {
            return true
        }
        return false
    }
}

enum OnboardingNavigationTransition {
    static func pushing(
        _ destination: OnboardingDestination,
        onto path: [OnboardingDestination]
    ) -> [OnboardingDestination] {
        path + [destination]
    }
}

enum OnboardingImportPersistenceEntry {
    static func destination(
        usesExistingProfileSecurity: Bool
    ) -> OnboardingDestination {
        usesExistingProfileSecurity ? .walletReady : .importPasscode
    }
}

enum OnboardingPasscodeCompletion: Equatable, Sendable {
    case persistCreatedWallet
    case persistImportedWallet

    var destination: OnboardingDestination {
        switch self {
        case .persistCreatedWallet: .creationPasscode
        case .persistImportedWallet: .importPasscode
        }
    }
}

enum OnboardingSheet: Identifiable {
    case deviceMigrationScanner
    case walletSetup(WalletRoute)
    case duplicateImport(DuplicateWalletImportWarning)
    case unsafeCredential(UnsafeCredentialImportWarning)

    var id: String {
        switch self {
        case .deviceMigrationScanner:
            "device-migration-scanner"
        case let .walletSetup(route):
            "wallet-setup-\(String(describing: route))"
        case let .duplicateImport(warning):
            "duplicate-\(warning.id)"
        case let .unsafeCredential(warning):
            "unsafe-credential-\(warning.id)"
        }
    }
}

#Preview("iPhone") {
    WalletDatabasePreviewHost { database in
        OnboardingView(database: database)
    }
}

#Preview("Accessibility text") {
    WalletDatabasePreviewHost { database in
        OnboardingView(database: database)
            .environment(\.dynamicTypeSize, .accessibility3)
    }
}
