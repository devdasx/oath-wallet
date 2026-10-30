import Foundation

/// Transparent Litecoin destinations only. Decode with the selected network;
/// historical P2SH aliases are accepted without guessing another chain.
enum LitecoinAddress {
    static func encode(script: Data, network: BitcoinSendNetwork) throws -> String {
        guard [.mainnet, .testnet, .regtest].contains(network),
              BitcoinSendPlan.standardScript(script) else { throw BitcoinSendError.invalidRecipient }
        let main = network == .mainnet
        if script.count == 25 { return Base58Check.encode(Data([main ? 48 : 111]) + script.dropFirst(3).prefix(20)) }
        if script.count == 23 { return Base58Check.encode(Data([main ? 50 : 58]) + script.dropFirst(2).prefix(20)) }
        return SegwitAddress.encode(hrp: hrp(network), version: script.first == 0 ? 0 : 1, program: script.dropFirst(2))
    }

    static func decode(_ address: String, network: BitcoinSendNetwork) throws -> Data {
        guard [.mainnet, .testnet, .regtest].contains(network), !address.isEmpty, address.utf8.count <= 90 else {
            throw BitcoinSendError.invalidRecipient
        }
        if let payload = try? Base58Check.decode(address), payload.count == 21 {
            let main = network == .mainnet
            if payload.first == (main ? 48 : 111) { return Data([0x76,0xa9,20]) + payload.dropFirst() + Data([0x88,0xac]) }
            if [UInt8(main ? 50 : 58), main ? 5 : 196].contains(payload.first!) {
                return Data([0xa9,20]) + payload.dropFirst() + Data([0x87])
            }
            throw BitcoinSendError.invalidRecipient
        }
        guard address == address.lowercased() || address == address.uppercased() else { throw BitcoinSendError.invalidRecipient }
        let lower = address.lowercased(), prefix = hrp(network)
        guard lower.hasPrefix(prefix + "1") else { throw BitcoinSendError.invalidRecipient }
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
        let values = try lower.dropFirst(prefix.count + 1).utf8.map { byte -> UInt8 in
            guard let i = alphabet.firstIndex(of: byte) else { throw BitcoinSendError.invalidRecipient }
            return UInt8(i)
        }
        guard values.count >= 7, let version = values.first, version <= 1 else { throw BitcoinSendError.invalidRecipient }
        var accumulator: UInt32 = 0, bits = 0, program = Data()
        for value in values.dropFirst().dropLast(6) {
            accumulator = ((accumulator << 5) | UInt32(value)) & 0x0fff; bits += 5
            if bits >= 8 { bits -= 8; program.append(UInt8((accumulator >> bits) & 255)) }
        }
        guard bits < 5, ((accumulator << (8 - bits)) & 255) == 0,
              (version == 0 && [20,32].contains(program.count)) || (version == 1 && program.count == 32),
              // Re-encoding verifies the complete checksum and its required
              // BIP173 (v0) / BIP350 (v1) variant, not just the payload.
              SegwitAddress.encode(hrp: prefix, version: version, program: program) == lower else { throw BitcoinSendError.invalidRecipient }
        return Data([version == 0 ? 0 : 0x51, UInt8(program.count)]) + program
    }
    private static func hrp(_ network: BitcoinSendNetwork) -> String {
        network == .mainnet ? "ltc" : network == .regtest ? "rltc" : "tltc"
    }
}
