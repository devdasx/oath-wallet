import Foundation
import WalletCore
import OathCloudBackup
import OathDatabase
import OathAnkr
import OathSecp256k1

extension OathWalletEngine {
    static func signWalletConnectMessage(_ message: Data, secret: OathWalletSecret, account: AccountRecord) throws -> String {
        guard message.count <= 4_096 else { throw OathWalletError.locked }
        return try withWalletConnectKey(secret: secret, account: account) { key in
            try OathWalletConnectMessage.sign(message, key: key, account: account.address)
        }
    }
    static func signWalletConnectTypedData(_ data: WalletConnectTypedData, secret: OathWalletSecret, account: AccountRecord) throws -> String {
        let chainID = EVMSendNetwork(rawValue: account.networkID)?.chainID ?? (account.networkID == "arc" ? ArcSendNetwork.mainnet.chainID : nil)
        guard chainID == data.sessionChainID else { throw WalletConnectTypedData.Failure.wrongChain }
        try data.validatePermissionTime()
        return try withWalletConnectKey(secret: secret, account: account) { key in
            try data.sign(privateKey: key, account: account.address)
        }
    }
    private static func withWalletConnectKey(secret: OathWalletSecret, account: AccountRecord, body: (Data) throws -> String) throws -> String {
        guard account.walletID == secret.id.uuidString,
              let chain = OathImportChain(rawValue: account.networkID), chain.isEVM else { throw OathWalletError.locked }
        var bytes: Data
        if let material = secret.privateKey {
            guard material.isValidStructure, material.networks.contains(chain) || material.isFullEVMScope,
                  account.derivationPath == "imported" else { throw OathWalletError.locked }
            bytes = material.bytes
        } else {
            let passphrase = try secret.bip39Passphrase
            guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
                  let wallet = HDWallet(mnemonic: secret.mnemonic, passphrase: passphrase, check: false),
                  let key = wallet.getKey(coin: .ethereum, derivationPath: account.derivationPath) else { throw OathWalletError.derivationFailed }
            bytes = key.data
        }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return try body(bytes)
    }
}
