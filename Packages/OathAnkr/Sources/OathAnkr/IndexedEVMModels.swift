import OathArtworkSource
import Foundation

/// Mainnet identity is explicit on every inventory, page, catalog and price.
/// These networks have RPC access at ANKR, but no Advanced Account API alias.
public enum IndexedEVMChain: String, Codable, CaseIterable, Sendable {
    case unichain, monad
    public var chainID: UInt64 { self == .unichain ? 130 : 143 }
    public var name: String { self == .unichain ? "Unichain" : "Monad" }
    public var symbol: String { self == .unichain ? "ETH" : "MON" }
    public var nativeCoinID: String { self == .unichain ? "ethereum" : "monad" }
    public var rpcPath: String { rawValue + "_mainnet" }
    public var batchLimit: Int { self == .monad ? 10 : 30 }
    public var wrappedNative: String {
        self == .unichain ? "0x4200000000000000000000000000000000000006" : "0x3bd359c1119da7da1d913d1c4d2b7c461115433a"
    }
}

public enum IndexedEVMIdentity {
    public static func address(_ value: String) throws -> String {
        guard AnkrQuantity.address(value) else { throw AnkrError.invalidAddress }
        return value.lowercased()
    }
    static func amount(_ value: SolanaJSON) throws -> String {
        guard let text = value.text else { throw AnkrError.invalidResponse }
        return try AnkrQuantity.decimal(text)
    }
    static func height(_ value: SolanaJSON) throws -> Int64 {
        guard let number = Int64(try amount(value)), number >= 0 else { throw AnkrError.invalidResponse }
        return number
    }
    static func timestamp(_ value: SolanaJSON) throws -> Double {
        guard let text = value.string else { throw AnkrError.invalidResponse }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text),
              date.timeIntervalSince1970 >= 0 else { throw AnkrError.invalidResponse }
        return date.timeIntervalSince1970
    }
}

public struct IndexedEVMToken: Codable, Sendable, Equatable {
    public let reference: String
    public let name: String
    public let symbol: String
    public let decimals: Int
    public let logo: String?
    public init(reference: String, name: String, symbol: String, decimals: Int, logo: String? = nil) throws {
        self.reference = reference == "native" ? reference : try IndexedEVMIdentity.address(reference)
        guard (0...255).contains(decimals) else { throw AnkrError.invalidResponse }
        self.name = String(name.prefix(512)); self.symbol = String(symbol.prefix(128)); self.decimals = decimals
        self.logo = ArtworkSource.normalized(logo)
    }
    public static func native(_ chain: IndexedEVMChain) -> Self {
        try! Self(reference: "native", name: chain.name, symbol: chain.symbol, decimals: 18)
    }
    static func decode(_ value: SolanaJSON) throws -> Self {
        guard value["type"].string == "ERC-20", let address = value["address_hash"].string,
              let decimals = value["decimals"].text.flatMap(Int.init) else { throw AnkrError.invalidResponse }
        return try Self(reference: address, name: value["name"].string ?? address, symbol: value["symbol"].string ?? String(address.prefix(8)), decimals: decimals, logo: value["icon_url"].string)
    }
}

public struct IndexedEVMHolding: Codable, Sendable {
    public let token: IndexedEVMToken
    /// A failed contract call is unknown, never zero.
    public let amount: String?
}
public struct IndexedEVMInventory: Codable, Sendable {
    public let chain: IndexedEVMChain
    public let owner: String
    public let block: Int64
    public let blockHash: String
    public let observedAt: Date
    public let holdings: [IndexedEVMHolding]
    public let complete: Bool
    /// Original index and RPC response bytes; request credentials are excluded.
    public let raw: Data
}
public enum IndexedEVMHistoryStream: String, CaseIterable, Codable, Sendable {
    case transactions, transfers, internalTransactions = "internal-transactions"
}
public extension IndexedEVMChain {
    /// Alchemy indexes external and ERC-20 transfers on Monad, but explicitly
    /// rejects internal transfers. Do not claim that unsupported stream is empty.
    var historyStreams: [IndexedEVMHistoryStream] {
        self == .monad ? [.transactions, .transfers] : IndexedEVMHistoryStream.allCases
    }
}
public struct IndexedEVMEvent: Codable, Sendable {
    public let id: String
    public let hash: String
    public let block: Int64
    public let timestamp: Double
    /// Nil only for receipt-verified logs whose contract exposes no decimals.
    /// The raw event remains durable; it must not be formatted as a guessed unit.
    public let token: IndexedEVMToken?
    public let amount: String
    public let from: String
    public let to: String
    public let failed: Bool
    public let fee: String?
    public let raw: Data
}
public struct IndexedEVMHistoryPage: Sendable {
    public let chain: IndexedEVMChain
    public let events: [IndexedEVMEvent]
    public let next: String?
    public let raw: Data
}
public struct IndexedEVMCatalog: Codable, Sendable {
    public let chain: IndexedEVMChain
    public let ids: [String: String]
    public init(chain: IndexedEVMChain, ids: [String: String]) { self.chain = chain; self.ids = ids }
    public static func empty(_ chain: IndexedEVMChain) -> Self { Self(chain: chain, ids: [:]) }
    public func contains(_ reference: String) -> Bool { reference == "native" || ids[reference.lowercased()] != nil }
}
public struct IndexedEVMPrice: Codable, Sendable {
    public let chain: IndexedEVMChain
    public let reference: String
    public let usd: String
    public let source: String
    public let fetchedAt: Date
}
