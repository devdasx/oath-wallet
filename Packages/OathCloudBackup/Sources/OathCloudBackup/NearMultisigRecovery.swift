import Foundation

extension BackupWallet {
    /// NEAR contract multisig recovery retains canonical Ed25519 public keys and the threshold.
    public struct NearMultisig: Codable, Equatable, Sendable {
        public let version: Int
        public let bootstrapSeed: Data
        public let required: Int
        public let address: String
        public let signers: [Signer]
        public init(bootstrapSeed: Data, required: Int, address: String, signers: [Signer]) {
            version = 1; self.bootstrapSeed = bootstrapSeed; self.required = required
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
                guard publicKey.count == 32 else { return false }
                if let key { return key.count == 32 && mnemonic == nil && language == nil && passphrase == nil }
                guard let mnemonic, !mnemonic.isEmpty, mnemonic.utf8.count < 16_384,
                      let language, !language.isEmpty, language.utf8.count < 64 else { return false }
                return passphrase == nil || (try? RecoveryPassphrase.normalized(passphrase!)) != nil
            }
        }
        public var isValidStructure: Bool {
            version == 1 && address.count == 64 && address.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } && bootstrapSeed.count == 32
                && (2...10).contains(signers.count) && (1...signers.count).contains(required)
                && signers.allSatisfy(\.isValidStructure)
                && Set(signers.map(\.publicKey)).count == signers.count
        }
        public func hasSameMaterial(as other: Self) -> Bool {
            bootstrapSeed == other.bootstrapSeed && version == other.version && address == other.address
                && required == other.required && signers.count == other.signers.count
                && signers.allSatisfy { other.signers.contains($0) }
        }
    }
}
