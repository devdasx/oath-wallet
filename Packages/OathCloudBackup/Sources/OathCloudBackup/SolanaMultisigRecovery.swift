import Foundation

extension BackupWallet {
    /// Recovery of a Solana program vault requires its original account address
    /// as well as the signer set. The creation seed preserves its program address across recovery.
    public struct SolanaMultisig: Codable, Equatable, Sendable {
        public let version: Int
        public let required: Int
        public let createSeed: Data
        public let address: String
        public let signers: [Signer]
        public init(required: Int, createSeed: Data, address: String, signers: [Signer]) {
            version = 1; self.required = required; self.createSeed = createSeed
            self.address = address; self.signers = signers
        }
        public struct Signer: Codable, Equatable, Sendable {
            public let address: String
            public let key: Data?
            public let mnemonic: String?
            public let language: String?
            public let passphrase: String?
            public init(address: String, key: Data? = nil, mnemonic: String? = nil, language: String? = nil, passphrase: String? = nil) {
                self.address = address; self.key = key; self.mnemonic = mnemonic
                self.language = language; self.passphrase = passphrase
            }
            public var isValidStructure: Bool {
                guard (32...44).contains(address.count) else { return false }
                if let key { return key.count == 32 && mnemonic == nil && language == nil && passphrase == nil }
                guard let mnemonic, !mnemonic.isEmpty, mnemonic.utf8.count < 16_384,
                      let language, !language.isEmpty, language.utf8.count < 64 else { return false }
                return passphrase == nil || (try? RecoveryPassphrase.normalized(passphrase!)) != nil
            }
        }
        public var isValidStructure: Bool {
            version == 1 && createSeed.count == 32 && (32...44).contains(address.count)
                && (2...5).contains(signers.count) && (1...signers.count).contains(required)
                && signers.allSatisfy(\.isValidStructure) && !signers.contains { $0.address == address }
                && Set(signers.map(\.address)).count == signers.count
        }
        public func hasSameMaterial(as other: Self) -> Bool {
            version == other.version && address == other.address && createSeed == other.createSeed
                && required == other.required && signers.count == other.signers.count
                && signers.allSatisfy { other.signers.contains($0) }
        }
    }
}
