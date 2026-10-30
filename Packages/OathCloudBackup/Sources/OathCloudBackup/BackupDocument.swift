import OathDiagnostics
import Foundation
import CryptoKit
import CommonCrypto
import Security

public enum CloudBackupError: Error, Equatable, Sendable {
    case passwordTooShort, passwordTooLong, invalidDocument, authenticationFailed
    case unavailable, accountChanged, fileConflict, uploadFailed, quotaExceeded
}

/// Portable recovery material. This value must never be logged or persisted
/// unencrypted. The app's six-digit PIN and installation key are not exported.
public struct BackupWallet: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let mnemonic: String
    public let language: String
    public let createdAt: Date
    public let accounts: [Account]
    /// Optional for backups made before wallet artwork could be customized.
    /// Nil preserves Oath's original palette instead of inventing a new color.
    public let colorHex: String?
    public let bitcoinMultisig: BitcoinMultisig?
    public let evmMultisig: EVMMultisig?
    public let tonMultisig: TonMultisig?
    public let thorchainMultisig: ThorchainMultisig?
    public let nearMultisig: NearMultisig?
    public let suiMultisig: SuiMultisig?
    public let aptosMultisig: AptosMultisig?
    public let stellarMultisig: StellarMultisig?
    public let xrplMultisig: XrplMultisig?
    public let solanaMultisig: SolanaMultisig?
    public let tronMultisig: TronMultisig?
    public let privateKey: ImportedPrivateKey?
    public let passphrase: String?
    /// Version 7 retains input accepted by the previous app, without widening
    /// the new-wallet input policy. Never infer this from a mnemonic alone.
    public let legacyPassphrase: Bool?
    /// Optional presentation provenance; not required to recover this wallet.
    public let parentWalletID: UUID?

    public struct ImportedPrivateKey: Codable, Sendable, Equatable {
        public let bytes: Data
        public let networks: [String]
        public let compressed: Bool?
        public let bitcoinExtendedKey: String?
        public let dogecoinExtendedKey: String?
        public let litecoinExtendedKey: String?
        public let bitcoinCashExtendedKey: String?
        public var requiresBitcoinCashV2: Bool { networks == ["bitcoincash"] && (compressed == false || bitcoinCashExtendedKey != nil) }
        public var requiresLitecoinV2: Bool { networks == ["litecoin"] && (compressed == false || litecoinExtendedKey != nil) }
        public var requiresBitcoinV2: Bool { networks == ["bitcoin"] && (compressed == false || bitcoinExtendedKey != nil) }
        public var requiresDogecoinV2: Bool { networks == ["dogecoin"] && (compressed == false || dogecoinExtendedKey != nil) }
        public init(bytes: Data, networks: [String], compressed: Bool? = nil, bitcoinExtendedKey: String? = nil, dogecoinExtendedKey: String? = nil, litecoinExtendedKey: String? = nil, bitcoinCashExtendedKey: String? = nil) {
            self.bytes = bytes; self.networks = networks; self.compressed = compressed; self.bitcoinExtendedKey = bitcoinExtendedKey; self.dogecoinExtendedKey = dogecoinExtendedKey; self.litecoinExtendedKey = litecoinExtendedKey; self.bitcoinCashExtendedKey = bitcoinCashExtendedKey
        }
    }

    public struct Account: Codable, Sendable, Equatable {
        public let network: String
        public let derivationPath: String
        public let index: Int
        /// A receive preference, not a replacement for the original account.
        /// Older backups omit this and open with the app's default.
        public let solanaReceivePath: String?
        public init(network: String, derivationPath: String, index: Int, solanaReceivePath: String? = nil) {
            self.network = network; self.derivationPath = derivationPath; self.index = index
            self.solanaReceivePath = solanaReceivePath
        }
    }

    public init(id: UUID, name: String, mnemonic: String, language: String,
                createdAt: Date, accounts: [Account], colorHex: String? = nil, privateKey: ImportedPrivateKey? = nil,
                passphrase: String? = nil, legacyPassphrase: Bool? = nil, parentWalletID: UUID? = nil, bitcoinMultisig: BitcoinMultisig? = nil, tronMultisig: TronMultisig? = nil, solanaMultisig: SolanaMultisig? = nil, xrplMultisig: XrplMultisig? = nil, stellarMultisig: StellarMultisig? = nil, aptosMultisig: AptosMultisig? = nil, suiMultisig: SuiMultisig? = nil, nearMultisig: NearMultisig? = nil, evmMultisig: EVMMultisig? = nil, tonMultisig: TonMultisig? = nil, thorchainMultisig: ThorchainMultisig? = nil) {
        self.id = id; self.name = name; self.mnemonic = mnemonic
        self.language = language; self.createdAt = createdAt; self.accounts = accounts
        self.colorHex = colorHex
        self.evmMultisig = evmMultisig
        self.tonMultisig = tonMultisig
        self.thorchainMultisig = thorchainMultisig
        self.nearMultisig = nearMultisig
        self.suiMultisig = suiMultisig
        self.aptosMultisig = aptosMultisig
        self.stellarMultisig = stellarMultisig
        self.xrplMultisig = xrplMultisig; self.solanaMultisig = solanaMultisig; self.bitcoinMultisig = bitcoinMultisig; self.tronMultisig = tronMultisig
        self.privateKey = privateKey
        self.passphrase = passphrase
        self.legacyPassphrase = legacyPassphrase
        self.parentWalletID = parentWalletID
    }
}

