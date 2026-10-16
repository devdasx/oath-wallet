import OathArtworkSource
import Foundation

/// Arc mainnet. The ERC-20 USDC precompile exposes the SAME native balance
/// at a different precision. System Transfer logs are the authoritative stream.
public enum ArcIdentity {
    public static let chainID = 5042
    public static let usdc = "0x3600000000000000000000000000000000000000"
    public static let systemEmitter = "0xfffffffffffffffffffffffffffffffffffffffe"
    public static let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
    public static func address(_ value: String) throws -> String {
        guard AnkrQuantity.address(value) else { throw AnkrError.invalidAddress }
        return value.lowercased()
    }
    public static func reference(_ value: String) throws -> String {
        if value == "native" { return value }
        let address = try address(value)
        return address == usdc || address == systemEmitter ? "native" : address
    }
    static func amount(_ value: SolanaJSON) throws -> String {
        guard let text = value.text else { throw AnkrError.invalidResponse }
        return try AnkrQuantity.decimal(text)
    }
    static func height(_ value: SolanaJSON) throws -> Int64 {
        guard let n = Int64(try amount(value)), n >= 0 else { throw AnkrError.invalidResponse }
        return n
    }
    /// Truncation is intentional: the ERC-20 view cannot represent native dust.
    public static func erc20Units(native: String) throws -> String {
        let units = try AnkrQuantity.decimal(native)
        return units.count > 12 ? String(units.dropLast(12)) : "0"
    }
}

public struct ArcToken: Codable, Sendable, Equatable {
    public let reference: String
    public let name: String
    public let symbol: String
    public let decimals: Int
    public let logo: String?
    public init(reference: String, name: String, symbol: String, decimals: Int, logo: String? = nil) throws {
        self.reference = try ArcIdentity.reference(reference)
        guard (0...255).contains(decimals) else { throw AnkrError.invalidResponse }
        if self.reference == "native" {
            self.name = "USDC"; self.symbol = "USDC"; self.decimals = 18; self.logo = nil
        } else {
            self.name = try TronIdentity.clean(name, limit: 512)
            self.symbol = try TronIdentity.clean(symbol, limit: 128)
            self.decimals = decimals
            self.logo = ArtworkSource.normalized(logo)
        }
    }
    public static let native = try! Self(reference: "native", name: "USDC", symbol: "USDC", decimals: 18)
}
public struct ArcHolding: Codable, Sendable {
    public let token: ArcToken
    public let amount: String?
}
public struct ArcInventory: Codable, Sendable {
    public let owner: String
    public let block: Int64
    public let blockHash: String
    public let observedAt: Date
    public let holdings: [ArcHolding]
    /// Only the specified contract set was read. Discovery coverage is stored
    /// separately; a successful batch never proves all tokens were discovered.
    public let complete: Bool
    public let raw: Data
}
public struct ArcTransaction: Codable, Sendable {
    public let hash: String
    public let block: Int64
    public let timestamp: Double
    public let from: String
    public let to: String?
    public let failed: Bool
    public let fee: String
    public let raw: Data
}
public struct ArcEvent: Codable, Sendable, Equatable {
    public let id: String
    public let hash: String
    public let logIndex: Int
    public let token: ArcToken
    public let amount: String
    public let from: String
    public let to: String
}
public struct ArcHistoryPage: Sendable {
    public let fromBlock: Int64
    public let nextBlock: Int64
    public let transactions: [ArcTransaction]
    public let events: [ArcEvent]
    public let raw: Data
}
public struct ArcCatalog: Codable, Sendable {
    public let ids: [String: String]
    public init(ids: [String: String]) { self.ids = ids }
    public static let empty = Self(ids: [:])
    /// Public CoinGecko contract identities captured 2026-10-12, never balances
    /// or prices. Fresh/cached catalogs take precedence; this only bootstraps an
    /// initial request during an outage. New contracts remain index-discovered.
    public static var bootstrap: Self {
        guard let url = Bundle.module.url(forResource:"ArcCatalog",withExtension:"json"),
              let data = try? Data(contentsOf:url), let catalog = try? JSONDecoder().decode(Self.self,from:data) else { return .empty }
        return catalog
    }
    public func contains(_ reference: String) -> Bool { reference == "native" || ids[reference] != nil }
}
public struct ArcPrice: Codable, Sendable {
    public let reference: String
    public let usd: String
    public let source: String
    public let fetchedAt: Date
}
