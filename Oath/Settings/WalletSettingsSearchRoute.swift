import Foundation

enum WalletSettingsSearchRoute: Hashable, Sendable {
    case root
    case wallets
    case security
    case deviceMigrationExport
    case appearance
    case language
    case currency
    case backupAndKeys
    case backupMaterial(wallet: ManagedWallet)
    case backupMethod(
        walletID: String,
        material: SettingsBackupMaterialChoice
    )
    case tools
    case currencyConverter
    case networkFeeDashboard
    case transactionExport
    case networkFeeDetails(String)
    case bitcoinTransactionBroadcaster
    case mnemonicLastWordFinder
    case evmAccessManager
    case evmApprovalReview(EVMOnChainApproval)
    case notifications
    case about
    case reset
}
