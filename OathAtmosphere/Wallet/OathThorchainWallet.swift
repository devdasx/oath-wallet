import Foundation
import WalletCore
import OathCloudBackup
import OathDatabase
import OathAnkr

extension OathWalletEngine {
    private static func thorchainKey(secret:OathWalletSecret,account:AccountRecord) throws -> Data {
        try Task.checkCancellation()
        guard account.walletID==secret.id.uuidString,account.networkID=="thorchain" else { throw ThorchainSendError.wrongOwner }
        var bytes:Data
        if let material=secret.privateKey {
            guard material.isValidStructure,material.networks == [.thorchain],account.derivationPath=="imported" else { throw ThorchainSendError.wrongOwner }
            bytes=material.bytes
        } else {
            let passphrase = try secret.bip39Passphrase
            guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
                  let wallet=HDWallet(mnemonic:secret.mnemonic,passphrase:passphrase,check:false),
                  let key=wallet.getKey(coin:.thorchain,derivationPath:account.derivationPath) else { throw OathWalletError.derivationFailed }
            bytes = key.data
        }
        return bytes
    }
    static func thorchainPublicKey(secret:OathWalletSecret,account:AccountRecord) throws -> Data {
        var bytes=try thorchainKey(secret:secret,account:account);defer { bytes.resetBytes(in:0..<bytes.count) }
        let pub=try ThorchainSendCrypto.publicKey(privateKey:bytes)
        guard try ThorchainIdentity.address(account.address)==ThorchainSendCrypto.address(publicKey:pub,network:.mainnet) else { throw ThorchainSendError.wrongOwner }
        return pub
    }
    static func signThorchain(_ plan:ThorchainSendPlan,secret:OathWalletSecret,account:AccountRecord) throws -> ThorchainSignedSend {
        guard try ThorchainIdentity.address(account.address)==plan.sender else { throw ThorchainSendError.wrongOwner }
        var bytes=try thorchainKey(secret:secret,account:account);defer { bytes.resetBytes(in:0..<bytes.count) }
        return try ThorchainSendCrypto.sign(plan,privateKey:bytes)
    }
    static func signThorchainWalletConnect(_ request: ThorchainWalletConnectRequest, secret: OathWalletSecret, account: AccountRecord) throws -> SolanaJSON {
        guard request.network == .mainnet, account.address == request.sender else { throw ThorchainSendError.wrongOwner }
        var bytes = try thorchainKey(secret: secret, account: account)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return try request.sign(privateKey: bytes)
    }
}
