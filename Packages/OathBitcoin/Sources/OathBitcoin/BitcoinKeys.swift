import Foundation
import CryptoKit
import OathSecp256k1
internal import BitcoinDevKit

public enum BitcoinAddressType: Int, Codable, CaseIterable, Sendable, Identifiable {
    case taproot = 86, nativeSegwit = 84, nestedSegwit = 49, legacy = 44
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .taproot: "Taproot · BIP86"
        case .nativeSegwit: "Native SegWit · BIP84"
        case .nestedSegwit: "SegWit · BIP49"
        case .legacy: "Legacy · BIP44"
        }
    }
    func wrap(_ key: String) -> String {
        switch self {
        case .taproot: "tr(\(key))"
        case .nativeSegwit: "wpkh(\(key))"
        case .nestedSegwit: "sh(wpkh(\(key)))"
        case .legacy: "pkh(\(key))"
        }
    }
}

public enum BitcoinError: Error, Equatable, Sendable {
    case invalidKey, unsupportedKeyScope, invalidAddress, invalidResponse, inconsistentSnapshot
    case timeout, disconnected, tls, batchUnsupported, wrongNetwork, server(code: Int)
    case unavailable, discoveryLimit, cancelled
}

/// Contains PUBLIC descriptors only. Private material never reaches the scanner,
/// database, transport, or diagnostic descriptions.
public struct BitcoinBranch: Codable, Equatable, Sendable, Identifiable {
    public let type: BitcoinAddressType
    public let change: UInt32
    public let path: String
    public let descriptor: String
    public let isHD: Bool
    public let network: UTXONetwork
    public let derivationPurpose: UInt32?
    public let electrumLegacyPublicKey: Data?
    public init(type: BitcoinAddressType, change: UInt32, path: String, descriptor: String, isHD: Bool, network: UTXONetwork = .bitcoin, derivationPurpose: UInt32? = nil, electrumLegacyPublicKey: Data? = nil) {
        self.electrumLegacyPublicKey = electrumLegacyPublicKey
        self.derivationPurpose = derivationPurpose
        self.type = type; self.change = change; self.path = path; self.descriptor = descriptor; self.isHD = isHD; self.network = network
    }
    private enum CodingKeys: String, CodingKey { case type, change, path, descriptor, isHD, network, derivationPurpose, electrumLegacyPublicKey }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(BitcoinAddressType.self, forKey: .type)
        change = try c.decode(UInt32.self, forKey: .change)
        path = try c.decode(String.self, forKey: .path)
        descriptor = try c.decode(String.self, forKey: .descriptor)
        isHD = try c.decode(Bool.self, forKey: .isHD)
        network = try c.decodeIfPresent(UTXONetwork.self, forKey: .network) ?? .bitcoin
        derivationPurpose = try c.decodeIfPresent(UInt32.self, forKey: .derivationPurpose)
        electrumLegacyPublicKey = try c.decodeIfPresent(Data.self, forKey: .electrumLegacyPublicKey)
    }
    public var id: String { "\(derivationPurpose ?? UInt32(type.rawValue)):\(change)" }
}

public struct BitcoinWalletDescriptor: Codable, Equatable, Sendable {
    public let branches: [BitcoinBranch]
    public let defaultType: BitcoinAddressType
    /// An account/branch key cannot recover the hardened siblings of its origin.
    public let scopedImport: Bool
    public init(branches: [BitcoinBranch], defaultType: BitcoinAddressType, scopedImport: Bool) {
        self.branches = branches; self.defaultType = defaultType; self.scopedImport = scopedImport
    }
    public var network: UTXONetwork { branches.first?.network ?? .bitcoin }
    public var types: [BitcoinAddressType] { BitcoinAddressType.allCases.filter { t in branches.contains { $0.type == t } } }
}

public struct BitcoinDerivedAddress: Codable, Equatable, Sendable, Identifiable {
    public let branchID: String
    public let type: BitcoinAddressType
    public let change: UInt32
    public let index: UInt32
    public let path: String
    public let address: String
    public let script: String
    public let scriptHash: String
    /// Bounded public satisfaction weight for P2WSH/P2SH multisig; absent on existing single-key addresses.
    public var multisigInputWeight: Int64? = nil
    public var id: String { "\(branchID):\(index)" }
}

public enum BitcoinKeys {
    /// Verifies legacy import ownership without installing its address policy.
    /// The caller supplies a bounded relative path; only public bytes escape.
    public static func importPublicKey(_ encoded: String, relativePath: String) throws -> Data {
        guard relativePath.utf8.count <= 512,
              relativePath.split(separator: "/").count <= 33 else { throw BitcoinError.invalidKey }
        let parsed = try normalizedExtended(encoded)
        guard parsed.privateKey else { throw BitcoinError.invalidKey }
        let leaf = try DescriptorSecretKey.fromString(privateKey: parsed.encoded)
            .derive(path: DerivationPath(path: relativePath))
        var bytes = leaf.secretBytes()
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return try OathSecp256k1.publicKey(bytes)
    }

