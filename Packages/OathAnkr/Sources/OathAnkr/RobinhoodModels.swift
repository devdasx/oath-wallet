import OathArtworkSource
import Foundation

/// Robinhood mainnet is an ETH-gas EVM chain. It is not an Ankr Advanced
/// Account API alias; its index and state providers are deliberately separate.
public enum RobinhoodIdentity {
    public static let chainID = 4663
    public static let networkID = "robinhood"
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

public struct RobinhoodToken: Codable, Sendable, Equatable {
    public let reference: String
    public let name: String
    public let symbol: String
    public let decimals: Int
    public let logo: String?
    public init(reference: String, name: String, symbol: String, decimals: Int, logo: String? = nil) throws {
        self.reference = reference == "native" ? reference : try RobinhoodIdentity.address(reference)
        guard (0...255).contains(decimals) else { throw AnkrError.invalidResponse }
        self.name = String(name.prefix(512)); self.symbol = String(symbol.prefix(128)); self.decimals = decimals
        self.logo = ArtworkSource.normalized(logo)
    }
    public static let native = try! Self(reference: "native", name: "Robinhood Chain", symbol: "ETH", decimals: 18)
    static func decode(_ value: SolanaJSON) throws -> Self {
        guard value["type"].string == "ERC-20", let address = value["address_hash"].string,
              let name = value["name"].string, let symbol = value["symbol"].string,
              let decimals = value["decimals"].text.flatMap(Int.init) else { throw AnkrError.invalidResponse }
        return try Self(reference: address, name: name, symbol: symbol, decimals: decimals, logo: value["icon_url"].string)
    }
}

public struct RobinhoodHolding: Codable, Sendable {
    public let token: RobinhoodToken
    /// A failed contract call is unknown, never zero.
    public let amount: String?
}
public struct RobinhoodInventory: Codable, Sendable {
    public let owner: String
    public let block: Int64
    public let blockHash: String
    public let observedAt: Date
    public let holdings: [RobinhoodHolding]
    public let complete: Bool
    /// Original index and RPC response bytes; request credentials are excluded.
    public let raw: Data
}
public enum RobinhoodHistoryStream: String, CaseIterable, Codable, Sendable {
    case transactions, transfers, internalTransactions = "internal-transactions"
}
public struct RobinhoodEvent: Codable, Sendable {
    public let id: String
    public let hash: String
    public let block: Int64
    public let timestamp: Double
    public let token: RobinhoodToken
    public let amount: String
    public let from: String
    public let to: String
    public let failed: Bool
    public let fee: String?
    public let raw: Data
}
public struct RobinhoodHistoryPage: Sendable {
    public let events: [RobinhoodEvent]
    public let next: String?
    public let raw: Data
}
public struct RobinhoodCatalog: Codable, Sendable {
    public let ids: [String: String]
    public init(ids: [String: String]) { self.ids = ids }
    public static let empty = Self(ids: [:])
    public func contains(_ reference: String) -> Bool { reference == "native" || ids[reference.lowercased()] != nil }
}
public struct RobinhoodPrice: Codable, Sendable {
    public let reference: String
    public let usd: String
    public let source: String
    public let fetchedAt: Date
}
