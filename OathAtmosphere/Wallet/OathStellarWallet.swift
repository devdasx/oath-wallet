import Foundation
import WalletCore
import OathCloudBackup
import OathDatabase
import OathAnkr

extension OathWalletEngine {
    static func signStellar(_ plan: StellarSendPlan, secret: OathWalletSecret, account: AccountRecord) throws -> StellarSignedSend {
        try Task.checkCancellation()
        guard account.walletID == secret.id.uuidString, account.networkID == "stellar",
              try StellarIdentity.address(account.address) == plan.sender else { throw StellarSendError.wrongOwner }
        var bytes: Data
        if let material = secret.privateKey {
            guard material.isValidStructure, material.networks == [.stellar], account.derivationPath == "imported" else { throw StellarSendError.wrongOwner }
            bytes = material.bytes
        } else {
            let passphrase = try secret.bip39Passphrase
            guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
                  let wallet = HDWallet(mnemonic:secret.mnemonic,passphrase:passphrase,check:false),
                  let key = wallet.getKey(coin:.stellar,derivationPath:account.derivationPath) else { throw OathWalletError.derivationFailed }
            bytes = key.data
        }
        defer { bytes.resetBytes(in:0..<bytes.count) }
        // Address equality validates the exact derived/imported signing key.
        return try StellarSendCrypto.sign(plan,privateKey:bytes)
    }
}