    /// Use a BIP39 seed from the app's existing, language-aware mnemonic engine.
    /// Only HMAC serialization happens here; BDK validates and derives the keys.
    public static func wallet(seed: Data, account: UInt32 = 0, network: UTXONetwork = .bitcoin) throws -> BitcoinWalletDescriptor {
        guard (network == .bitcoin || network == .litecoin), (16...64).contains(seed.count), account < 0x8000_0000 else { throw BitcoinError.invalidKey }
        var digest = Data(HMAC<SHA512>.authenticationCode(for: seed, using: SymmetricKey(data: Data("Bitcoin seed".utf8))))
        defer { digest.resetBytes(in: 0..<digest.count) }
        let payload = Data([0x04, 0x88, 0xad, 0xe4]) + Data(repeating: 0, count: 9) + digest.suffix(32) + Data([0]) + digest.prefix(32)
        return try extended(Base58Check.encode(payload), account: account, defaultType: .nativeSegwit, network: network)
    }

    /// LND/btcwallet BIP49Plus uses native SegWit change under purpose 49.
    /// Entropy is the decoded aezeed seed, never a BIP39 PBKDF2 result.
    public static func aezeedWallet(entropy: Data, account: UInt32 = 0) throws -> BitcoinWalletDescriptor {
        guard entropy.count == 16 else { throw BitcoinError.invalidKey }
        let standard = try wallet(seed: entropy, account: account)
        let branches = try standard.branches.map { branch -> BitcoinBranch in
            guard branch.type == .nestedSegwit, branch.change == 1 else { return branch }
            let wrapped = branch.descriptor.split(separator: "#")[0]
            guard wrapped.hasPrefix("sh("), wrapped.hasSuffix(")") else { throw BitcoinError.invalidKey }
            let descriptor = try Descriptor(descriptor: String(wrapped.dropFirst(3).dropLast()), networkKind: .main)
            try descriptor.sanityCheck()
            return BitcoinBranch(type: .nativeSegwit, change: 1, path: branch.path,
                descriptor: descriptor.asPublic().description, isHD: true, derivationPurpose: 49)
        }
        return .init(branches: branches, defaultType: .nativeSegwit, scopedImport: false)
    }

    /// Supports mainnet xprv/yprv/zprv and account xpub/ypub/zpub. The latter is
    /// also used to test that the scanner needs no private signing material.
    public static func extended(_ encoded: String, account: UInt32 = 0,
                                defaultType: BitcoinAddressType? = nil, network: UTXONetwork = .bitcoin) throws -> BitcoinWalletDescriptor {
        guard (network == .bitcoin || network == .litecoin) else { throw BitcoinError.wrongNetwork }
        let coinType: UInt32 = network == .litecoin ? 2 : 0
        let parsed = try normalizedExtended(encoded, network: network)
        let bytes = parsed.bytes
        let depth = Int(bytes[4])
        let child = bytes[9..<13].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard depth <= 5, account < 0x8000_0000 else { throw BitcoinError.unsupportedKeyScope }
        let secret = parsed.privateKey ? try DescriptorSecretKey.fromString(privateKey: parsed.encoded) : nil
        let publicKey = parsed.privateKey ? nil : try DescriptorPublicKey.fromString(publicKey: parsed.encoded)
        guard secret != nil || depth >= 3 else { throw BitcoinError.unsupportedKeyScope }
        if depth == 0 { guard child == 0, bytes[5..<9].allSatisfy({ $0 == 0 }) else { throw BitcoinError.invalidKey } }
        if depth == 1 { guard child >= 0x8000_0000, [44,49,84,86].contains(child & 0x7fff_ffff) else { throw BitcoinError.unsupportedKeyScope } }
        if depth == 2 { guard child == 0x8000_0000 + coinType else { throw BitcoinError.wrongNetwork } }
        if depth == 3 { guard child >= 0x8000_0000 else { throw BitcoinError.unsupportedKeyScope } }
        if depth == 4 { guard child <= 1 else { throw BitcoinError.unsupportedKeyScope } }
        if depth == 5 { guard child < 0x8000_0000 else { throw BitcoinError.unsupportedKeyScope } }
        var branches: [BitcoinBranch] = []
        for type in BitcoinAddressType.allCases {
            let relative: String
            switch depth {
            case 0: relative = "m/\(type.rawValue)'/\(coinType)'/\(account)'"
            case 1: relative = "m/\(coinType)'/\(account)'"
            case 2: relative = "m/\(account)'"
            default: relative = "m"
            }
            let key: String
            if let secret { key = try secret.derive(path: DerivationPath(path: relative)).asPublic().description }
            else { key = publicKey!.description }
            let changes: [UInt32] = depth == 4 ? [child] : depth == 5 ? [0] : [0, 1]
            for change in changes {
                let suffix = depth < 4 ? "/\(change)/*" : depth == 4 ? "/*" : ""
                let descriptor = try Descriptor(descriptor: type.wrap(key + suffix), networkKind: .main)
                try descriptor.sanityCheck()
                let path = depth == 0 ? "\(relative)/\(change)" : "imported\(relative == "m" ? "" : "/" + relative.dropFirst(2))\(depth < 4 ? "/\(change)" : "")"
                branches.append(.init(type: type, change: change, path: path, descriptor: descriptor.asPublic().description, isHD: depth < 5, network: network))
            }
        }
        return .init(branches: branches, defaultType: defaultType ?? parsed.type, scopedImport: depth != 0)
    }

