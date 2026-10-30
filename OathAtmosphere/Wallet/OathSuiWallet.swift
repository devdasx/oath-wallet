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
        if let material = secret.suiMultisig {
            guard account.derivationPath == "sui-multisig-v1", plan.multisig == (try material.policy()) else { throw SuiSendError.changed }
            try material.validateMaterial()
            var keys = try material.signers.sorted { $0.publicKey.lexicographicallyPrecedes($1.publicKey) }.prefix(material.required).map { try $0.signingKey() }
            defer { for i in keys.indices { keys[i].resetBytes(in: 0..<keys[i].count) } }
            return try SuiSendCrypto.sign(plan, privateKeys: keys)
        }
        guard plan.multisig == nil else { throw SuiSendError.changed }
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
