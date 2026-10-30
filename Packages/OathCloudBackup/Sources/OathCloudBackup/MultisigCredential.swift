import Foundation

/// Shared, versioned recovery document inside the existing authenticated ciphertext.
/// Never store this document in public metadata, logs, or diagnostics.
public struct MultisigCredential: Codable, Equatable, Sendable {
    public enum Material: Equatable, Sendable {
        case bitcoin(BackupWallet.BitcoinMultisig)
        case tron(BackupWallet.TronMultisig)
        case solana(BackupWallet.SolanaMultisig)
        case xrpl(BackupWallet.XrplMultisig)
        case stellar(BackupWallet.StellarMultisig)
        case aptos(BackupWallet.AptosMultisig)
        case sui(BackupWallet.SuiMultisig)
        case near(BackupWallet.NearMultisig)
        case evm(BackupWallet.EVMMultisig)
        case ton(BackupWallet.TonMultisig)
        case thorchain(BackupWallet.ThorchainMultisig)
    }
    public let material: Material
    public init(_ material: Material) throws {
        self.material = material
        guard isValid else { throw CloudBackupError.invalidDocument }
    }
    public var isValid: Bool {
        switch material {
        case .bitcoin(let value): value.isValidStructure
        case .tron(let value): value.isValidStructure
        case .solana(let value): value.isValidStructure
        case .xrpl(let value): value.isValidStructure
        case .stellar(let value): value.isValidStructure
        case .aptos(let value): value.isValidStructure
        case .sui(let value): value.isValidStructure
        case .near(let value): value.isValidStructure
        case .evm(let value): value.isValidStructure
        case .ton(let value): value.isValidStructure
        case .thorchain(let value): value.isValidStructure
        }
    }
    public var network: String {
        switch material {
        case .bitcoin(let value): value.chainID
        case .tron: "tron"
        case .solana: "solana"
        case .xrpl: "xrpl"
        case .stellar: "stellar"
        case .aptos: "aptos"
        case .sui: "sui"
        case .near: "near"
        case .evm(let value): value.network
        case .ton: "ton"
        case .thorchain: "thorchain"
        }
    }
    public var required: Int {
        switch material {
        case .bitcoin(let value): value.required
        case .tron(let value): value.required
        case .solana(let value): value.required
        case .xrpl(let value): value.required
        case .stellar(let value): value.required
        case .aptos(let value): value.required
        case .sui(let value): value.required
        case .near(let value): value.required
        case .evm(let value): value.required
        case .ton(let value): value.required
        case .thorchain(let value): value.required
        }
    }
    /// Original participant order is preserved: some chains bind order into the address.
    /// Display sorting must never rewrite this recovery document.
    public struct Signer: Equatable, Sendable {
        public let number: Int
        public let publicIdentity: String?
        public let mnemonic: String?
        public let language: String?
        public let passphrase: String?
        public let keyHex: String?
        public let wif: String?
    }
    public var signers: [Signer] {
        switch material {
        case .bitcoin(let value): value.signers.enumerated().map { v in
            Signer(number: v.offset + 1, publicIdentity: nil, mnemonic: v.element.mnemonic,
                language: v.element.language, passphrase: v.element.passphrase, keyHex: nil, wif: v.element.wif)
        }
        case .tron(let value): value.signers.enumerated().map { v in
            Signer(number: v.offset + 1, publicIdentity: v.element.address, mnemonic: v.element.mnemonic,
                language: v.element.language, passphrase: v.element.passphrase, keyHex: v.element.key.map(Self.hex), wif: nil)
        }
        case .solana(let value): value.signers.enumerated().map { v in
            Signer(number: v.offset + 1, publicIdentity: v.element.address, mnemonic: v.element.mnemonic,
                language: v.element.language, passphrase: v.element.passphrase, keyHex: v.element.key.map(Self.hex), wif: nil)
        }
        case .xrpl(let value): value.signers.enumerated().map { v in
            Signer(number: v.offset + 1, publicIdentity: v.element.address, mnemonic: v.element.mnemonic,
                language: v.element.language, passphrase: v.element.passphrase, keyHex: v.element.key.map(Self.hex), wif: nil)
        }
        case .stellar(let value): value.signers.enumerated().map { v in
            Signer(number: v.offset + 1, publicIdentity: v.element.address, mnemonic: v.element.mnemonic,
                language: v.element.language, passphrase: v.element.passphrase, keyHex: v.element.key.map(Self.hex), wif: nil)
        }
        case .aptos(let value): value.signers.enumerated().map { v in
            Signer(number: v.offset + 1, publicIdentity: Self.hex(v.element.publicKey), mnemonic: v.element.mnemonic,
                language: v.element.language, passphrase: v.element.passphrase, keyHex: v.element.key.map(Self.hex), wif: nil)
        }
        case .sui(let value): value.signers.enumerated().map { v in
            Signer(number: v.offset + 1, publicIdentity: Self.hex(v.element.publicKey), mnemonic: v.element.mnemonic,
                language: v.element.language, passphrase: v.element.passphrase, keyHex: v.element.key.map(Self.hex), wif: nil)
        }
        case .near(let value): value.signers.enumerated().map { v in
            Signer(number: v.offset + 1, publicIdentity: Self.hex(v.element.publicKey), mnemonic: v.element.mnemonic,
                language: v.element.language, passphrase: v.element.passphrase, keyHex: v.element.key.map(Self.hex), wif: nil)
        }
        case .evm(let value): value.signers.enumerated().map { v in
            Signer(number: v.offset + 1, publicIdentity: v.element.address, mnemonic: v.element.mnemonic,
                language: v.element.language, passphrase: v.element.passphrase, keyHex: v.element.key.map(Self.hex), wif: nil)
        }
        case .ton(let value): value.signers.enumerated().map { v in
            Signer(number: v.offset + 1, publicIdentity: Self.hex(v.element.publicKey), mnemonic: v.element.mnemonic,
                language: v.element.language, passphrase: v.element.passphrase, keyHex: v.element.key.map(Self.hex), wif: nil)
        }
        case .thorchain(let value): value.signers.enumerated().map { v in
            Signer(number: v.offset + 1, publicIdentity: Self.hex(v.element.publicKey), mnemonic: v.element.mnemonic,
                language: v.element.language, passphrase: v.element.passphrase, keyHex: v.element.key.map(Self.hex), wif: nil)
        }
        }
    }
    public struct RecoveryField: Equatable, Sendable {
        public let name: String
        public let value: String
    }
    /// Non-signer recovery material is equally important and remains encrypted.
    public var recoveryFields: [RecoveryField] {
        switch material {
        case .bitcoin(let v): [.init(name: "derivation", value: v.accountPath),
            .init(name: "policy", value: ["bitcoincash", "dogecoin"].contains(v.chainID) ? "sh(sortedmulti)" : "wsh(sortedmulti)")]
        case .tron(let v): [.init(name: "accountKey", value: Self.hex(v.accountKey))]
        case .xrpl(let v): [.init(name: "accountKey", value: Self.hex(v.accountKey))]
        case .stellar(let v): [.init(name: "accountKey", value: Self.hex(v.accountKey))]
        case .solana(let v): [.init(name: "createSeed", value: Self.hex(v.createSeed))]
        case .near(let v): [.init(name: "bootstrapSeed", value: Self.hex(v.bootstrapSeed))]
        case .evm(let v): [.init(name: "executorKey", value: Self.hex(v.executorKey)), .init(name: "salt", value: Self.hex(v.salt))]
        default: []
        }
    }
    private static func hex(_ value: Data) -> String { value.map { String(format: "%02x", $0) }.joined() }
    private enum CodingKeys: String, CodingKey { case format, version, type, material }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .format) == "oath.wallet.multisig-credential",
              try c.decode(Int.self, forKey: .version) == 1 else { throw CloudBackupError.invalidDocument }
        switch try c.decode(String.self, forKey: .type) {
        case "bitcoin": material = .bitcoin(try c.decode(BackupWallet.BitcoinMultisig.self, forKey: .material))
        case "tron": material = .tron(try c.decode(BackupWallet.TronMultisig.self, forKey: .material))
        case "solana": material = .solana(try c.decode(BackupWallet.SolanaMultisig.self, forKey: .material))
        case "xrpl": material = .xrpl(try c.decode(BackupWallet.XrplMultisig.self, forKey: .material))
        case "stellar": material = .stellar(try c.decode(BackupWallet.StellarMultisig.self, forKey: .material))
        case "aptos": material = .aptos(try c.decode(BackupWallet.AptosMultisig.self, forKey: .material))
        case "sui": material = .sui(try c.decode(BackupWallet.SuiMultisig.self, forKey: .material))
        case "near": material = .near(try c.decode(BackupWallet.NearMultisig.self, forKey: .material))
        case "evm": material = .evm(try c.decode(BackupWallet.EVMMultisig.self, forKey: .material))
        case "ton": material = .ton(try c.decode(BackupWallet.TonMultisig.self, forKey: .material))
        case "thorchain": material = .thorchain(try c.decode(BackupWallet.ThorchainMultisig.self, forKey: .material))
        default: throw CloudBackupError.invalidDocument
        }
        guard isValid else { throw CloudBackupError.invalidDocument }
    }
    public func encode(to encoder: Encoder) throws {
        guard isValid else { throw CloudBackupError.invalidDocument }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("oath.wallet.multisig-credential", forKey: .format)
        try c.encode(1, forKey: .version)
        switch material {
        case .bitcoin(let value): try c.encode("bitcoin", forKey: .type); try c.encode(value, forKey: .material)
        case .tron(let value): try c.encode("tron", forKey: .type); try c.encode(value, forKey: .material)
        case .solana(let value): try c.encode("solana", forKey: .type); try c.encode(value, forKey: .material)
        case .xrpl(let value): try c.encode("xrpl", forKey: .type); try c.encode(value, forKey: .material)
        case .stellar(let value): try c.encode("stellar", forKey: .type); try c.encode(value, forKey: .material)
        case .aptos(let value): try c.encode("aptos", forKey: .type); try c.encode(value, forKey: .material)
        case .sui(let value): try c.encode("sui", forKey: .type); try c.encode(value, forKey: .material)
        case .near(let value): try c.encode("near", forKey: .type); try c.encode(value, forKey: .material)
        case .evm(let value): try c.encode("evm", forKey: .type); try c.encode(value, forKey: .material)
        case .ton(let value): try c.encode("ton", forKey: .type); try c.encode(value, forKey: .material)
        case .thorchain(let value): try c.encode("thorchain", forKey: .type); try c.encode(value, forKey: .material)
        }
    }
}
