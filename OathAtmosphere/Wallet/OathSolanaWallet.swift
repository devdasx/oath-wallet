import Foundation
import WalletCore
import OathCloudBackup
import OathDatabase

extension OathWalletEngine {
    /// Derived only while the vault is unlocked. Private material never leaves
    /// WalletCore; the database receives public addresses and their exact paths.
    static func solanaReceiveAddresses(for secret: OathWalletSecret, account: AccountRecord) throws -> [SolanaReceiveAddress] {
        try Task.checkCancellation()
        guard account.walletID == secret.id.uuidString, account.networkID == "solana" else {
            throw OathWalletError.derivationFailed
        }
        if let material = secret.privateKey {
            guard account.derivationPath == "imported",
                  try importedKeyProfile(for: secret, material: material).addresses.contains(where: {
                      $0.chain == .solana && $0.address == account.address && $0.path == account.derivationPath
                  }) else { throw OathWalletError.derivationFailed }
            return [.init(path: account.derivationPath, address: account.address)]
        }
        let passphrase = try secret.bip39Passphrase
        guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
              let wallet = HDWallet(mnemonic: secret.mnemonic, passphrase: passphrase, check: false) else {
            throw OathWalletError.invalidPhrase
        }
        let index = SolanaDerivation.accountIndex(in: account.derivationPath) ?? account.accountIndex
        var paths = try SolanaDerivation.allCases.map { try $0.path(accountIndex: index) }
        // A restored nonstandard account remains reachable as "Original address".
        if !paths.contains(account.derivationPath) { paths.append(account.derivationPath) }
        let addresses = try paths.map { path -> SolanaReceiveAddress in
            try Task.checkCancellation()
            guard let key = wallet.getKey(coin: .solana, derivationPath: path) else { throw OathWalletError.derivationFailed }
            let address = CoinType.solana.deriveAddress(privateKey: key)
            guard AnyAddress.isValid(string: address, coin: .solana) else { throw OathWalletError.derivationFailed }
            return .init(path: path, address: address)
        }
        guard addresses.contains(.init(path: account.derivationPath, address: account.address)) else {
            throw OathWalletError.derivationFailed
        }
        return addresses
    }
}
