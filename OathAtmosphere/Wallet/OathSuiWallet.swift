import Foundation
import WalletCore
import OathCloudBackup
import OathDatabase
import OathAnkr

extension OathWalletEngine {
    static func signSui(_ plan: SuiSendPlan, secret: OathWalletSecret, account: AccountRecord) throws -> SuiSignedSend {
        try Task.checkCancellation()
        guard account.walletID == secret.id.uuidString, account.networkID == "sui",
              try SuiIdentity.address(account.address) == plan.sender else { throw SuiSendError.wrongOwner }
        var bytes: Data
        if let material = secret.privateKey {
            guard material.isValidStructure, material.networks == [.sui], account.derivationPath == "imported" else { throw SuiSendError.wrongOwner }
            bytes = material.bytes
        } else {
            let passphrase = try secret.bip39Passphrase
            guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
                  let wallet = HDWallet(mnemonic:secret.mnemonic,passphrase:passphrase,check:false),
                  let key = wallet.getKey(coin:.sui,derivationPath:account.derivationPath) else { throw OathWalletError.derivationFailed }
            bytes = key.data
        }
        defer { bytes.resetBytes(in:0..<bytes.count) }
        // Address equality validates the exact derived/imported signing key.
        return try SuiSendCrypto.sign(plan,privateKey:bytes)
    }
}
