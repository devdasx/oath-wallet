import Foundation
import WalletCore
import OathAnkr
import OathCloudBackup

extension BackupWallet.EVMMultisig.Signer {
    static let path = "m/44'/60'/0'/0/0"
    func signingKey() throws -> Data {
        guard isValidStructure else { throw OathWalletError.invalidPrivateKey }
        let bytes: Data
        if let key { bytes = key }
        else {
            guard let mnemonic, let language,
                  let checked = OathMnemonicValidator.bundled?.verifiedPhrase(mnemonic), checked.language == language,
                  let wallet = HDWallet(mnemonic: checked.phrase,
                      passphrase: try passphrase.map(RecoveryPassphrase.normalized) ?? "", check: false),
                  let key = wallet.getKey(coin: .ethereum, derivationPath: Self.path) else { throw OathWalletError.invalidPhrase }
            bytes = key.data
        }
        guard try EVMSendCrypto.address(privateKey: bytes) == address else { throw EVMSendError.wrongOwner }
        return bytes
    }
    static func phrase(_ text: String, passphrase: String?) throws -> Self {
        guard let phrase = OathMnemonicValidator.bundled?.verifiedPhrase(text),
              let wallet = HDWallet(mnemonic: phrase.phrase, passphrase: passphrase ?? "", check: false),
              let key = wallet.getKey(coin: .ethereum, derivationPath: path) else { throw OathWalletError.invalidPhrase }
        return try .init(address: EVMSendCrypto.address(privateKey: key.data), mnemonic: phrase.phrase,
                         language: phrase.language, passphrase: passphrase)
    }
}
extension BackupWallet.EVMMultisig {
    func policy() throws -> EVMMultisigPolicy {
        guard isValidStructure else { throw OathWalletError.invalidPrivateKey }
        return try .init(required: required, owners: signers.map(\.address), salt: salt, executor: EVMSendCrypto.address(privateKey: executorKey))
    }
    func validateMaterial() throws {
        guard try policy().address == address else { throw EVMSendError.wrongOwner }
        for signer in signers {
            var bytes = try signer.signingKey(); bytes.resetBytes(in: 0..<bytes.count)
        }
    }
    var recoveryText: String {
        // A portable, versioned JSON export avoids ambiguous passphrase whitespace.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return "Oath EVM Safe 1.4.1 multisig v1\nSigner BIP39 derivation: m/44'/60'/0'/0/0\n" + String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
}
extension OathWalletEngine {
    static func multisig(_ material: BackupWallet.EVMMultisig, id: UUID = UUID()) throws -> OathWalletSecret {
        try material.validateMaterial()
        return .init(id: id, mnemonic: "", language: "", createdAt: .now, backedUp: false, evmMultisig: material)
    }
    static func multisigProfile(for secret: OathWalletSecret, material: BackupWallet.EVMMultisig) throws -> OathWalletProfile {
        try material.validateMaterial()
        guard let chain = OathImportChain(rawValue: material.network), chain.isEVM else { throw OathWalletError.invalidPrivateKey }
        return .init(id: secret.id, addresses: [.init(chain: chain, address: material.address, path: "evm-multisig-v1")],
                     createdAt: secret.createdAt, backedUp: secret.backedUp)
    }
}
