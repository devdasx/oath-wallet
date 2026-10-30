import Foundation

public enum PolkadotError: Error, Sendable, Equatable {
    case configuration, invalidAddress, malformed, wrongNetwork, incompleteInventory, paginationLoop, unavailable
    case http(Int), rpc(Int)
}

public enum PolkadotIdentity {
    public static let genesis = "0x68d56f15f85d3136970ec16946040bc1752654e906147f7e43e9d539d7c3de2f"
    public static let relayGenesis = "0x91b171bb158e2d3848fa23a9f1c25182fb8e20313b2c1eb49219da7a70ce90c3"
    public static func reference(_ value: String) throws -> String {
        if let id = UInt32(value), String(id) == value { return "assets:" + value }
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw PolkadotError.malformed }
        if ["assets", "pool"].contains(parts[0]), let id = UInt32(parts[1]), String(id) == parts[1] { return value }
        if parts[0] == "foreign", try bytes(parts[1]).count == 32 { return "foreign:" + parts[1].lowercased() }
        throw PolkadotError.malformed
    }
    public static func publicKey(_ address: String) throws -> Data {
        guard (35...48).contains(address.count), let data = try? SuiSendCrypto.unbase58(address), data.count == 35,
              data.first == 0 || data.first == 42,
              data.suffix(2) == SuiSendCrypto.hash(Data("SS58PRE".utf8) + data.prefix(33), length: 64).prefix(2) else { throw PolkadotError.invalidAddress }
        return Data(data.dropFirst().prefix(32))
    }
    public static func address(_ value: String) throws -> String { try address(publicKey: publicKey(value)) }
    public static func address(publicKey: Data) throws -> String {
        guard publicKey.count == 32 else { throw PolkadotError.invalidAddress }
        let body = Data([0]) + publicKey
        return SuiSendCrypto.base58(body + SuiSendCrypto.hash(Data("SS58PRE".utf8) + body, length: 64).prefix(2))
    }
    static func hex(_ data: Data) -> String { "0x" + data.map { String(format:"%02x", $0) }.joined() }
    static func bytes(_ value: String) throws -> Data {
        let bytes = Array(value.utf8)
        guard bytes.count >= 2, bytes[0] == 48, bytes[1] == 120, bytes.count % 2 == 0, bytes.count <= 16_000_002 else { throw PolkadotError.malformed }
        func nibble(_ byte: UInt8) throws -> UInt8 {
            switch byte { case 48...57: return byte-48; case 65...70: return byte-55; case 97...102: return byte-87; default: throw PolkadotError.malformed }
        }
        var result = Data(); result.reserveCapacity((bytes.count-2)/2)
        for i in stride(from:2,to:bytes.count,by:2) { result.append(try nibble(bytes[i]) << 4 | nibble(bytes[i+1])) }
        return result
    }
    static func concat(_ data: Data) -> Data { SuiSendCrypto.hash(data, length: 16) + data }
    static func uint(_ data: Data) -> String {
        var value = "0"
        for byte in data.reversed() {
            for _ in 0..<8 { value = SuiIdentity.add(value, value) }
            value = SuiIdentity.add(value, String(byte))
        }
        return value
    }
    static func number(_ value: SolanaJSON) throws -> Int64 {
        guard let text = value.text, let n = Int64(text), n >= 0 else { throw PolkadotError.malformed }; return n
    }
    static func amount(_ value: SolanaJSON) throws -> String {
        guard let text = value.text, !text.isEmpty, text.count <= 39, text.utf8.allSatisfy({ (48...57).contains($0) }) else { throw PolkadotError.malformed }
        let n = String(text.drop(while: { $0 == "0" })); return n.isEmpty ? "0" : n
    }
}

public struct PolkadotToken: Codable, Sendable, Equatable {
    public let reference: String, name: String, symbol: String
    public let decimals: Int
    /// SCALE-encoded pallet key, retained exactly for foreign XCM locations.
    public let pallet: String, key: Data
    public static let native = Self(reference: "native", name: "Polkadot", symbol: "DOT", decimals: 10, pallet: "System", key: Data())
    public init(reference: String, name: String, symbol: String, decimals: Int, pallet: String, key: Data) {
        self.reference = reference; self.name = name; self.symbol = symbol; self.decimals = decimals; self.pallet = pallet; self.key = key
    }
    public var coinGeckoID: String? {
        switch reference {
        case "native": "polkadot"
        case "assets:1984": decimals == 6 ? "tether" : nil
        case "assets:1337": decimals == 6 ? "usd-coin" : nil
        default: nil
        }
    }
}
public struct PolkadotHolding: Codable, Sendable {
    public let token: PolkadotToken, amount: String
    public let frozen: Bool
    public init(token: PolkadotToken, amount: String, frozen: Bool = false) { self.token = token; self.amount = amount; self.frozen = frozen }
}
public struct PolkadotInventory: Codable, Sendable {
    public let owner: String, blockHash: String
    public let height: Int64
    public let holdings: [PolkadotHolding]
    public let observedAt: Date
    public init(owner: String, blockHash: String, height: Int64, holdings: [PolkadotHolding], observedAt: Date = .now) {
        self.owner = owner; self.blockHash = blockHash; self.height = height; self.holdings = holdings; self.observedAt = observedAt
    }
}
public struct PolkadotEvent: Codable, Sendable {
    public let id: String, transaction: String, reference: String, amount: String, from: String, to: String
    public let height: Int64, timestamp: Double
    public let successful: Bool
    public let token: PolkadotToken?
}
public struct PolkadotHistoryPage: Sendable {
    public let events: [PolkadotEvent], next: Int?
    public let oldestHeight: Int64?
    public init(events: [PolkadotEvent], next: Int?, oldestHeight: Int64? = nil) { self.events = events; self.next = next; self.oldestHeight = oldestHeight }
}
public struct PolkadotPrice: Codable, Sendable {
    public let reference: String, usd: String, source: String
    public let observedAt: Date
}

