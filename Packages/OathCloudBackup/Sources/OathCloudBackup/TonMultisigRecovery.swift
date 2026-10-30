import Foundation

extension BackupWallet {
    /// GRAM multisig recovery retains canonical Ed25519 public keys and the threshold.
    public struct TonMultisig: Codable, Equatable, Sendable {
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
                guard publicKey.count == 32 else { return false }
                if let key { return key.count == 32 && mnemonic == nil && language == nil && passphrase == nil }
                guard let mnemonic, !mnemonic.isEmpty, mnemonic.utf8.count < 16_384,
                      let language, !language.isEmpty, language.utf8.count < 64 else { return false }
                return passphrase == nil || (try? RecoveryPassphrase.normalized(passphrase!)) != nil
            }
        }
        public var isValidStructure: Bool {
            version == 1 && address.count == 66 && address.hasPrefix("0:") && address.dropFirst(2).allSatisfy { $0.isHexDigit && !$0.isUppercase }
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
