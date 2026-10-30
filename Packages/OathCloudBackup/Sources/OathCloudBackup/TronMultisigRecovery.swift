import Foundation

extension BackupWallet {
    /// Recovery of a TRON permission wallet requires its original account address
    /// as well as the signer set. The bootstrap key is useful only before setup.
    public struct TronMultisig: Codable, Equatable, Sendable {
        public let version: Int
        public let required: Int
        public let accountKey: Data
        public let address: String
        public let signers: [Signer]
        public init(required: Int, accountKey: Data, address: String, signers: [Signer]) {
            version = 1; self.required = required; self.accountKey = accountKey
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
                guard address.count == 34 else { return false }
                if let key { return key.count == 32 && mnemonic == nil && language == nil && passphrase == nil }
                guard let mnemonic, !mnemonic.isEmpty, mnemonic.utf8.count < 16_384,
                      let language, !language.isEmpty, language.utf8.count < 64 else { return false }
                return passphrase == nil || (try? RecoveryPassphrase.normalized(passphrase!)) != nil
            }
        }
        public var isValidStructure: Bool {
            version == 1 && accountKey.count == 32 && address.count == 34
                && (2...5).contains(signers.count) && (1...signers.count).contains(required)
                && signers.allSatisfy(\.isValidStructure) && !signers.contains { $0.address == address }
                && Set(signers.map(\.address)).count == signers.count
        }
        public func hasSameMaterial(as other: Self) -> Bool {
            version == other.version && address == other.address && accountKey == other.accountKey
                && required == other.required && signers.count == other.signers.count
                && signers.allSatisfy { other.signers.contains($0) }
        }
    }
}