    public static func singleKey(bytes: Data, compressed: Bool, network: UTXONetwork = .bitcoin) throws -> BitcoinWalletDescriptor {
        guard (network == .bitcoin || network == .litecoin), bytes.count == 32 else { throw BitcoinError.invalidKey }
        let wif = Base58Check.encode(Data([0x80]) + bytes + (compressed ? Data([1]) : Data()))
        let key = try DescriptorSecretKey.fromString(privateKey: wif).asPublic().description
        let types = compressed ? BitcoinAddressType.allCases : [.legacy]
        let branches = try types.map { type in
            let descriptor = try Descriptor(descriptor: type.wrap(key), networkKind: .main)
            try descriptor.sanityCheck()
            return BitcoinBranch(type: type, change: 0, path: "imported", descriptor: descriptor.asPublic().description, isHD: false, network: network)
        }
        return .init(branches: branches, defaultType: compressed ? .nativeSegwit : .legacy, scopedImport: false)
    }

    public static func decodeImport(_ text: String) throws -> (bytes: Data, compressed: Bool, extended: String?) {
        guard text.utf8.count <= 128 else { throw BitcoinError.invalidKey }
        let hex = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
        if hex.count == 64, let bytes = Data(hex: hex) {
            _ = try singleKey(bytes: bytes, compressed: true)
            return (bytes, true, nil)
        }
        if text.hasPrefix("xprv") || text.hasPrefix("yprv") || text.hasPrefix("zprv") {
            let parsed = try normalizedExtended(text)
            guard parsed.privateKey else { throw BitcoinError.invalidKey }
            _ = try extended(text)
            let bytes = try DescriptorSecretKey.fromString(privateKey: parsed.encoded).secretBytes()
            guard bytes.count == 32 else { throw BitcoinError.invalidKey }
            return (bytes, true, text)
        }
        let payload = try Base58Check.decode(text)
        guard payload.first == 0x80, payload.count == 33 || (payload.count == 34 && payload.last == 1) else { throw BitcoinError.invalidKey }
        let bytes = Data(payload.dropFirst().prefix(32))
        _ = try singleKey(bytes: bytes, compressed: payload.count == 34)
        return (bytes, payload.count == 34, nil)
    }

    public static func wif(bytes: Data, compressed: Bool) throws -> String {
        _ = try singleKey(bytes: bytes, compressed: compressed)
        return Base58Check.encode(Data([0x80]) + bytes + (compressed ? Data([1]) : Data()))
    }

    public static func addresses(branch: BitcoinBranch, range: Range<UInt32>) throws -> [BitcoinDerivedAddress] {
        guard range.upperBound < 0x8000_0000, branch.isHD || range == 0..<1 else { throw BitcoinError.invalidAddress }
        if branch.electrumLegacyPublicKey != nil { return try ElectrumBitcoin.legacyAddresses(branch: branch, range: range) }
        let descriptor = try Descriptor(descriptor: branch.descriptor, networkKind: .main)
        // Reject accidental secret-bearing descriptors at this public boundary.
        guard descriptor.toStringWithSecret() == descriptor.asPublic().description else { throw BitcoinError.invalidKey }
        return try range.map { index in
            try Task.checkCancellation()
            let address = try descriptor.deriveAddress(index: index, network: .bitcoin)
            let script = address.scriptPubkey().toBytes()
            let encoded: String
            if branch.network == .dogecoin {
                guard branch.type == .legacy else { throw BitcoinError.invalidAddress }
                encoded = try DogecoinAddress.encode(script: script, network: .mainnet)
            } else if branch.network == .bitcoincash {
                guard branch.type == .legacy else { throw BitcoinError.invalidAddress }
                encoded = try CashAddress.p2pkh(script: script)
            } else if branch.network == .litecoin {
                encoded = try LitecoinKeys.address(script: script, type: branch.type)
            } else { encoded = address.description }
            return .init(branchID: branch.id, type: branch.type, change: branch.change, index: index,
                         path: branch.isHD ? "\(branch.path)/\(index)" : branch.path,
                         address: encoded, script: script.hex,
                         scriptHash: Data(SHA256.hash(data: script).reversed()).hex,
                         multisigInputWeight: branch.descriptor.hasPrefix("wsh(sortedmulti(") ? Int64(try descriptor.maxWeightToSatisfy()) + 166 : branch.descriptor.hasPrefix("sh(sortedmulti(") ? Int64(try descriptor.maxWeightToSatisfy()) + 172 : nil)
        }
    }

