import Foundation
import WalletCore
import OathAnkr
import OathCloudBackup

extension BackupWallet.XrplMultisig.Signer {
    static let path = "m/44'/144'/0'/0/0"
    func signingKey() throws -> Data {
        guard isValidStructure else { throw OathWalletError.invalidPrivateKey }
        let bytes: Data
        if let key { bytes = key }
        else {
            guard let mnemonic, let language,
                  let checked = OathMnemonicValidator.bundled?.verifiedPhrase(mnemonic), checked.language == language,
                  let wallet = HDWallet(mnemonic: checked.phrase,
                      passphrase: try passphrase.map(RecoveryPassphrase.normalized) ?? "", check: false),
                  let key = wallet.getKey(coin: .xrp, derivationPath: Self.path) else { throw OathWalletError.invalidPhrase }
            bytes = key.data
        }
        guard try XrplSendCrypto.address(privateKey: bytes) == address else { throw XrplSendError.wrongOwner }
        return bytes
    }
    static func phrase(_ text: String, passphrase: String?) throws -> Self {
        guard let phrase = OathMnemonicValidator.bundled?.verifiedPhrase(text),
              let wallet = HDWallet(mnemonic: phrase.phrase, passphrase: try passphrase.map(RecoveryPassphrase.normalized) ?? "", check: false),
              let key = wallet.getKey(coin: .xrp, derivationPath: path) else { throw OathWalletError.invalidPhrase }
        return try .init(address: XrplSendCrypto.address(privateKey: key.data), mnemonic: phrase.phrase,
                         language: phrase.language, passphrase: passphrase)
    }
}
extension BackupWallet.XrplMultisig {
    func policy() throws -> XrplMultisigPolicy {
        guard isValidStructure else { throw OathWalletError.invalidPrivateKey }
        return try .init(account: address, required: required, signers: signers.map(\.address))
    }
    func validateMaterial() throws {
        _ = try policy()
        guard try XrplSendCrypto.address(privateKey: accountKey) == address else { throw XrplSendError.wrongOwner }
        for signer in signers {
            var bytes = try signer.signingKey(); bytes.resetBytes(in: 0..<bytes.count)
        }
    }
    var recoveryText: String {
        // A portable, versioned JSON export avoids ambiguous passphrase whitespace.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return "Oath XRP multisig v1\nSigner BIP39 derivation: m/44'/144'/0'/0/0\n" + String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
}
extension OathWalletEngine {
    static func multisig(_ material: BackupWallet.XrplMultisig, id: UUID = UUID()) throws -> OathWalletSecret {
        try material.validateMaterial()
        return .init(id: id, mnemonic: "", language: "", createdAt: .now, backedUp: false, xrplMultisig: material)
    }
    static func multisigProfile(for secret: OathWalletSecret, material: BackupWallet.XrplMultisig) throws -> OathWalletProfile {
        try material.validateMaterial()
        return .init(id: secret.id, addresses: [.init(chain: .xrpl, address: material.address, path: "xrpl-multisig-v1")],
                     createdAt: secret.createdAt, backedUp: secret.backedUp)
    }
}
