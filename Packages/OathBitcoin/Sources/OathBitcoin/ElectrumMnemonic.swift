import Foundation
import CryptoKit
import CommonCrypto
import OathSecp256k1
import OathDiagnostics

public enum ElectrumSeedKind: String, Codable, Sendable {
    case old, standard, segwit, twoFactor, twoFactorSegwit
    public var isTwoFactor: Bool { self == .twoFactor || self == .twoFactorSegwit }
}

/// Local encrypted-vault material only. Never serialize into public metadata or telemetry.
public struct ElectrumSeedMaterial: Codable, Equatable, Sendable {
    public let kind: ElectrumSeedKind
    public let seed: Data
    public let secondSeed: Data?
    public let passphrase: String
    public var isValid: Bool {
        seed.count == (kind == .old ? 32 : 64) && passphrase.utf8.count <= 4096
            && (secondSeed == nil || (kind == .twoFactor && secondSeed?.count == 64 && passphrase.isEmpty))
            && (kind != .old || passphrase.isEmpty)
    }
}

public enum ElectrumMnemonicError: Error, Equatable { case invalidPhrase, unsupportedPassphrase, derivation }

/// Electrum seed-version, normalization and KDF rules, independent of BIP39.
/// Reference: spesmilo/electrum mnemonic.py, old_mnemonic.py and keystore.py (MIT).
public enum ElectrumMnemonic {
    public static func normalize(_ value: String) -> String {
        let scalars = value.decomposedStringWithCompatibilityMapping.lowercased()
            .unicodeScalars.filter { $0.properties.canonicalCombiningClass == .notReordered }
        let spaces = scalars.split { scalar in
            scalar.properties.isWhitespace || (0x1c...0x1f).contains(scalar.value)
        }.map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
        let units = Array(spaces.unicodeScalars)
        return String(String.UnicodeScalarView(units.enumerated().compactMap { i, scalar in
            scalar == " " && i > 0 && i + 1 < units.count && isCJK(units[i-1].value) && isCJK(units[i+1].value) ? nil : scalar
        }))
    }
    private static func isCJK(_ n: UInt32) -> Bool {
        let ranges: [ClosedRange<UInt32>] = [0x4e00...0x9fff,0x3400...0x4dbf,0x20000...0x2a6df,0x2a700...0x2b73f,0x2b740...0x2b81f,0xf900...0xfaff,0x2f800...0x2fa1d,0x3190...0x319f,0x2e80...0x2eff,0x2f00...0x2fdf,0x31c0...0x31ef,0x2ff0...0x2fff,0xe0100...0xe01ef,0x3100...0x312f,0x31a0...0x31bf,0xff00...0xffef,0x3040...0x309f,0x30a0...0x30ff,0x31f0...0x31ff,0x1b000...0x1b0ff,0xac00...0xd7af,0x1100...0x11ff,0xa960...0xa97f,0xd7b0...0xd7ff,0x3130...0x318f,0xa4d0...0xa4ff,0x16f00...0x16f9f,0xa000...0xa48f,0xa490...0xa4cf]
        return ranges.contains { $0.contains(n) }
    }
    private static let oldWords: [String: Int] = {
        guard let url = Bundle.module.url(forResource: "electrum-old-words", withExtension: "txt") else {
            OathDiagnostics.record(DiagnosticFailure("electrum_wordlist_missing"), component: "bitcoin", operation: "electrum_wordlist")
            return [:]
        }
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) }
        catch {
            OathDiagnostics.record(DiagnosticFailure("electrum_wordlist_unreadable"), component: "bitcoin", operation: "electrum_wordlist")
            return [:]
        }
        let words = text.split(whereSeparator: \.isNewline).map(String.init)
        guard words.count == 1626, Set(words).count == 1626 else {
            OathDiagnostics.record(DiagnosticFailure("electrum_wordlist_invalid"), component: "bitcoin", operation: "electrum_wordlist")
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) })
    }()
    private static func oldHex(_ text: String) -> String? {
        let hex = text.filter { !$0.isWhitespace }
        if [32,64].contains(hex.count), Data(hex: hex) != nil { return hex }
        let words = text.split(separator: " ").map(String.init)
        guard [12,24].contains(words.count), oldWords.count == 1626 else { return nil }
        var result = ""
        for i in stride(from: 0, to: words.count, by: 3) {
            guard let a = oldWords[words[i]], let b = oldWords[words[i+1]], let c = oldWords[words[i+2]] else { return nil }
            let n = 1626
            // Electrum deliberately accepts legacy overflow groups; %08x is a minimum width.
            let value = a + n * ((b-a+n)%n) + n*n * ((c-b+n)%n)
            result += String(format: "%08llx", UInt64(value))
        }
        return result
    }
    public static func kind(_ text: String) -> ElectrumSeedKind? {
        guard !text.isEmpty, text.utf8.count <= 4096, oldWords.count == 1626 else { return nil }
        let normalized = normalize(text)
        if oldHex(normalized) != nil { return .old }
        let hash = Data(HMAC<SHA512>.authenticationCode(for: Data(normalized.utf8), using: SymmetricKey(data: Data("Seed version".utf8)))).hex
        if hash.hasPrefix("01") { return .standard }
        if hash.hasPrefix("100") { return .segwit }
        let count = text.split(whereSeparator: \.isWhitespace).count
        if hash.hasPrefix("101"), count == 12 || count >= 20 { return .twoFactor }
        if hash.hasPrefix("102") { return .twoFactorSegwit }
        return nil
    }
    /// A version prefix also matches some URLs, JSON and public addresses. The scanner
    /// accepts mnemonic-shaped input; explicit Electrum decoding retains its native semantics.
    public static func recognizesScannedPhrase(_ text: String) -> Bool {
        guard let kind = kind(text) else { return false }
        if kind == .old { return true } // Legacy word sequences or 16/32 bytes of hex entropy.
        let plain = text.decomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCharacters = CharacterSet.alphanumerics.union(.nonBaseCharacters)
        let allowed = wordCharacters.union(.whitespacesAndNewlines)
        guard !plain.isEmpty, plain.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return plain.contains(where: \.isWhitespace) || plain.unicodeScalars.allSatisfy { isCJK($0.value) }
    }

    public static func allowsPassphrase(_ text: String) -> Bool {
        guard let kind = kind(text) else { return false }
        return kind != .old && !(kind == .twoFactor && text.split(whereSeparator: \.isWhitespace).count >= 20)
    }
    public static func decode(_ phrase: String, passphrase: String = "") throws -> ElectrumSeedMaterial {
        guard let kind = kind(phrase), passphrase.utf8.count <= 4096 else { throw ElectrumMnemonicError.invalidPhrase }
        guard passphrase.isEmpty || allowsPassphrase(phrase) else { throw ElectrumMnemonicError.unsupportedPassphrase }
        let text = normalize(phrase)
        if kind == .old {
            guard let hex = oldHex(text) else { throw ElectrumMnemonicError.invalidPhrase }
            var encoded = Data(hex.utf8), value = encoded
            defer { encoded.resetBytes(in: 0..<encoded.count); value.resetBytes(in: 0..<value.count) }
            for i in 0..<100_000 {
                if i % 1024 == 0 { try Task.checkCancellation() }
                value = Data(SHA256.hash(data: value + encoded))
            }
            _ = try OathSecp256k1.publicKey(value, compressed: false)
            return .init(kind: kind, seed: value, secondSeed: nil, passphrase: "")
        }
        let words = text.split(separator: " ")
        if kind == .twoFactor, words.count >= 20 {
            return try .init(kind: kind, seed: stretch(words.prefix(12).joined(separator: " "), passphrase: ""),
                             secondSeed: stretch(words.dropFirst(12).joined(separator: " "), passphrase: ""), passphrase: "")
        }
        return try .init(kind: kind, seed: stretch(text, passphrase: passphrase), secondSeed: nil, passphrase: passphrase)
    }
    private static func stretch(_ text: String, passphrase: String) throws -> Data {
        var password = Array(normalize(text).utf8), salt = Array(("electrum" + normalize(passphrase)).utf8), output = [UInt8](repeating: 0, count: 64)
        defer { _ = salt.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }; _ = password.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }; _ = output.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let status = password.withUnsafeBytes { p in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.bindMemory(to: Int8.self).baseAddress, password.count,
                    s.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), 2048, &output, 64)
            }
        }
        guard status == kCCSuccess else { throw ElectrumMnemonicError.derivation }
        return Data(output)
    }
}
