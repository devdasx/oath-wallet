import Foundation
import WalletCore
import OathCloudBackup
import OathDatabase
import OathAnkr

extension OathWalletEngine {
    private static func tonKey(secret:OathWalletSecret,account:AccountRecord) throws -> Data {
        try Task.checkCancellation()
        guard account.walletID==secret.id.uuidString,account.networkID=="ton" else { throw TonSendError.wrongOwner }
        var bytes:Data
        if let material=secret.privateKey {
            guard material.isValidStructure,material.networks == [.ton],account.derivationPath=="imported" else { throw TonSendError.wrongOwner }
            bytes=material.bytes
        } else {
            let passphrase = try secret.bip39Passphrase
            guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
                  let wallet=HDWallet(mnemonic:secret.mnemonic,passphrase:passphrase,check:false),
                  let key=wallet.getKey(coin:.ton,derivationPath:account.derivationPath) else { throw OathWalletError.derivationFailed }
            bytes = key.data
        }
        return bytes
    }
    static func tonPublicKey(secret:OathWalletSecret,account:AccountRecord) throws -> Data {
        if let material = secret.tonMultisig {
            guard account.walletID == secret.id.uuidString, account.networkID == "ton", account.derivationPath == "ton-multisig-v1",
                  try TonIdentity.raw(account.address) == material.address else { throw TonSendError.wrongOwner }
            return try material.policy().publicKeys[0]
        }
        var bytes=try tonKey(secret:secret,account:account);defer { bytes.resetBytes(in:0..<bytes.count) }
        let pub=try TonSendCrypto.publicKey(privateKey:bytes)
        guard try TonIdentity.raw(account.address)==TonSendCrypto.address(publicKey:pub) else { throw TonSendError.wrongOwner }
        return pub
    }
    static func signTon(_ plan:TonSendPlan,secret:OathWalletSecret,account:AccountRecord) throws -> TonSignedSend {
        guard try TonIdentity.raw(account.address)==plan.sender else { throw TonSendError.wrongOwner }
        if let material = secret.tonMultisig {
            guard account.walletID == secret.id.uuidString, account.networkID == "ton", account.derivationPath == "ton-multisig-v1",
                  plan.network == .mainnet, try material.policy() == plan.multisig else { throw TonSendError.wrongOwner }
            var keys = [Data]()
            defer { for i in keys.indices { keys[i].resetBytes(in: 0..<keys[i].count) } }
            for signer in material.signers { keys.append(try signer.signingKey()) }
            return try TonMultisigCrypto.sign(plan, privateKeys: keys)
        }
        var bytes=try tonKey(secret:secret,account:account);defer { bytes.resetBytes(in:0..<bytes.count) }
        return try TonSendCrypto.sign(plan,privateKey:bytes)
    }
}
