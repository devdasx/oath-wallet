import SwiftUI

enum WalletSecurityAuthenticationPurpose {
    case appUnlock
    case settings
    case resetAppData
    case removeWallet
    case deleteICloudBackup
    case walletSensitiveData
    case sendTransaction
    case deviceMigrationExport

    var titleKey: LocalizedStringKey {
        "security.authentication.passcode.title"
    }

    var messageKey: LocalizedStringKey {
        switch self {
        case .appUnlock:
            "security.authentication.unlock.biometric_reason"
        case .settings:
            "security.authentication.settings.message"
        case .resetAppData:
            "security.authentication.reset.biometric_reason"
        case .removeWallet:
            "security.authentication.remove_wallet.message"
        case .deleteICloudBackup:
            "security.authentication.delete_icloud_backup.message"
        case .walletSensitiveData:
            "security.authentication.wallet_sensitive.message"
        case .sendTransaction:
            "send.authorization.message"
        case .deviceMigrationExport:
            "device_migration.authentication.message"
        }
    }

    var biometricReasonKey: String {
        switch self {
        case .appUnlock:
            "security.authentication.unlock.biometric_reason"
        case .settings:
            "security.authentication.settings.biometric_reason"
        case .resetAppData:
            "security.authentication.reset.biometric_reason"
        case .removeWallet:
            "security.authentication.remove_wallet.biometric_reason"
        case .deleteICloudBackup:
            "security.authentication.delete_icloud_backup.biometric_reason"
        case .walletSensitiveData:
            "security.authentication.wallet_sensitive.biometric_reason"
        case .sendTransaction:
            "send.authorization.biometric_reason"
        case .deviceMigrationExport:
            "device_migration.authentication.biometric_reason"
        }
    }

    var diagnosticSource: String {
        switch self {
        case .appUnlock:
            "app_unlock"
        case .settings:
            "security_settings"
        case .resetAppData:
            "reset_app_data"
        case .removeWallet:
            "remove_wallet"
        case .deleteICloudBackup:
            "delete_icloud_backup"
        case .walletSensitiveData:
            "wallet_sensitive_data"
        case .sendTransaction:
            "send_transaction"
        case .deviceMigrationExport:
            "device_migration_export"
        }
    }
}
