import Foundation

/// The EAM's delegated address and its Ethereum representation name one account.
/// Native f1/f3 accounts are different identities and cannot be converted offline.
public enum FilecoinIdentity {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    public static func ethereum(_ address: String, testnet: Bool = false) throws -> String {
        if address.hasPrefix("0x") { return try IndexedEVMIdentity.address(address) }
        guard address.hasPrefix(testnet ? "t410f" : "f410f"), address.utf8.count == 44 else { throw AnkrError.invalidAddress }
        var buffer: UInt32 = 0, bits = 0, bytes = Data()
        for byte in address.utf8.dropFirst(5) {
            guard let digit = alphabet.firstIndex(of: byte) else { throw AnkrError.invalidAddress }
            buffer = (buffer << 5) | UInt32(digit)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> bits) & 255))
                buffer &= (1 << bits) - 1
            }
        }
        guard bits == 3, buffer == 0, bytes.count == 24 else { throw AnkrError.invalidAddress }
        let payload = Data(bytes.prefix(20))
        guard !isIDMask(payload),
              bytes.suffix(4) == SuiSendCrypto.hash(Data([4, 10]) + payload, length: 4) else { throw AnkrError.invalidAddress }
        return "0x" + payload.map { String(format: "%02x", $0) }.joined()
    }

    public static func delegated(_ ethereum: String, testnet: Bool = false) throws -> String {
        let address = try IndexedEVMIdentity.address(ethereum), payload = try TronIdentity.hex(address)
        guard !isIDMask(payload) else { throw AnkrError.invalidAddress }
        let data = payload + SuiSendCrypto.hash(Data([4, 10]) + payload, length: 4)
        var buffer: UInt32 = 0, bits = 0, result = testnet ? "t410f" : "f410f"
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                result.append(Character(UnicodeScalar(alphabet[Int((buffer >> bits) & 31)])))
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { result.append(Character(UnicodeScalar(alphabet[Int((buffer << (5 - bits)) & 31)]))) }
        return result
    }

    // Reserved Ethereum ID masks resolve to f0 actors, never EAM f410 accounts.
    private static func isIDMask(_ payload: Data) -> Bool {
        payload.first == 255 && payload.dropFirst().prefix(11).allSatisfy { $0 == 0 }
    }
}