enum PolkadotStorage {
    static let pallets = ["Assets": "682a59d51ab9e48a8c8cc418ff9708d2", "ForeignAssets": "30e64a56026f4b5e3c2d196283a9a17d", "PoolAssets": "4db06ba1ca6f18b1edb06ff082d24409"]
    static let account = "b99d880ec681799c0cf30e8886371da9", metadata = "b5f3822e35ca2f31ce3526eab1363fd2", asset = "d34371a193a751eea5883e9553457b2e"
    static func nativeKey(_ owner: String) throws -> String {
        "0x26aa394eea5630e07c48ae0c9558cef7" + account + PolkadotIdentity.hex(PolkadotIdentity.concat(try PolkadotIdentity.publicKey(owner))).dropFirst(2)
    }
    static func accountKey(_ token: PolkadotToken, owner: String) throws -> String {
        guard let prefix = pallets[token.pallet] else { throw PolkadotError.malformed }
        return "0x" + prefix + account + PolkadotIdentity.hex(PolkadotIdentity.concat(token.key) + PolkadotIdentity.concat(try PolkadotIdentity.publicKey(owner))).dropFirst(2)
    }
    static func native(_ value: SolanaJSON) throws -> String {
        if value.isNull { return "0" }
        guard let hex = value.string else { throw PolkadotError.malformed }
        let bytes = try PolkadotIdentity.bytes(hex)
        guard bytes.count == 80 else { throw PolkadotError.malformed }
        return SuiIdentity.add(PolkadotIdentity.uint(bytes.subdata(in: 16..<32)), PolkadotIdentity.uint(bytes.subdata(in: 32..<48)))
    }
    static func holding(_ value: SolanaJSON, token: PolkadotToken) throws -> PolkadotHolding? {
        if value.isNull { return nil }
        guard let hex = value.string else { throw PolkadotError.malformed }
        let bytes = try PolkadotIdentity.bytes(hex)
        guard bytes.count >= 18, bytes.count <= 80, bytes[16] <= 2 else { throw PolkadotError.malformed }
        return .init(token: token, amount: PolkadotIdentity.uint(bytes.prefix(16)), frozen: bytes[16] != 0)
    }
    static func token(key storageKey: String, value: SolanaJSON, pallet: String) throws -> PolkadotToken {
        guard let prefix = pallets[pallet], storageKey.hasPrefix("0x" + prefix + metadata), let raw = value.string else { throw PolkadotError.malformed }
        let keyBytes = try PolkadotIdentity.bytes(storageKey), key = Data(keyBytes.dropFirst(48))
        guard keyBytes.count > 48, keyBytes.count <= 512, keyBytes.subdata(in: 32..<48) == SuiSendCrypto.hash(key, length: 16) else { throw PolkadotError.malformed }
        let reference: String
        if pallet == "ForeignAssets" { reference = "foreign:" + PolkadotIdentity.hex(SuiSendCrypto.hash(key)) }
        else {
            guard key.count == 4 else { throw PolkadotError.malformed }
            reference = (pallet == "Assets" ? "assets:" : "pool:") + PolkadotIdentity.uint(key)
        }
        let data = Array(try PolkadotIdentity.bytes(raw)); var offset = 16
        func string() throws -> String {
            guard offset < data.count else { throw PolkadotError.malformed }
            let first = Int(data[offset]); offset += 1; let length: Int
            switch first & 3 {
            case 0: length = first >> 2
            case 1:
                guard offset < data.count else { throw PolkadotError.malformed }; length = (first | Int(data[offset]) << 8) >> 2; offset += 1
            default: throw PolkadotError.malformed
            }
            guard length <= 1024, offset + length <= data.count else { throw PolkadotError.malformed }
            defer { offset += length }
            return String(decoding: data[offset..<offset+length], as: UTF8.self).filter { !$0.unicodeScalars.contains(where: { $0.value < 32 }) }
        }
        let name = try string(), symbol = try string()
        guard offset + 2 == data.count, data[offset+1] <= 1 else { throw PolkadotError.malformed }
        return .init(reference: reference, name: name.isEmpty ? reference : name, symbol: symbol.isEmpty ? reference : symbol, decimals: Int(data[offset]), pallet: pallet, key: key)
    }
}
