import Foundation
import WalletCore
import OathAnkr
import OathCloudBackup

extension BackupWallet.ThorchainMultisig.Signer {
    static func importedKey(_ text: String) throws -> Data {
        let key = try TronIdentity.hex(text)
        guard key.count == 32 else { throw OathWalletError.invalidPrivateKey }
        return key
    }
    static let path = "m/44'/931'/0'/0/0"
    func signingKey() throws -> Data {
        guard isValidStructure else { throw OathWalletError.invalidPrivateKey }
        let bytes: Data
        if let key { bytes = key }
        else {
            guard let mnemonic, let language,
                  let checked = OathMnemonicValidator.bundled?.verifiedPhrase(mnemonic), checked.language == language,
                  let wallet = HDWallet(mnemonic: checked.phrase,
                      passphrase: try passphrase.map(RecoveryPassphrase.normalized) ?? "", check: false),
                  let key = wallet.getKey(coin: .thorchain, derivationPath: Self.path) else { throw OathWalletError.invalidPhrase }
            bytes = key.data
        }
        guard try ThorchainSendCrypto.publicKey(privateKey: bytes) == publicKey else { throw ThorchainSendError.wrongOwner }
        return bytes
    }
    static func phrase(_ text: String, passphrase: String?) throws -> Self {
        guard let phrase = OathMnemonicValidator.bundled?.verifiedPhrase(text),
              let wallet = HDWallet(mnemonic: phrase.phrase, passphrase: try passphrase.map(RecoveryPassphrase.normalized) ?? "", check: false),
              let key = wallet.getKey(coin: .thorchain, derivationPath: path) else { throw OathWalletError.invalidPhrase }
        return try .init(publicKey: ThorchainSendCrypto.publicKey(privateKey: key.data), mnemonic: phrase.phrase,
                         language: phrase.language, passphrase: passphrase)
    }
}
extension BackupWallet.ThorchainMultisig {
    func policy() throws -> ThorchainMultisigPolicy {
        guard isValidStructure else { throw OathWalletError.invalidPrivateKey }
        let policy = try ThorchainMultisigPolicy(required: required, publicKeys: signers.map(\.publicKey))
        guard policy.address(network: .mainnet) == address else { throw ThorchainSendError.wrongOwner }
        return policy
    }
    func validateMaterial() throws {
        _ = try policy()
        for signer in signers {
            var bytes = try signer.signingKey(); bytes.resetBytes(in: 0..<bytes.count)
        }
    }
    var recoveryText: String {
        // A portable, versioned JSON export avoids ambiguous passphrase whitespace.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return "Oath THORChain multisig v1\nSigner BIP39 derivation: m/44'/931'/0'/0/0\n" + String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
}
extension OathWalletEngine {
    static func multisig(_ material: BackupWallet.ThorchainMultisig, id: UUID = UUID()) throws -> OathWalletSecret {
        try material.validateMaterial()
        return .init(id: id, mnemonic: "", language: "", createdAt: .now, backedUp: false, thorchainMultisig: material)
    }
    static func multisigProfile(for secret: OathWalletSecret, material: BackupWallet.ThorchainMultisig) throws -> OathWalletProfile {
        try material.validateMaterial()
        return .init(id: secret.id, addresses: [.init(chain: .thorchain, address: material.address, path: "thorchain-multisig-v1")],
                     createdAt: secret.createdAt, backedUp: secret.backedUp)
    }
}
