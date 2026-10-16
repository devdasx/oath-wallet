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
        guard account.address==plan.sender else { throw SolanaSendError.wrongOwner }
        var bytes=try solanaKey(secret:secret,account:account);defer { bytes.resetBytes(in:0..<bytes.count) }
        return try SolanaSendCrypto.sign(plan,privateKey:bytes)
    }
}
