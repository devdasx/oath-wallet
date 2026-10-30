import Foundation
import WalletCore
import OathAnkr
import OathCloudBackup

extension BackupWallet.NearMultisig.Signer {
    static func importedKey(_ text: String) throws -> Data {
        if text.hasPrefix("ed25519:") {
            let payload = try SolanaSendCrypto.decode(String(text.dropFirst(8)))
            guard payload.count == 32 || payload.count == 64 else { throw OathWalletError.invalidPrivateKey }
            let seed = Data(payload.prefix(32))
            if payload.count == 64 { guard try NearSendCrypto.publicKey(privateKey: seed) == Data(payload.suffix(32)) else { throw OathWalletError.invalidPrivateKey } }
            return seed
        }
        let key = try TronIdentity.hex(text)
        guard key.count == 32 else { throw OathWalletError.invalidPrivateKey }
        return key
    }
    static let path = "m/44'/397'/0'"
    func signingKey() throws -> Data {
        guard isValidStructure else { throw OathWalletError.invalidPrivateKey }
        let bytes: Data
        if let key { bytes = key }
        else {
            guard let mnemonic, let language,
                  let checked = OathMnemonicValidator.bundled?.verifiedPhrase(mnemonic), checked.language == language,
                  let wallet = HDWallet(mnemonic: checked.phrase,
                      passphrase: try passphrase.map(RecoveryPassphrase.normalized) ?? "", check: false),
                  let key = wallet.getKey(coin: .near, derivationPath: Self.path) else { throw OathWalletError.invalidPhrase }
            bytes = key.data
        }
        guard try NearSendCrypto.publicKey(privateKey: bytes) == publicKey else { throw NearSendError.wrongOwner }
        return bytes
    }
    static func phrase(_ text: String, passphrase: String?) throws -> Self {
        guard let phrase = OathMnemonicValidator.bundled?.verifiedPhrase(text),
              let wallet = HDWallet(mnemonic: phrase.phrase, passphrase: try passphrase.map(RecoveryPassphrase.normalized) ?? "", check: false),
              let key = wallet.getKey(coin: .near, derivationPath: path) else { throw OathWalletError.invalidPhrase }
        return try .init(publicKey: NearSendCrypto.publicKey(privateKey: key.data), mnemonic: phrase.phrase,
                         language: phrase.language, passphrase: passphrase)
    }
}
extension BackupWallet.NearMultisig {
    func policy() throws -> NearMultisigPolicy {
        guard isValidStructure else { throw OathWalletError.invalidPrivateKey }
        let policy = try NearMultisigPolicy(bootstrap: NearSendCrypto.publicKey(privateKey: bootstrapSeed), required: required, publicKeys: signers.map(\.publicKey))
        guard policy.address == address else { throw NearSendError.wrongOwner }
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
        return "Oath NEAR multisig v1\nSigner BIP39 derivation: m/44'/397'/0'\n" + String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
}
extension OathWalletEngine {
    static func multisig(_ material: BackupWallet.NearMultisig, id: UUID = UUID()) throws -> OathWalletSecret {
        try material.validateMaterial()
        return .init(id: id, mnemonic: "", language: "", createdAt: .now, backedUp: false, nearMultisig: material)
    }
    static func multisigProfile(for secret: OathWalletSecret, material: BackupWallet.NearMultisig) throws -> OathWalletProfile {
        try material.validateMaterial()
        return .init(id: secret.id, addresses: [.init(chain: .near, address: material.address, path: "near-multisig-v1")],
                     createdAt: secret.createdAt, backedUp: secret.backedUp)
    }
}
