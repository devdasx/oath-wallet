import Foundation
import OathCloudBackup

/// A single validated multisig type, added without replacing the existing vault.
enum OathMultisigMaterial: Sendable {
    case bitcoin(BackupWallet.BitcoinMultisig)
    case tron(BackupWallet.TronMultisig)
    case solana(BackupWallet.SolanaMultisig)
    case xrpl(BackupWallet.XrplMultisig)
    case stellar(BackupWallet.StellarMultisig)
    case aptos(BackupWallet.AptosMultisig)
    case sui(BackupWallet.SuiMultisig)
    case near(BackupWallet.NearMultisig)
    case evm(BackupWallet.EVMMultisig)
    case ton(BackupWallet.TonMultisig)
    case thorchain(BackupWallet.ThorchainMultisig)

    func secret(id: UUID) throws -> OathWalletSecret {
        switch self {
        case .bitcoin(let material): try OathWalletEngine.multisig(material, id: id)
        case .tron(let material): try OathWalletEngine.multisig(material, id: id)
        case .solana(let material): try OathWalletEngine.multisig(material, id: id)
        case .xrpl(let material): try OathWalletEngine.multisig(material, id: id)
        case .stellar(let material): try OathWalletEngine.multisig(material, id: id)
        case .aptos(let material): try OathWalletEngine.multisig(material, id: id)
        case .sui(let material): try OathWalletEngine.multisig(material, id: id)
        case .near(let material): try OathWalletEngine.multisig(material, id: id)
        case .evm(let material): try OathWalletEngine.multisig(material, id: id)
        case .ton(let material): try OathWalletEngine.multisig(material, id: id)
        case .thorchain(let material): try OathWalletEngine.multisig(material, id: id)
        }
    }
}
