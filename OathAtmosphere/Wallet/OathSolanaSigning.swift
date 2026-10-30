import Foundation
import WalletCore
import OathCloudBackup
import OathDatabase
import OathAnkr

extension OathWalletEngine {
    private static func solanaKey(secret:OathWalletSecret,account:AccountRecord) throws -> Data {
        try Task.checkCancellation()
        guard account.walletID==secret.id.uuidString,account.networkID=="solana" else { throw SolanaSendError.wrongOwner }
        var bytes:Data
        if let material=secret.privateKey {
            guard material.isValidStructure,material.networks == [.solana],account.derivationPath=="imported" else { throw SolanaSendError.wrongOwner }
            bytes=material.bytes
        } else {
            let passphrase = try secret.bip39Passphrase
            guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
                  let wallet=HDWallet(mnemonic:secret.mnemonic,passphrase:passphrase,check:false),
                  let key=wallet.getKey(coin:.solana,derivationPath:account.derivationPath) else { throw OathWalletError.derivationFailed }
            bytes = key.data
        }
        return bytes
    }
    static func solanaPublicKey(secret:OathWalletSecret,account:AccountRecord) throws -> Data {
        var bytes=try solanaKey(secret:secret,account:account);defer { bytes.resetBytes(in:0..<bytes.count) }
        let pub=try SolanaSendCrypto.publicKey(privateKey:bytes)
        guard account.address == (try SolanaSendCrypto.address(privateKey:bytes)) else { throw SolanaSendError.wrongOwner }
        return pub
    }
    static func signWalletConnectSolana(_ request: WalletConnectSolanaRequest, secret: OathWalletSecret, account: AccountRecord) throws -> WalletConnectSolanaSigned {
        guard account.address == request.account else { throw SolanaSendError.wrongOwner }
        var bytes = try solanaKey(secret: secret, account: account); defer { bytes.resetBytes(in: 0..<bytes.count) }
        return try request.sign(privateKey: bytes)
    }
    static func signSolana(_ plan:SolanaSendPlan,secret:OathWalletSecret,account:AccountRecord) throws -> SolanaSignedSend {
        guard account.walletID == secret.id.uuidString, account.networkID == "solana", account.address==plan.sender else { throw SolanaSendError.wrongOwner }
        if let material = secret.solanaMultisig {
            guard account.derivationPath == "solana-multisig-v1", let context = plan.multisig,
                  try material.policy() == context.policy else { throw SolanaSendError.changed }
            try plan.validate()
            var keys = try context.signingMembers.map { address in
                guard let signer = material.signers.first(where: { $0.address == address }) else { throw SolanaSendError.wrongOwner }
                return try signer.signingKey()
            }
            if context.setupTreasury != nil { keys.append(material.createSeed) }
            defer { for i in keys.indices { keys[i].resetBytes(in: 0..<keys[i].count) } }
            return try SolanaMultisigCrypto.sign(plan, privateKeys: keys)
        }
        guard plan.multisig == nil else { throw SolanaSendError.changed }
        var bytes=try solanaKey(secret:secret,account:account);defer { bytes.resetBytes(in:0..<bytes.count) }
        return try SolanaSendCrypto.sign(plan,privateKey:bytes)
    }
}
