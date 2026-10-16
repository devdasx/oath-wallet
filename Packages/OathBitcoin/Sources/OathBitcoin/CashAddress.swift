import Foundation

/// CashAddr and legacy Base58 encodings commit to the same locking script.
/// A caller must specify the network; never infer it from an unprefixed string.
enum CashAddress {
    private static let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
    static func p2pkh(script: Data) throws -> String { try encode(script: script, prefix: "bitcoincash") }

    static func encode(script: Data, prefix: String) throws -> String {
        let b = Array(script), version: UInt8, hash: Data
        if b.count == 25, b.prefix(3) == [0x76,0xa9,0x14], b.suffix(2) == [0x88,0xac] {
            version = 0; hash = script.dropFirst(3).prefix(20)
        } else if b.count == 23, b.prefix(2) == [0xa9,0x14], b.last == 0x87 {
            version = 8; hash = script.dropFirst(2).prefix(20)
        } else if b.count == 35, b.prefix(2) == [0xaa,0x20], b.last == 0x87 {
            version = 11; hash = script.dropFirst(2).prefix(32)
        } else { throw BitcoinError.invalidAddress }
        let values = try convert(Array(Data([version]) + hash), from: 8, to: 5, pad: true)
        let checksum = polymod(prefix.utf8.map { $0 & 31 } + [0] + values + Array(repeating: 0, count: 8)) ^ 1
        let suffix = (0..<8).map { UInt8((checksum >> (5 * (7 - $0))) & 31) }
        return prefix + ":" + String(decoding: (values + suffix).map { alphabet[Int($0)] }, as: UTF8.self)
    }

    static func decode(_ address: String, prefix: String) throws -> Data {
        guard !address.isEmpty, address.utf8.count <= 196 else { throw BitcoinSendError.invalidRecipient }
        if !address.contains(":"), let payload = try? Base58Check.decode(address), payload.count == 21 {
            let main = prefix == "bitcoincash"
            if payload.first == (main ? 0 : 111) { return Data([0x76,0xa9,0x14]) + payload.dropFirst() + Data([0x88,0xac]) }
            if payload.first == (main ? 5 : 196) { return Data([0xa9,0x14]) + payload.dropFirst() + Data([0x87]) }
            throw BitcoinSendError.invalidRecipient
        }
        guard address == address.lowercased() || address == address.uppercased() else { throw BitcoinSendError.invalidRecipient }
        let parts = address.lowercased().split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || (parts.count == 2 && parts[0] == prefix), let payload = parts.last else { throw BitcoinSendError.invalidRecipient }
        let values = try payload.utf8.map { byte -> UInt8 in
            guard let i = alphabet.firstIndex(of: byte) else { throw BitcoinSendError.invalidRecipient }; return UInt8(i)
        }
        guard values.count >= 8, polymod(prefix.utf8.map { $0 & 31 } + [0] + values) == 1 else { throw BitcoinSendError.invalidRecipient }
        let bytes = try convert(Array(values.dropLast(8)), from: 5, to: 8, pad: false)
        guard let version = bytes.first, version & 0x80 == 0 else { throw BitcoinSendError.invalidRecipient }
        let lengths = [20,24,28,32,40,48,56,64], type = (version >> 3) & 15
        let hash = Data(bytes.dropFirst())
        guard hash.count == lengths[Int(version & 7)] else { throw BitcoinSendError.invalidRecipient }
        // Token-aware addresses can receive plain BCH. They do not authorize
        // consuming CashToken outputs or constructing token-bearing outputs.
        if (type == 0 || type == 2), hash.count == 20 { return Data([0x76,0xa9,0x14]) + hash + Data([0x88,0xac]) }
        if type == 1 || type == 3 {
            if hash.count == 20 { return Data([0xa9,0x14]) + hash + Data([0x87]) }
            if hash.count == 32 { return Data([0xaa,0x20]) + hash + Data([0x87]) }
        }
        throw BitcoinSendError.invalidRecipient
    }
    private static func polymod(_ values: [UInt8]) -> UInt64 {
        var checksum: UInt64 = 1
        let generators: [UInt64] = [0x98f2bc8e61,0x79b76d99e2,0xf33e5fb3c4,0xae2eabe2a8,0x1e4f43e470]
        for value in values {
            let top = checksum >> 35
            checksum = ((checksum & 0x07ffffffff) << 5) ^ UInt64(value)
            for bit in 0..<5 where ((top >> bit) & 1) != 0 { checksum ^= generators[bit] }
        }
        return checksum
    }
    private static func convert(_ values: [UInt8], from: Int, to: Int, pad: Bool) throws -> [UInt8] {
        var accumulator: UInt32 = 0, bits = 0, result: [UInt8] = []
        let mask: UInt32 = (1 << to) - 1
        for value in values {
            accumulator = ((accumulator << from) | UInt32(value)) & ((1 << (from + to - 1)) - 1)
            bits += from
            while bits >= to { bits -= to; result.append(UInt8((accumulator >> bits) & mask)) }
        }
        if pad { if bits > 0 { result.append(UInt8((accumulator << (to - bits)) & mask)) } }
        else if bits >= from || ((accumulator << (to - bits)) & mask) != 0 { throw BitcoinSendError.invalidRecipient }
        return result
    }
}