/// Version 1: UTF-8 JSON; AES-256-GCM combined nonce/ciphertext/tag; PBKDF2
/// HMAC-SHA256, 600,000 rounds, random 32-byte salt. All header fields are AAD.
/// Version 2 uses the same encryption and additionally requires BIP-39
/// passphrase support. Older readers reject it instead of restoring wrong keys.
/// Fixed, bounded parameters are checked BEFORE deriving a key on restore.
public enum BackupDocument {
    public static let fileExtension = "oathbackup"
    public static let maximumBytes = 1_048_576
    private static let iterations: UInt32 = 600_000

    struct Header: Codable, Sendable {
        var format = "org.oathwallet.encrypted-wallet"
        var version = 1
        var cipher = "AES-256-GCM"
        var kdf = "PBKDF2-HMAC-SHA256"
        var passwordNormalization = "NFC"
        var rounds = BackupDocument.iterations
        var salt: Data
    }
    struct Envelope: Codable { var header: Header; var sealed: Data }

    public static func validate(password: String) throws {
        guard password.count >= 8 else { throw CloudBackupError.passwordTooShort }
        guard password.utf8.count <= 1_024 else { throw CloudBackupError.passwordTooLong }
    }

    public static func seal(_ wallet: BackupWallet, password: String) throws -> Data {
        try validate(password: password)
        try validate(wallet: wallet)
        var salt = Data(count: 32)
        let result = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard result == errSecSuccess else { throw CloudBackupError.unavailable }
        // Version 2 requires passphrase support. Version 1 readers must fail
        // closed instead of restoring these words as the empty-passphrase wallet.
        let header = Header(version: wallet.evmMultisig != nil ? 21 : wallet.bitcoinMultisig?.chainID == "dogecoin" ? 20 : wallet.bitcoinMultisig?.chainID == "bitcoincash" ? 19 : wallet.bitcoinMultisig?.chainID == "litecoin" ? 18 : wallet.tonMultisig != nil ? 17 : wallet.thorchainMultisig != nil ? 16 : wallet.nearMultisig != nil ? 15 : wallet.suiMultisig != nil ? 14 : wallet.aptosMultisig != nil ? 13 : wallet.stellarMultisig != nil ? 12 : wallet.xrplMultisig != nil ? 11 : wallet.solanaMultisig != nil ? 10 : wallet.tronMultisig != nil ? 9 : wallet.bitcoinMultisig != nil ? 8 : wallet.legacyPassphrase == true ? 7 : wallet.privateKey?.requiresBitcoinCashV2 == true ? 6 : wallet.privateKey?.requiresLitecoinV2 == true ? 5 : wallet.privateKey?.requiresDogecoinV2 == true ? 4 : wallet.privateKey?.requiresBitcoinV2 == true ? 3 : (wallet.passphrase == nil ? 1 : 2), salt: salt)
        let key = try derive(password, salt: salt)
        var plaintext = try encoder().encode(wallet)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        guard plaintext.count < maximumBytes / 2 else { throw CloudBackupError.invalidDocument }
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: encoder().encode(header))
        guard let combined = box.combined else { throw CloudBackupError.invalidDocument }
        return try encoder().encode(Envelope(header: header, sealed: combined))
    }

    public static func open(_ data: Data, password: String) throws -> BackupWallet {
        try validate(password: password)
        guard data.count <= maximumBytes else { throw CloudBackupError.invalidDocument }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { OathDiagnostics.record(error); throw CloudBackupError.invalidDocument }
        let h = envelope.header
        guard h.format == "org.oathwallet.encrypted-wallet", (1...21).contains(h.version),
              h.cipher == "AES-256-GCM", h.kdf == "PBKDF2-HMAC-SHA256",
              h.passwordNormalization == "NFC",
              h.rounds == iterations, h.salt.count == 32, envelope.sealed.count >= 28 else {
            throw CloudBackupError.invalidDocument
        }
        let key = try derive(password, salt: h.salt)
        var plaintext: Data
        do {
            plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed),
                                         using: key, authenticating: encoder().encode(h))
        } catch { OathDiagnostics.record(error); throw CloudBackupError.authenticationFailed }
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let wallet: BackupWallet
        do { wallet = try JSONDecoder().decode(BackupWallet.self, from: plaintext) }
        catch { OathDiagnostics.record(error); throw CloudBackupError.invalidDocument }
        try validate(wallet: wallet)
        guard h.version >= 21 || wallet.evmMultisig == nil else { throw CloudBackupError.invalidDocument }
        guard h.version >= 20 || wallet.bitcoinMultisig?.chainID != "dogecoin" else { throw CloudBackupError.invalidDocument }
        guard h.version >= 19 || wallet.bitcoinMultisig?.chainID != "bitcoincash" else { throw CloudBackupError.invalidDocument }
        guard h.version >= 18 || wallet.bitcoinMultisig?.chainID != "litecoin" else { throw CloudBackupError.invalidDocument }
        guard h.version >= 17 || wallet.tonMultisig == nil else { throw CloudBackupError.invalidDocument }
        guard h.version >= 16 || wallet.thorchainMultisig == nil else { throw CloudBackupError.invalidDocument }
        guard h.version >= 15 || wallet.nearMultisig == nil else { throw CloudBackupError.invalidDocument }
        guard h.version >= 14 || wallet.suiMultisig == nil else { throw CloudBackupError.invalidDocument }
        guard h.version >= 13 || wallet.aptosMultisig == nil else { throw CloudBackupError.invalidDocument }
        guard h.version >= 12 || wallet.stellarMultisig == nil else { throw CloudBackupError.invalidDocument }
        guard h.version >= 11 || wallet.xrplMultisig == nil else { throw CloudBackupError.invalidDocument }
        guard h.version >= 10 || wallet.solanaMultisig == nil else { throw CloudBackupError.invalidDocument }
        guard h.version >= 9 || wallet.tronMultisig == nil else { throw CloudBackupError.invalidDocument }
        guard h.version >= 8 || wallet.bitcoinMultisig == nil else { throw CloudBackupError.invalidDocument }
        guard h.version >= 7 || wallet.legacyPassphrase != true else { throw CloudBackupError.invalidDocument }
        guard h.version >= 2 || wallet.passphrase == nil else { throw CloudBackupError.invalidDocument }
        guard h.version >= 3 || wallet.privateKey?.requiresBitcoinV2 != true else { throw CloudBackupError.invalidDocument }
        guard h.version >= 6 || wallet.privateKey?.requiresBitcoinCashV2 != true else { throw CloudBackupError.invalidDocument }
        guard h.version >= 5 || wallet.privateKey?.requiresLitecoinV2 != true else { throw CloudBackupError.invalidDocument }
        guard h.version >= 4 || wallet.privateKey?.requiresDogecoinV2 != true else { throw CloudBackupError.invalidDocument }
        return wallet
    }

    private static func validate(wallet: BackupWallet) throws {
        guard wallet.accounts.allSatisfy({ account in
            guard let path = account.solanaReceivePath else { return true }
            return wallet.privateKey == nil && account.network == "solana" && !path.isEmpty && path.utf8.count <= 128
        }) else { throw CloudBackupError.invalidDocument }
        if wallet.legacyPassphrase == true {
            guard wallet.privateKey == nil, let passphrase = wallet.passphrase,
                  (try? RecoveryPassphrase.normalizedLegacy(passphrase)) != nil else { throw CloudBackupError.invalidDocument }
        } else if let passphrase = wallet.passphrase {
            guard (try? RecoveryPassphrase.normalized(passphrase)) != nil else { throw CloudBackupError.invalidDocument }
        }
        if let color = wallet.colorHex {
            guard color.utf8.count == 6,
                  color.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else {
                throw CloudBackupError.invalidDocument
            }
        }
        if let multisig = wallet.evmMultisig {
            guard multisig.isValidStructure, wallet.tonMultisig == nil, wallet.thorchainMultisig == nil, wallet.bitcoinMultisig == nil, wallet.tronMultisig == nil, wallet.solanaMultisig == nil, wallet.xrplMultisig == nil, wallet.stellarMultisig == nil, wallet.suiMultisig == nil, wallet.aptosMultisig == nil, wallet.nearMultisig == nil,
                  wallet.mnemonic.isEmpty, wallet.language.isEmpty, wallet.privateKey == nil,
                  wallet.passphrase == nil, wallet.legacyPassphrase == nil,
                  wallet.accounts.count == 1, wallet.accounts[0].network == multisig.network,
                  wallet.accounts[0].index == 0, wallet.accounts[0].derivationPath == "evm-multisig-v1" else {
                throw CloudBackupError.invalidDocument
            }
        } else if let multisig = wallet.tonMultisig {
            guard multisig.isValidStructure, wallet.thorchainMultisig == nil, wallet.bitcoinMultisig == nil, wallet.tronMultisig == nil, wallet.solanaMultisig == nil, wallet.xrplMultisig == nil, wallet.stellarMultisig == nil, wallet.suiMultisig == nil, wallet.aptosMultisig == nil, wallet.nearMultisig == nil,
                  wallet.mnemonic.isEmpty, wallet.language.isEmpty, wallet.privateKey == nil,
                  wallet.passphrase == nil, wallet.legacyPassphrase == nil,
                  wallet.accounts.count == 1, wallet.accounts[0].network == "ton",
                  wallet.accounts[0].index == 0, wallet.accounts[0].derivationPath == "ton-multisig-v1" else {
                throw CloudBackupError.invalidDocument
            }
        } else if let multisig = wallet.thorchainMultisig {
            guard multisig.isValidStructure, wallet.bitcoinMultisig == nil, wallet.tronMultisig == nil, wallet.solanaMultisig == nil, wallet.xrplMultisig == nil, wallet.stellarMultisig == nil, wallet.suiMultisig == nil, wallet.aptosMultisig == nil, wallet.nearMultisig == nil,
                  wallet.mnemonic.isEmpty, wallet.language.isEmpty, wallet.privateKey == nil,
                  wallet.passphrase == nil, wallet.legacyPassphrase == nil,
                  wallet.accounts.count == 1, wallet.accounts[0].network == "thorchain",
                  wallet.accounts[0].index == 0, wallet.accounts[0].derivationPath == "thorchain-multisig-v1" else {
                throw CloudBackupError.invalidDocument
            }
        } else if let multisig = wallet.nearMultisig {
            guard multisig.isValidStructure, wallet.bitcoinMultisig == nil, wallet.tronMultisig == nil, wallet.solanaMultisig == nil, wallet.xrplMultisig == nil, wallet.stellarMultisig == nil, wallet.suiMultisig == nil, wallet.aptosMultisig == nil,
                  wallet.mnemonic.isEmpty, wallet.language.isEmpty, wallet.privateKey == nil,
                  wallet.passphrase == nil, wallet.legacyPassphrase == nil,
                  wallet.accounts.count == 1, wallet.accounts[0].network == "near",
                  wallet.accounts[0].index == 0, wallet.accounts[0].derivationPath == "near-multisig-v1" else {
                throw CloudBackupError.invalidDocument
            }
        } else if let multisig = wallet.suiMultisig {
            guard multisig.isValidStructure, wallet.bitcoinMultisig == nil, wallet.tronMultisig == nil, wallet.solanaMultisig == nil, wallet.xrplMultisig == nil, wallet.stellarMultisig == nil, wallet.aptosMultisig == nil,
                  wallet.mnemonic.isEmpty, wallet.language.isEmpty, wallet.privateKey == nil,
                  wallet.passphrase == nil, wallet.legacyPassphrase == nil,
                  wallet.accounts.count == 1, wallet.accounts[0].network == "sui",
                  wallet.accounts[0].index == 0, wallet.accounts[0].derivationPath == "sui-multisig-v1" else {
                throw CloudBackupError.invalidDocument
            }
        } else if let multisig = wallet.aptosMultisig {
            guard multisig.isValidStructure, wallet.bitcoinMultisig == nil, wallet.tronMultisig == nil, wallet.solanaMultisig == nil, wallet.xrplMultisig == nil, wallet.stellarMultisig == nil,
                  wallet.mnemonic.isEmpty, wallet.language.isEmpty, wallet.privateKey == nil,
                  wallet.passphrase == nil, wallet.legacyPassphrase == nil,
                  wallet.accounts.count == 1, wallet.accounts[0].network == "aptos",
                  wallet.accounts[0].index == 0, wallet.accounts[0].derivationPath == "aptos-multisig-v1" else {
                throw CloudBackupError.invalidDocument
            }
        } else if let multisig = wallet.stellarMultisig {
            guard multisig.isValidStructure, wallet.bitcoinMultisig == nil, wallet.tronMultisig == nil, wallet.solanaMultisig == nil, wallet.xrplMultisig == nil,
                  wallet.mnemonic.isEmpty, wallet.language.isEmpty, wallet.privateKey == nil,
                  wallet.passphrase == nil, wallet.legacyPassphrase == nil,
                  wallet.accounts.count == 1, wallet.accounts[0].network == "stellar",
                  wallet.accounts[0].index == 0, wallet.accounts[0].derivationPath == "stellar-multisig-v1" else {
                throw CloudBackupError.invalidDocument
            }
        } else if let multisig = wallet.xrplMultisig {
            guard multisig.isValidStructure, wallet.bitcoinMultisig == nil, wallet.tronMultisig == nil, wallet.solanaMultisig == nil,
                  wallet.mnemonic.isEmpty, wallet.language.isEmpty, wallet.privateKey == nil,
                  wallet.passphrase == nil, wallet.legacyPassphrase == nil,
                  wallet.accounts.count == 1, wallet.accounts[0].network == "xrpl",
                  wallet.accounts[0].index == 0, wallet.accounts[0].derivationPath == "xrpl-multisig-v1" else {
                throw CloudBackupError.invalidDocument
            }
        } else if let multisig = wallet.solanaMultisig {
            guard multisig.isValidStructure, wallet.bitcoinMultisig == nil, wallet.tronMultisig == nil,
                  wallet.mnemonic.isEmpty, wallet.language.isEmpty, wallet.privateKey == nil,
                  wallet.passphrase == nil, wallet.legacyPassphrase == nil,
                  wallet.accounts.count == 1, wallet.accounts[0].network == "solana",
                  wallet.accounts[0].index == 0, wallet.accounts[0].derivationPath == "solana-multisig-v1" else {
                throw CloudBackupError.invalidDocument
            }
        } else if let multisig = wallet.tronMultisig {
            guard multisig.isValidStructure, wallet.bitcoinMultisig == nil,
                  wallet.mnemonic.isEmpty, wallet.language.isEmpty, wallet.privateKey == nil,
                  wallet.passphrase == nil, wallet.legacyPassphrase == nil,
                  wallet.accounts.count == 1, wallet.accounts[0].network == "tron",
                  wallet.accounts[0].index == 0, wallet.accounts[0].derivationPath == "tron-multisig-v1" else {
                throw CloudBackupError.invalidDocument
            }
        } else if let multisig = wallet.bitcoinMultisig {
            guard multisig.isValidStructure, wallet.mnemonic.isEmpty, wallet.language.isEmpty,
                  wallet.privateKey == nil, wallet.passphrase == nil, wallet.legacyPassphrase == nil,
                  wallet.accounts.count == 1, wallet.accounts[0].network == multisig.chainID,
                  wallet.accounts[0].index == 0, wallet.accounts[0].derivationPath == multisig.accountPath + "/0/0" else {
                throw CloudBackupError.invalidDocument
            }
        } else if let key = wallet.privateKey {
            guard (key.compressed != false || key.networks == ["bitcoin"] || key.networks == ["dogecoin"] || key.networks == ["litecoin"] || key.networks == ["bitcoincash"]),
                  (key.bitcoinExtendedKey == nil || (key.networks == ["bitcoin"] && key.compressed != false && key.bitcoinExtendedKey!.utf8.count <= 128)),
                  (key.dogecoinExtendedKey == nil || (key.networks == ["dogecoin"] && key.compressed != false && key.dogecoinExtendedKey!.utf8.count <= 128)),
                  (key.bitcoinCashExtendedKey == nil || (key.networks == ["bitcoincash"] && key.compressed != false && key.bitcoinCashExtendedKey!.utf8.count <= 128)),
                  (key.litecoinExtendedKey == nil || (key.networks == ["litecoin"] && key.compressed != false && key.litecoinExtendedKey!.utf8.count <= 128)) else { throw CloudBackupError.invalidDocument }
            guard wallet.mnemonic.isEmpty, wallet.language.isEmpty, wallet.passphrase == nil, key.bytes.count == 32,
                  !key.networks.isEmpty, Set(key.networks).count == key.networks.count,
                  Set(key.networks) == Set(wallet.accounts.map(\.network)),
                  wallet.accounts.allSatisfy({ $0.derivationPath == "imported" && $0.index == 0 }) else {
                throw CloudBackupError.invalidDocument
            }
        } else {
            guard !wallet.mnemonic.isEmpty, wallet.mnemonic.utf8.count < 16_384,
                  !wallet.language.isEmpty else { throw CloudBackupError.invalidDocument }
        }
        guard wallet.name.count <= 100,
              wallet.createdAt.timeIntervalSince1970.isFinite, wallet.accounts.count <= 1_024,
              wallet.accounts.allSatisfy({ !$0.network.isEmpty && !$0.derivationPath.isEmpty && $0.index >= 0 }) else {
            throw CloudBackupError.invalidDocument
        }
    }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    private static func derive(_ password: String, salt: Data) throws -> SymmetricKey {
        // Swift's native String equality treats canonically equivalent input
        // as matching confirmation. Derive identically across those keyboards.
        var passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var key = [UInt8](repeating: 0, count: 32)
        defer {
            _ = passwordBytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            _ = key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        }
        let result = passwordBytes.withUnsafeBytes { password in
            salt.withUnsafeBytes { salt in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    password.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
                    salt.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &key, key.count)
            }
        }
        guard result == kCCSuccess else { throw CloudBackupError.unavailable }
        return SymmetricKey(data: key)
    }
}
