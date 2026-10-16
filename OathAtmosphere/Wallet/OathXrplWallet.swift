import Foundation
import WalletCore
import OathCloudBackup
import OathDatabase
import OathAnkr

extension OathWalletEngine {
    static func signXrpl(_ plan: XrplSendPlan, secret: OathWalletSecret, account: AccountRecord) throws -> XrplSignedSend {
        try Task.checkCancellation()
        guard account.walletID == secret.id.uuidString, account.networkID == "xrpl",
              try XrplIdentity.address(account.address) == plan.sender else { throw XrplSendError.wrongOwner }
        var bytes: Data
        if let material = secret.privateKey {
            guard material.isValidStructure, material.networks == [.xrpl], account.derivationPath == "imported" else { throw XrplSendError.wrongOwner }
            bytes = material.bytes
        } else {
            let passphrase = try secret.bip39Passphrase
            guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
                  let wallet = HDWallet(mnemonic:secret.mnemonic,passphrase:passphrase,check:false),
                  let key = wallet.getKey(coin:.xrp,derivationPath:account.derivationPath) else { throw OathWalletError.derivationFailed }
            bytes = key.data
        }
        defer { bytes.resetBytes(in:0..<bytes.count) }
        // Address equality validates the exact derived/imported signing key.
        return try XrplSendCrypto.sign(plan,privateKey:bytes)
    }
}
