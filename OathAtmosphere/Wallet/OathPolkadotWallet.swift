import Foundation
import WalletCore
import OathCloudBackup
import OathDatabase
import OathAnkr

extension OathWalletEngine {
    static func signPolkadot(_ plan: PolkadotSendPlan, secret: OathWalletSecret, account: AccountRecord) throws -> PolkadotSignedSend {
        try Task.checkCancellation()
        guard account.walletID == secret.id.uuidString, account.networkID == "polkadot",
              try PolkadotIdentity.publicKey(account.address) == PolkadotIdentity.publicKey(plan.sender) else { throw PolkadotSendError.wrongOwner }
        var bytes: Data
        if let material = secret.privateKey {
            guard material.isValidStructure, material.networks == [.polkadot], account.derivationPath == "imported" else { throw PolkadotSendError.wrongOwner }
            bytes = material.bytes
        } else {
            let passphrase = try secret.bip39Passphrase
            guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
                  let wallet = HDWallet(mnemonic:secret.mnemonic,passphrase:passphrase,check:false),
                  let key = wallet.getKey(coin:.polkadot,derivationPath:account.derivationPath) else { throw OathWalletError.derivationFailed }
            bytes = key.data
        }
        defer { bytes.resetBytes(in:0..<bytes.count) }
        return try PolkadotSendCrypto.sign(plan,privateKey:bytes)
    }
}
