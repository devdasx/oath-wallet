import Foundation

extension BackupWallet {
    /// Secret recovery document. Policy is deliberately versioned and immutable.
    /// The application validates cryptographic material before committing a restore.
    public struct BitcoinMultisig: Codable, Equatable, Sendable {
        public let version: Int
        /// Missing in v1 Bitcoin backups. v2 binds Litecoin; v3 binds Bitcoin Cash P2SH; v4 binds Dogecoin P2SH.
        public let network: String?
        public var chainID: String { network ?? "bitcoin" }
        public var accountPath: String { chainID == "dogecoin" ? "m/48'/3'/0'/0'" : chainID == "bitcoincash" ? "m/48'/145'/0'/0'" : chainID == "litecoin" ? "m/48'/2'/0'/2'" : "m/48'/0'/0'/2'" }
        public let required: Int
        public let signers: [Signer]
        public init(required: Int, signers: [Signer], network: String? = nil) {
            version = network == "dogecoin" ? 4 : network == "bitcoincash" ? 3 : network == nil ? 1 : 2; self.network = network; self.required = required; self.signers = signers
        }
        public struct Signer: Codable, Equatable, Sendable {
            public let wif: String?
            public let mnemonic: String?
            public let language: String?
            public let passphrase: String?
            public init(wif: String? = nil, mnemonic: String? = nil, language: String? = nil, passphrase: String? = nil) {
                self.wif = wif; self.mnemonic = mnemonic; self.language = language; self.passphrase = passphrase
            }
            public var isValidStructure: Bool {
                if let wif {
                    return wif.utf8.count == 52 && mnemonic == nil && language == nil && passphrase == nil
                }
                guard let mnemonic, !mnemonic.isEmpty, mnemonic.utf8.count < 16_384,
                      let language, !language.isEmpty, language.utf8.count < 64 else { return false }
                return passphrase == nil || (try? RecoveryPassphrase.normalized(passphrase!)) != nil
            }
        }
        /// sortedmulti is independent of the order in which signers were entered.
        public func hasSameMaterial(as other: Self) -> Bool {
            chainID == other.chainID && required == other.required && signers.count == other.signers.count
                && signers.allSatisfy { other.signers.contains($0) }
        }
        public var isValidStructure: Bool {
            ((version == 1 && network == nil) || (version == 2 && network == "litecoin") || (version == 3 && network == "bitcoincash") || (version == 4 && network == "dogecoin")) && (2...15).contains(signers.count) && (1...signers.count).contains(required)
                && signers.allSatisfy(\.isValidStructure)
        }
    }
}
