import Foundation
import CryptoKit
import WalletCore

enum OathTokenAddress {
    static func networks(for query: String) -> [OathTokenNetwork] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count == 42, value.lowercased().hasPrefix("0x"), hex(String(value.dropFirst(2)))?.count == 20 {
            return OathTokenNetwork.all.filter { $0.chain.isEVM }
        }
        if value.count == 34, let data = Base58.decode(string: value), data.count == 21, data.first == 0x41 {
            return OathTokenNetwork.all.filter { $0.chain == .tron }
        }
        if (32...44).contains(value.count), Base58.decodeNoCheck(string: value)?.count == 32 {
            return OathTokenNetwork.all.filter { $0.chain == .solana }
        }
        return []
    }

    static func canonical(_ address: String, network: OathTokenNetwork) throws -> String {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard networks(for: address).contains(network) else { throw OathTokenLookupError.invalidAddress }
        if network.chain.isEVM {
            return checksum(address)
        }
        return address
    }

    static func checksum(_ address: String) -> String {
        let lower = String(address.dropFirst(2)).lowercased()
        let digest = Hash.keccak256(data: Data(lower.utf8)).map { String(format: "%02x", $0) }.joined()
        return "0x" + zip(lower, digest).map { character, nibble in
            Int(String(nibble), radix: 16)! >= 8 ? String(character).uppercased() : String(character)
        }.joined()
    }

    static func callAddress(_ address: String, network: OathTokenNetwork) throws -> String {
        if network.chain == .tron {
            guard let data = Base58.decode(string: address), data.count == 21, data.first == 0x41 else {
                throw OathTokenLookupError.invalidAddress
            }
            return "0x" + data.dropFirst().map { String(format: "%02x", $0) }.joined()
        }
        return try canonical(address, network: network)
    }

    static func hex(_ string: String) -> Data? {
        let text = string.hasPrefix("0x") ? String(string.dropFirst(2)) : string
        guard text.utf8.count % 2 == 0, text.utf8.count <= 131_072 else { return nil }
        let bytes = Array(text.utf8)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c { case 48...57: c - 48; case 65...70: c - 55; case 97...102: c - 87; default: nil }
        }
        var result = Data(); result.reserveCapacity(bytes.count / 2)
        for i in stride(from: 0, to: bytes.count, by: 2) {
            guard let a = nibble(bytes[i]), let b = nibble(bytes[i + 1]) else { return nil }
            result.append(a * 16 + b)
        }
        return result
    }
}

enum OathTokenABI {
    static func word(_ raw: String) throws -> Data {
        guard let data = OathTokenAddress.hex(raw), data.count == 32 else { throw OathTokenLookupError.malformedResponse }
        return data
    }
    static func decimals(_ raw: String) throws -> Int {
        let data = try word(raw)
        guard data.prefix(31).allSatisfy({ $0 == 0 }) else { throw OathTokenLookupError.malformedResponse }
        return Int(data[31])
    }
    static func string(_ raw: String) throws -> String {
        guard let data = OathTokenAddress.hex(raw) else { throw OathTokenLookupError.malformedResponse }
        let text: Data
        if data.count == 32 { // Legacy ERC-20 bytes32 name/symbol.
            text = data.prefix { $0 != 0 }
        } else {
            guard data.count >= 64, data.prefix(31).allSatisfy({ $0 == 0 }), data[31] == 32,
                  data[32..<60].allSatisfy({ $0 == 0 }) else { throw OathTokenLookupError.malformedResponse }
            let count = data[60..<64].reduce(0) { $0 * 256 + Int($1) }
            guard (1...512).contains(count), count <= data.count - 64 else { throw OathTokenLookupError.malformedResponse }
            text = data.subdata(in: 64..<(64 + count))
        }
        guard let value = String(data: text, encoding: .utf8) else { throw OathTokenLookupError.malformedResponse }
        return try clean(value)
    }
    static func clean(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\0")))
        guard !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0)
                  || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) else {
            throw OathTokenLookupError.metadataUnavailable
        }
        return value
    }

}

enum OathSolanaMetadata {
    static let program = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"
    static let tokenProgram = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
    static let token2022Program = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"

    /// Batch candidate PDAs rather than introducing a second Ed25519 library.
    /// Only a real account owned by Metaplex and containing this exact mint is
    /// accepted. Exhaust all bumps if absent; never assume an arbitrary cutoff.
    static func candidates(mint: String) throws -> [String] {
        guard let mintData = Base58.decodeNoCheck(string: mint), mintData.count == 32,
              let programData = Base58.decodeNoCheck(string: program) else { throw OathTokenLookupError.invalidAddress }
        return (0...255).reversed().map { bump in
            let seed = Data("metadata".utf8) + programData + mintData + Data([UInt8(bump)]) + programData + Data("ProgramDerivedAddress".utf8)
            return Base58.encodeNoCheck(data: Data(SHA256.hash(data: seed)))
        }
    }

    static func decode(_ data: Data, mint: String) throws -> (name: String, symbol: String) {
        guard data.count >= 65, data[0] == 4,
              Base58.encodeNoCheck(data: data.subdata(in: 33..<65)) == mint else { throw OathTokenLookupError.malformedResponse }
        var offset = 65
        func read() throws -> String {
            guard offset + 4 <= data.count else { throw OathTokenLookupError.malformedResponse }
            let count = data[offset..<(offset + 4)].enumerated().reduce(0) { $0 + (Int($1.element) << ($1.offset * 8)) }
            offset += 4
            guard count <= 512, count <= data.count - offset,
                  let text = String(data: data.subdata(in: offset..<(offset + count)), encoding: .utf8) else {
                throw OathTokenLookupError.malformedResponse
            }
            offset += count
            return try OathTokenABI.clean(text)
        }
        return try (read(), read())
    }
}
