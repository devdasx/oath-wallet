import Foundation

extension BackupWallet {
    /// Recovery of a Safe wallet recovery includes the salt, network, signers and gas executor.
    /// The executor cannot spend Safe funds without the required owner signatures.
    public struct EVMMultisig: Codable, Equatable, Sendable {
        public let network: String
        public let salt: Data
        public let version: Int
        public let required: Int
        public let executorKey: Data
        public let address: String
        public let signers: [Signer]
        public init(network: String, salt: Data, required: Int, executorKey: Data, address: String, signers: [Signer]) {
            self.network = network; self.salt = salt
            version = 1; self.required = required; self.executorKey = executorKey
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
                guard EVMMultisig.validAddress(address) else { return false }
                if let key { return key.count == 32 && mnemonic == nil && language == nil && passphrase == nil }
                guard let mnemonic, !mnemonic.isEmpty, mnemonic.utf8.count < 16_384,
                      let language, !language.isEmpty, language.utf8.count < 64 else { return false }
                return passphrase == nil || (try? RecoveryPassphrase.normalized(passphrase!)) != nil
            }
        }
        public static let networks: Set<String> = ["arc", "ethereum", "arbitrum", "avalanche", "base", "bnb", "fantom", "flare", "somnia", "story", "gnosis", "linea", "optimism", "polygon", "chiliz", "celo", "monad", "unichain", "hyperevm", "robinhood", "scroll", "taiko", "telos", "xlayer"]
        static func validAddress(_ value: String) -> Bool {
            value.count == 42 && value.hasPrefix("0x") && value == value.lowercased()
                && value.dropFirst(2).allSatisfy { $0.isASCII && $0.isHexDigit }
        }
        public var isValidStructure: Bool {
            version == 1 && Self.networks.contains(network) && salt.count == 32 && executorKey.count == 32 && Self.validAddress(address)
                && (2...15).contains(signers.count) && (1...signers.count).contains(required)
                && signers.allSatisfy(\.isValidStructure) && !signers.contains { $0.address == address }
                && Set(signers.map(\.address)).count == signers.count
        }
        public func hasSameMaterial(as other: Self) -> Bool {
            network == other.network && salt == other.salt && version == other.version && address == other.address && executorKey == other.executorKey
                && required == other.required && signers.count == other.signers.count
                && signers.allSatisfy { other.signers.contains($0) }
        }
    }
}
