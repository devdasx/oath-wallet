import Foundation
import WalletCore
import OathAnkr
import OathCloudBackup

extension BackupWallet.SolanaMultisig.Signer {
    static let path = "m/44'/501'/0'/0'"
    func signingKey() throws -> Data {
        guard isValidStructure else { throw OathWalletError.invalidPrivateKey }
        let bytes: Data
        if let key { bytes = key }
        else {
            guard let mnemonic, let language,
                  let checked = OathMnemonicValidator.bundled?.verifiedPhrase(mnemonic), checked.language == language,
                  let wallet = HDWallet(mnemonic: checked.phrase,
                      passphrase: try passphrase.map(RecoveryPassphrase.normalized) ?? "", check: false) else { throw OathWalletError.invalidPhrase }
            bytes = try SolanaMultisigCrypto.deriveSigner(seed: wallet.seed)
        }
        guard try SolanaSendCrypto.address(privateKey: bytes) == address else { throw SolanaSendError.wrongOwner }
        return bytes
    }
    static func phrase(_ text: String, passphrase: String?) throws -> Self {
        guard let phrase = OathMnemonicValidator.bundled?.verifiedPhrase(text),
              let wallet = HDWallet(mnemonic: phrase.phrase, passphrase: try passphrase.map(RecoveryPassphrase.normalized) ?? "", check: false) else { throw OathWalletError.invalidPhrase }
        return try .init(address: SolanaSendCrypto.address(privateKey: SolanaMultisigCrypto.deriveSigner(seed: wallet.seed)), mnemonic: phrase.phrase,
                         language: phrase.language, passphrase: passphrase)
    }
}
extension BackupWallet.SolanaMultisig {
    func policy() throws -> SolanaMultisigPolicy {
        guard isValidStructure else { throw OathWalletError.invalidPrivateKey }
        return try .init(createKey: SolanaSendCrypto.address(privateKey: createSeed), required: required, members: signers.map(\.address))
    }
    func validateMaterial() throws {
        _ = try policy()
        guard try policy().vault == address else { throw SolanaSendError.wrongOwner }
        for signer in signers {
            var bytes = try signer.signingKey(); bytes.resetBytes(in: 0..<bytes.count)
        }
    }
    var recoveryText: String {
        // A portable, versioned JSON export avoids ambiguous passphrase whitespace.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return "Oath Solana multisig v1\nSigner BIP39 derivation: m/44'/501'/0'/0'\n" + String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
}
extension OathWalletEngine {
    static func multisig(_ material: BackupWallet.SolanaMultisig, id: UUID = UUID()) throws -> OathWalletSecret {
        try material.validateMaterial()
        return .init(id: id, mnemonic: "", language: "", createdAt: .now, backedUp: false, solanaMultisig: material)
    }
    static func multisigProfile(for secret: OathWalletSecret, material: BackupWallet.SolanaMultisig) throws -> OathWalletProfile {
        try material.validateMaterial()
        return .init(id: secret.id, addresses: [.init(chain: .solana, address: material.address, path: "solana-multisig-v1")],
                     createdAt: secret.createdAt, backedUp: secret.backedUp)
    }
}
