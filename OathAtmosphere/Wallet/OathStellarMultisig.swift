import Foundation
import WalletCore
import OathAnkr
import OathCloudBackup

extension BackupWallet.StellarMultisig.Signer {
    static let path = "m/44'/148'/0'"
    func signingKey() throws -> Data {
        guard isValidStructure else { throw OathWalletError.invalidPrivateKey }
        let bytes: Data
        if let key { bytes = key }
        else {
            guard let mnemonic, let language,
                  let checked = OathMnemonicValidator.bundled?.verifiedPhrase(mnemonic), checked.language == language,
                  let wallet = HDWallet(mnemonic: checked.phrase,
                      passphrase: try passphrase.map(RecoveryPassphrase.normalized) ?? "", check: false),
                  let key = wallet.getKey(coin: .stellar, derivationPath: Self.path) else { throw OathWalletError.invalidPhrase }
            bytes = key.data
        }
        guard try StellarSendCrypto.address(privateKey: bytes) == address else { throw StellarSendError.wrongOwner }
        return bytes
    }
    static func phrase(_ text: String, passphrase: String?) throws -> Self {
        guard let phrase = OathMnemonicValidator.bundled?.verifiedPhrase(text),
              let wallet = HDWallet(mnemonic: phrase.phrase, passphrase: try passphrase.map(RecoveryPassphrase.normalized) ?? "", check: false),
              let key = wallet.getKey(coin: .stellar, derivationPath: path) else { throw OathWalletError.invalidPhrase }
        return try .init(address: StellarSendCrypto.address(privateKey: key.data), mnemonic: phrase.phrase,
                         language: phrase.language, passphrase: passphrase)
    }
}
extension BackupWallet.StellarMultisig {
    func policy() throws -> StellarMultisigPolicy {
        guard isValidStructure else { throw OathWalletError.invalidPrivateKey }
        return try .init(account: address, required: required, signers: signers.map(\.address))
    }
    func validateMaterial() throws {
        _ = try policy()
        guard try StellarSendCrypto.address(privateKey: accountKey) == address else { throw StellarSendError.wrongOwner }
        for signer in signers {
            var bytes = try signer.signingKey(); bytes.resetBytes(in: 0..<bytes.count)
        }
    }
    var recoveryText: String {
        // A portable, versioned JSON export avoids ambiguous passphrase whitespace.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return "Oath Stellar multisig v1\nSigner BIP39 derivation: m/44'/148'/0'\n" + String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
}
extension OathWalletEngine {
    static func multisig(_ material: BackupWallet.StellarMultisig, id: UUID = UUID()) throws -> OathWalletSecret {
        try material.validateMaterial()
        return .init(id: id, mnemonic: "", language: "", createdAt: .now, backedUp: false, stellarMultisig: material)
    }
    static func multisigProfile(for secret: OathWalletSecret, material: BackupWallet.StellarMultisig) throws -> OathWalletProfile {
        try material.validateMaterial()
        return .init(id: secret.id, addresses: [.init(chain: .stellar, address: material.address, path: "stellar-multisig-v1")],
                     createdAt: secret.createdAt, backedUp: secret.backedUp)
    }
}
