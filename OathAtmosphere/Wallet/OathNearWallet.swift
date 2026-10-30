import Foundation
import WalletCore
import OathCloudBackup
import OathDatabase
import OathAnkr

extension OathWalletEngine {
    private static func nearKey(secret:OathWalletSecret,account:AccountRecord) throws -> Data {
        try Task.checkCancellation()
        guard account.walletID==secret.id.uuidString,account.networkID=="near" else { throw NearSendError.wrongOwner }
        var bytes:Data
        if let material=secret.privateKey {
            guard material.isValidStructure,material.networks == [.near],account.derivationPath=="imported" else { throw NearSendError.wrongOwner }
            bytes=material.bytes
        } else {
            let passphrase = try secret.bip39Passphrase
            guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
                  let wallet=HDWallet(mnemonic:secret.mnemonic,passphrase:passphrase,check:false),
                  let key=wallet.getKey(coin:.near,derivationPath:account.derivationPath) else { throw OathWalletError.derivationFailed }
            bytes = key.data
        }
        return bytes
    }
    static func nearPublicKey(secret:OathWalletSecret,account:AccountRecord) throws -> Data {
        if let material=secret.nearMultisig {
            guard account.walletID==secret.id.uuidString,account.networkID=="near",account.derivationPath=="near-multisig-v1",account.address==material.address else { throw NearSendError.wrongOwner }
            return try material.policy().publicKeys[0]
        }
        var bytes=try nearKey(secret:secret,account:account);defer { bytes.resetBytes(in:0..<bytes.count) }
        let pub=try NearSendCrypto.publicKey(privateKey:bytes)
        if NearSendPlan.isImplicit(account.address) {
            guard try NearSendCrypto.address(privateKey:bytes)==account.address else { throw NearSendError.wrongOwner }
        }
        return pub
    }
    static func signNear(_ plan:NearSendPlan,secret:OathWalletSecret,account:AccountRecord) throws -> NearSignedSend {
        guard try NearIdentity.address(account.address)==plan.sender else { throw NearSendError.wrongOwner }
        if let material=secret.nearMultisig {
            guard account.walletID==secret.id.uuidString,account.networkID=="near",account.derivationPath=="near-multisig-v1",
                  let context=plan.multisig,context.policy == (try material.policy()) else { throw NearSendError.changed }
            try material.validateMaterial()
            var keys = try context.stage == .transfer ? material.signers.sorted { $0.publicKey.lexicographicallyPrecedes($1.publicKey) }.prefix(material.required).map { try $0.signingKey() } : [material.bootstrapSeed]
            defer { for i in keys.indices { keys[i].resetBytes(in:0..<keys[i].count) } }
            return try NearSendCrypto.sign(plan,privateKeys:keys)
        }
        guard plan.multisig == nil else { throw NearSendError.changed }
        var bytes=try nearKey(secret:secret,account:account);defer { bytes.resetBytes(in:0..<bytes.count) }
        return try NearSendCrypto.sign(plan,privateKey:bytes)
    }
}
