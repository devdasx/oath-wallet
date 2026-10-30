import Foundation
import WalletCore
import OathAnkr
import OathCloudBackup

extension BackupWallet.AptosMultisig.Signer {
    static let path = "m/44'/637'/0'/0'/0'"
    func signingKey() throws -> Data {
        guard isValidStructure else { throw OathWalletError.invalidPrivateKey }
        let bytes: Data
        if let key { bytes = key }
        else {
            guard let mnemonic, let language,
                  let checked = OathMnemonicValidator.bundled?.verifiedPhrase(mnemonic), checked.language == language,
                  let wallet = HDWallet(mnemonic: checked.phrase,
                      passphrase: try passphrase.map(RecoveryPassphrase.normalized) ?? "", check: false),
                  let key = wallet.getKey(coin: .aptos, derivationPath: Self.path) else { throw OathWalletError.invalidPhrase }
            bytes = key.data
        }
        guard try AptosSendCrypto.publicKey(privateKey: bytes) == publicKey else { throw AptosSendError.wrongOwner }
        return bytes
    }
    static func phrase(_ text: String, passphrase: String?) throws -> Self {
        guard let phrase = OathMnemonicValidator.bundled?.verifiedPhrase(text),
              let wallet = HDWallet(mnemonic: phrase.phrase, passphrase: try passphrase.map(RecoveryPassphrase.normalized) ?? "", check: false),
              let key = wallet.getKey(coin: .aptos, derivationPath: path) else { throw OathWalletError.invalidPhrase }
        return try .init(publicKey: AptosSendCrypto.publicKey(privateKey: key.data), mnemonic: phrase.phrase,
                         language: phrase.language, passphrase: passphrase)
    }
}
extension BackupWallet.AptosMultisig {
    func policy() throws -> AptosMultisigPolicy {
        guard isValidStructure else { throw OathWalletError.invalidPrivateKey }
        let policy = try AptosMultisigPolicy(required: required, publicKeys: signers.map(\.publicKey))
        guard policy.address == address else { throw AptosSendError.wrongOwner }
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
        return "Oath Aptos multisig v1\nSigner BIP39 derivation: m/44'/637'/0'/0'/0'\n" + String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
}
extension OathWalletEngine {
    static func multisig(_ material: BackupWallet.AptosMultisig, id: UUID = UUID()) throws -> OathWalletSecret {
        try material.validateMaterial()
        return .init(id: id, mnemonic: "", language: "", createdAt: .now, backedUp: false, aptosMultisig: material)
    }
    static func multisigProfile(for secret: OathWalletSecret, material: BackupWallet.AptosMultisig) throws -> OathWalletProfile {
        try material.validateMaterial()
        return .init(id: secret.id, addresses: [.init(chain: .aptos, address: material.address, path: "aptos-multisig-v1")],
                     createdAt: secret.createdAt, backedUp: secret.backedUp)
    }
}
