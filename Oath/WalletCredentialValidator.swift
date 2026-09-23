import Foundation
import WalletCore

enum BIP39MnemonicValidator {
    static func isValid(_ mnemonic: String) -> Bool {
        WalletCoreService.isValidRecoveryPhrase(mnemonic)
    }
}

enum EVMPrivateKeyValidator {
    static func isValid(_ privateKey: String) -> Bool {
        WalletCoreService.isValidPrivateKey(privateKey)
    }
}