    static func normalizedExtended(_ text: String, network: UTXONetwork = .bitcoin) throws -> (encoded: String, bytes: Data, privateKey: Bool, type: BitcoinAddressType) {
        guard text.utf8.count <= 128 else { throw BitcoinError.invalidKey }
        var data = try Base58Check.decode(text)
        guard data.count == 78 else { throw BitcoinError.invalidKey }
        let version = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var versions: [UInt32: (Bool, BitcoinAddressType)] = [
            0x0488ade4: (true, .legacy), 0x049d7878: (true, .nestedSegwit), 0x04b2430c: (true, .nativeSegwit),
            0x0488b21e: (false, .legacy), 0x049d7cb2: (false, .nestedSegwit), 0x04b24746: (false, .nativeSegwit)]
        if network == .litecoin {
            versions[0x019d9cfe] = (true, .legacy); versions[0x019da462] = (false, .legacy)
            versions[0x01b26792] = (true, .nestedSegwit); versions[0x01b26ef6] = (false, .nestedSegwit)
        }
        guard let (privateKey, type) = versions[version] else { throw BitcoinError.invalidKey }
        try Base58Check.validateExtendedKeyData(data, privateVersion: privateKey)
        data.replaceSubrange(0..<4, with: privateKey ? [0x04,0x88,0xad,0xe4] : [0x04,0x88,0xb2,0x1e])
        return (Base58Check.encode(data), data, privateKey, type)
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init?(hex: String) {
        guard hex.count % 2 == 0, hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else { return nil }
        var bytes: [UInt8] = []; var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); guard let byte = UInt8(hex[i..<j], radix: 16) else { return nil }; bytes.append(byte); i = j }
        self.init(bytes)
    }
}

/// Base58Check encoding only; elliptic curve and BIP32 operations stay in BDK.
enum Base58Check {
    /// A version alias changes only the four version bytes. Validate the
    /// original key data before a descriptor parser can discard its type byte.
    static func validateExtendedKeyData(_ payload: Data, privateVersion: Bool) throws {
        guard payload.count == 78 else { throw BitcoinError.invalidKey }
        let marker = payload[45]
        if privateVersion {
            guard marker == 0 else { throw BitcoinError.invalidKey }
        } else {
            guard marker == 2 || marker == 3 else { throw BitcoinError.invalidKey }
        }
    }

    static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    static func encode(_ payload: Data) -> String {
        let data = payload + SHA256.hash(data: Data(SHA256.hash(data: payload))).prefix(4)
        var digits = [UInt8](repeating: 0, count: 1)
        for byte in data {
            var carry = Int(byte)
            for i in digits.indices { carry += Int(digits[i]) << 8; digits[i] = UInt8(carry % 58); carry /= 58 }
            while carry > 0 { digits.append(UInt8(carry % 58)); carry /= 58 }
        }
        return String(decoding: Array(repeating: alphabet[0], count: data.prefix(while: { $0 == 0 }).count) + digits.reversed().map { alphabet[Int($0)] }, as: UTF8.self)
    }
    static func decode(_ text: String) throws -> Data {
        guard !text.isEmpty, text.utf8.count <= 128 else { throw BitcoinError.invalidKey }
        var bytes = [UInt8](repeating: 0, count: 1)
        for c in text.utf8 {
            guard let n = alphabet.firstIndex(of: c) else { throw BitcoinError.invalidKey }
            var carry = n
            for i in bytes.indices { carry += Int(bytes[i]) * 58; bytes[i] = UInt8(carry & 255); carry >>= 8 }
            while carry > 0 { bytes.append(UInt8(carry & 255)); carry >>= 8 }
        }
        let data = Data(Array(repeating: UInt8(0), count: text.utf8.prefix(while: { $0 == alphabet[0] }).count) + bytes.reversed())
        guard data.count > 4 else { throw BitcoinError.invalidKey }
        let payload = Data(data.dropLast(4))
        guard data.suffix(4) == Data(SHA256.hash(data: Data(SHA256.hash(data: payload))).prefix(4)) else { throw BitcoinError.invalidKey }
        return payload
    }
}
