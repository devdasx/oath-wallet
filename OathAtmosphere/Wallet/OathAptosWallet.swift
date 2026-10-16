import Foundation
import WalletCore
import OathCloudBackup
import OathDatabase
import OathAnkr

extension OathWalletEngine {
    private static func aptosKey(secret:OathWalletSecret,account:AccountRecord) throws -> Data {
        try Task.checkCancellation()
        guard account.walletID==secret.id.uuidString,account.networkID=="aptos" else { throw AptosSendError.wrongOwner }
        var bytes:Data
        if let material=secret.privateKey {
            guard material.isValidStructure,material.networks == [.aptos],account.derivationPath=="imported" else { throw AptosSendError.wrongOwner }
            bytes=material.bytes
        } else {
            let passphrase = try secret.bip39Passphrase
            guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
                  let wallet=HDWallet(mnemonic:secret.mnemonic,passphrase:passphrase,check:false),
                  let key=wallet.getKey(coin:.aptos,derivationPath:account.derivationPath) else { throw OathWalletError.derivationFailed }
            bytes = key.data
        }
        return bytes
    }
    static func aptosPublicKey(secret:OathWalletSecret,account:AccountRecord) throws -> Data {
        var bytes=try aptosKey(secret:secret,account:account);defer { bytes.resetBytes(in:0..<bytes.count) }
        let pub=try AptosSendCrypto.publicKey(privateKey:bytes)
        guard try AptosIdentity.address(account.address)==AptosSendCrypto.address(privateKey:bytes) else { throw AptosSendError.wrongOwner }
        return pub
    }
    static func signAptos(_ plan:AptosSendPlan,secret:OathWalletSecret,account:AccountRecord) throws -> AptosSignedSend {
        guard try AptosIdentity.address(account.address)==plan.sender else { throw AptosSendError.wrongOwner }
        var bytes=try aptosKey(secret:secret,account:account);defer { bytes.resetBytes(in:0..<bytes.count) }
        return try AptosSendCrypto.sign(plan,privateKey:bytes)
    }
}
