import Foundation
import WalletCore
import OathAnkr
import OathCloudBackup

extension BackupWallet.SuiMultisig.Signer {
    static func importedKey(_ text: String) throws -> Data {
        if text.hasPrefix("suiprivkey1") {
            guard let payload = Bech32.decode(string: text), payload.count == 33, payload.first == 0 else { throw OathWalletError.invalidPrivateKey }
            return Data(payload.dropFirst())
        }
        let key = try TronIdentity.hex(text)
        guard key.count == 32 else { throw OathWalletError.invalidPrivateKey }
        return key
    }
    static let path = "m/44'/784'/0'/0'/0'"
    func signingKey() throws -> Data {
        guard isValidStructure else { throw OathWalletError.invalidPrivateKey }
        let bytes: Data
        if let key { bytes = key }
        else {
            guard let mnemonic, let language,
                  let checked = OathMnemonicValidator.bundled?.verifiedPhrase(mnemonic), checked.language == language,
                  let wallet = HDWallet(mnemonic: checked.phrase,
                      passphrase: try passphrase.map(RecoveryPassphrase.normalized) ?? "", check: false),
                  let key = wallet.getKey(coin: .sui, derivationPath: Self.path) else { throw OathWalletError.invalidPhrase }
            bytes = key.data
        }
        guard try SuiSendCrypto.publicKey(privateKey: bytes) == publicKey else { throw SuiSendError.wrongOwner }
        return bytes
    }
    static func phrase(_ text: String, passphrase: String?) throws -> Self {
        guard let phrase = OathMnemonicValidator.bundled?.verifiedPhrase(text),
              let wallet = HDWallet(mnemonic: phrase.phrase, passphrase: try passphrase.map(RecoveryPassphrase.normalized) ?? "", check: false),
              let key = wallet.getKey(coin: .sui, derivationPath: path) else { throw OathWalletError.invalidPhrase }
        return try .init(publicKey: SuiSendCrypto.publicKey(privateKey: key.data), mnemonic: phrase.phrase,
                         language: phrase.language, passphrase: passphrase)
    }
}
extension BackupWallet.SuiMultisig {
    func policy() throws -> SuiMultisigPolicy {
        guard isValidStructure else { throw OathWalletError.invalidPrivateKey }
        let policy = try SuiMultisigPolicy(required: required, publicKeys: signers.map(\.publicKey))
        guard policy.address == address else { throw SuiSendError.wrongOwner }
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
        return "Oath Sui multisig v1\nSigner BIP39 derivation: m/44'/784'/0'/0'/0'\n" + String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
}
extension OathWalletEngine {
    static func multisig(_ material: BackupWallet.SuiMultisig, id: UUID = UUID()) throws -> OathWalletSecret {
        try material.validateMaterial()
        return .init(id: id, mnemonic: "", language: "", createdAt: .now, backedUp: false, suiMultisig: material)
    }
    static func multisigProfile(for secret: OathWalletSecret, material: BackupWallet.SuiMultisig) throws -> OathWalletProfile {
        try material.validateMaterial()
        return .init(id: secret.id, addresses: [.init(chain: .sui, address: material.address, path: "sui-multisig-v1")],
                     createdAt: secret.createdAt, backedUp: secret.backedUp)
    }
}
