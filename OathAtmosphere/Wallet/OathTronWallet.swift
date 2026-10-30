import Foundation
import WalletCore
import OathCloudBackup
import OathDatabase
import OathAnkr

extension OathWalletEngine {
    static func signTron(_ plan: TronSendPlan, secret: OathWalletSecret, account: AccountRecord) throws -> TronSignedSend {
        try Task.checkCancellation()
        guard account.walletID == secret.id.uuidString, account.networkID == "tron",
              try TronIdentity.address(account.address) == plan.sender else { throw TronSendError.wrongOwner }
        if let material = secret.tronMultisig {
            guard account.derivationPath == "tron-multisig-v1", material.address == plan.sender else { throw TronSendError.wrongOwner }
            let policy = try material.policy()
            if let setup = plan.multisigSetup {
                guard setup == policy, plan.multisig == nil else { throw TronSendError.changed }
                return try TronSendCrypto.sign(plan, privateKey: material.accountKey)
            }
            guard plan.multisig == policy, plan.removal == nil else { throw TronSendError.changed }
            var keys = try material.signers.prefix(material.required).map { try $0.signingKey() }
            defer { for i in keys.indices { keys[i].resetBytes(in: 0..<keys[i].count) } }
            return try TronSendCrypto.sign(plan, privateKeys: keys)
        }
        guard plan.multisig == nil, plan.multisigSetup == nil else { throw TronSendError.changed }
        var bytes: Data
        if let material = secret.privateKey {
            guard material.isValidStructure, material.networks == [.tron], account.derivationPath == "imported" else { throw TronSendError.wrongOwner }
            bytes = material.bytes
        } else {
            let passphrase = try secret.bip39Passphrase
            guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
                  let wallet = HDWallet(mnemonic:secret.mnemonic,passphrase:passphrase,check:false),
                  let key = wallet.getKey(coin:.tron,derivationPath:account.derivationPath) else { throw OathWalletError.derivationFailed }
            bytes = key.data
        }
        defer { bytes.resetBytes(in:0..<bytes.count) }
        // Address equality validates the exact derived/imported signing key.
        return try TronSendCrypto.sign(plan,privateKey:bytes)
    }
}

extension OathWalletEngine {
    static func signWalletConnectTron(_ request: WalletConnectTronRequest, review: WalletConnectTronReview?, secret: OathWalletSecret, account: AccountRecord) throws -> TronJSON {
        try Task.checkCancellation()
        guard account.walletID == secret.id.uuidString, account.networkID == "tron", secret.tronMultisig == nil,
              try TronIdentity.address(account.address) == request.account else { throw TronSendError.wrongOwner }
        if request.message == nil {
            guard let review, review.request == request else { throw TronSendError.changed }
            try review.validate()
        }
        var key: Data
        if let material = secret.privateKey {
            guard material.isValidStructure, material.networks == [.tron], account.derivationPath == "imported" else { throw TronSendError.wrongOwner }
            key = material.bytes
        } else {
            let passphrase = try secret.bip39Passphrase
            guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
                  let wallet = HDWallet(mnemonic:secret.mnemonic, passphrase:passphrase, check:false),
                  let derived = wallet.getKey(coin:.tron, derivationPath:account.derivationPath) else { throw OathWalletError.derivationFailed }
            key = derived.data
        }
        defer { key.resetBytes(in:0..<key.count) }
        return try request.sign(privateKey:key)
    }
}
