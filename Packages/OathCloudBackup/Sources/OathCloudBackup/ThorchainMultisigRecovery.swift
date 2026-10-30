import Foundation

extension BackupWallet {
    /// Native Thorchain multisig recovery retains canonical secp256k1 public keys and the threshold.
    public struct ThorchainMultisig: Codable, Equatable, Sendable {
        public let version: Int
        public let required: Int
        public let address: String
        public let signers: [Signer]
        public init(required: Int, address: String, signers: [Signer]) {
            version = 1; self.required = required
            self.address = address; self.signers = signers
        }
        public struct Signer: Codable, Equatable, Sendable {
            public let publicKey: Data
            public let key: Data?
            public let mnemonic: String?
            public let language: String?
            public let passphrase: String?
            public init(publicKey: Data, key: Data? = nil, mnemonic: String? = nil, language: String? = nil, passphrase: String? = nil) {
                self.publicKey = publicKey; self.key = key; self.mnemonic = mnemonic
                self.language = language; self.passphrase = passphrase
            }
            public var isValidStructure: Bool {
                guard publicKey.count == 33 && [2, 3].contains(publicKey.first!) else { return false }
                if let key { return key.count == 32 && mnemonic == nil && language == nil && passphrase == nil }
                guard let mnemonic, !mnemonic.isEmpty, mnemonic.utf8.count < 16_384,
                      let language, !language.isEmpty, language.utf8.count < 64 else { return false }
                return passphrase == nil || (try? RecoveryPassphrase.normalized(passphrase!)) != nil
            }
        }
        public var isValidStructure: Bool {
            version == 1 && address.count == 43 && address.hasPrefix("thor1")
                && (2...7).contains(signers.count) && (1...signers.count).contains(required)
                && signers.allSatisfy(\.isValidStructure)
                && Set(signers.map(\.publicKey)).count == signers.count
        }
        public func hasSameMaterial(as other: Self) -> Bool {
            version == other.version && address == other.address
                && required == other.required && signers.count == other.signers.count
                && signers.allSatisfy { other.signers.contains($0) }
        }
    }
}
