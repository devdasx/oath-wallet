import Foundation
import CryptoKit
import OathAnkr
import OathBitcoin

/// Offline recipient decoding used by the shared scanner.
/// Format probing is expected validation, not a diagnostic failure.
enum OathScanAddress {
    struct Recipient: Sendable, Equatable {
        let address: String
        var memo: String? = nil
        var memoType: String? = nil
    }

    /// Infer networks for an unqualified scan, separately from validating an
    /// address on a network explicitly selected by a payment URI.
    static func networks(for value: String) -> [OathImportChain] {
        let matches = OathImportChain.allCases.filter { decode(value, chain: $0) != nil }
        guard matches.count > 1, matches.contains(.near) else { return matches }

        // NEAR's named-account grammar accepts almost any lowercase identifier,
        // including valid bc1/ltc1/CashAddr strings. It is only a fallback when
        // another network recognizes a concrete address format. Do not weaken
        // NearIdentity or explicit near: requests to resolve this scan ambiguity.
        // Native and Ethereum-like implicit accounts (and deterministic accounts)
        // have real address formats, so their genuine overlaps remain selectable.
        let isNativeImplicit = value.utf8.count == 64 && value.utf8.allSatisfy(isLowercaseHex)
        let isPrefixedAccount = value.utf8.count == 42
            && (value.hasPrefix("0x") || value.hasPrefix("0s"))
            && value.utf8.dropFirst(2).allSatisfy(isLowercaseHex)
        return isNativeImplicit || isPrefixedAccount ? matches : matches.filter { $0 != .near }
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }

    static func decode(_ value: String, chain: OathImportChain) -> Recipient? {
        guard !value.isEmpty, value.utf8.count <= 256,
              value.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
        if chain.isEVM {
            guard value.hasPrefix("0x"), value.count == 42,
                  value.dropFirst(2).allSatisfy(\.isHexDigit) else { return nil }
            let hex = String(value.dropFirst(2))
            if hex != hex.lowercased(), hex != hex.uppercased() {
                let digest = TronSendCrypto.keccak(Data(hex.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
                for (c, h) in zip(hex, digest) where c.isLetter {
                    guard c.isUppercase == (h.hexDigitValue! >= 8) else { return nil }
                }
            }
            return .init(address: value)
        }
        if let network = UTXONetwork(rawValue: chain.rawValue) {
            guard (try? BitcoinSendPlan.recipientScript(value, chain: network)) != nil else { return nil }
            return .init(address: value)
        }
        switch chain {
        case .thorchain:
            guard (try? ThorchainIdentity.address(value)) != nil else { return nil }
        case .near:
            guard value != "system", (try? NearIdentity.address(value)) != nil else { return nil }
        case .solana:
            guard let bytes = try? SolanaSendCrypto.decode(value), bytes.count == 32 else { return nil }
        case .tron:
            guard let address = try? TronIdentity.address(value) else { return nil }
            return .init(address: address)
        case .sui, .aptos:
            guard let address = try? AptosIdentity.address(value) else { return nil }
            return .init(address: address)
        case .ton:
            guard (try? TonIdentity.raw(value)) != nil else { return nil }
        case .stellar:
            if (try? StellarIdentity.address(value)) != nil { break }
            // SEP-23 muxed account -> G address + ID memo, without losing routing.
            guard value.count == 69, let data = base32(value), data.count == 43, data[0] == 96,
                  crc16(Data(data.prefix(41))) == Array(data.suffix(2)) else { return nil }
            let account = strKey(Data(data[1..<33]), version: 48)
            let id = data[33..<41].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            return .init(address: account, memo: String(id), memoType: "id")
        case .xrpl:
            if (try? XrplIdentity.address(value)) != nil { break }
            // X-address mainnet prefix and embedded little-endian destination tag.
            guard let data = base58Check(value, alphabet: rippleAlphabet), data.count == 31,
                  Array(data.prefix(2)) == [0x05, 0x44], data[22] <= 1,
                  data[27..<31].allSatisfy({ $0 == 0 }),
                  data[22] == 1 || data[23..<27].allSatisfy({ $0 == 0 }) else { return nil }
            let account = base58Encode(Data([0]) + data[2..<22], alphabet: rippleAlphabet)
            let tag = data[23..<27].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return .init(address: account, memo: data[22] == 1 ? String(tag) : nil)
        default: return nil
        }
        return .init(address: value)
    }

    static let rippleAlphabet = Array("rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz".utf8)
    static func base58Check(_ text: String, alphabet: [UInt8]) -> Data? {
        var bytes = [Int]()
        for c in text.utf8 {
            guard let index = alphabet.firstIndex(of: c) else { return nil }
            var carry = index
            for i in bytes.indices { carry += bytes[i] * 58; bytes[i] = carry & 255; carry >>= 8 }
            while carry > 0 { bytes.append(carry & 255); carry >>= 8 }
        }
        let data = Data(Array(repeating: UInt8(0), count: text.utf8.prefix(while: { $0 == alphabet[0] }).count) + bytes.reversed().map(UInt8.init))
        guard data.count >= 5, checksum(Data(data.dropLast(4))) == data.suffix(4) else { return nil }
        return Data(data.dropLast(4))
    }
    static func base58Encode(_ payload: Data, alphabet: [UInt8]) -> String {
        let data = payload + checksum(payload)
        var digits = [Int]()
        for c in data {
            var carry = Int(c)
            for i in digits.indices { carry += digits[i] * 256; digits[i] = carry % 58; carry /= 58 }
            while carry > 0 { digits.append(carry % 58); carry /= 58 }
        }
        return String(decoding: Array(repeating: alphabet[0], count: data.prefix(while: { $0 == 0 }).count) + digits.reversed().map { alphabet[$0] }, as: UTF8.self)
    }
    private static func checksum(_ data: Data) -> Data { Data(SHA256.hash(data: Data(SHA256.hash(data: data))).prefix(4)) }
    static func crc16(_ data: Data) -> [UInt8] {
        var crc: UInt16 = 0
        for c in data { crc ^= UInt16(c) << 8; for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc &<< 1) ^ 0x1021 : crc &<< 1 } }
        return [UInt8(truncatingIfNeeded: crc), UInt8(crc >> 8)]
    }
    static func base32(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var bits = 0, buffer: UInt32 = 0, out = Data()
        for c in text.utf8 {
            guard let index = alphabet.firstIndex(of: c) else { return nil }
            buffer = (buffer << 5) | UInt32(index); bits += 5
            if bits >= 8 { bits -= 8; out.append(UInt8((buffer >> bits) & 255)); buffer &= (1 << bits) - 1 }
        }
        guard buffer == 0 else { return nil }
        return out
    }
    static func strKey(_ data: Data, version: UInt8) -> String {
        let payload = Data([version]) + data
        let bytes = payload + crc16(payload), alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer: UInt32 = 0, bits = 0, out = ""
        for c in bytes {
            buffer = (buffer << 8) | UInt32(c); bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[Int((buffer >> bits) & 31)]) }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { out.append(alphabet[Int((buffer << (5 - bits)) & 31)]) }
        return out
    }
}
