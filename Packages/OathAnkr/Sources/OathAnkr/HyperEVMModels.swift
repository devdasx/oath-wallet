import OathArtworkSource
import Foundation

/// HyperEVM mainnet uses HYPE for gas. It is not an Ankr Advanced
/// Account API alias; its index and state providers are deliberately separate.
public enum HyperEVMIdentity {
    public static let chainID = 999
    public static let networkID = "hyperevm"
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

public struct HyperEVMToken: Codable, Sendable, Equatable {
    public let reference: String
    public let name: String
    public let symbol: String
    public let decimals: Int
    public let logo: String?
    public init(reference: String, name: String, symbol: String, decimals: Int, logo: String? = nil) throws {
        self.reference = reference == "native" ? reference : try HyperEVMIdentity.address(reference)
        guard (0...255).contains(decimals) else { throw AnkrError.invalidResponse }
        self.name = String(name.prefix(512)); self.symbol = String(symbol.prefix(128)); self.decimals = decimals
        self.logo = ArtworkSource.normalized(logo)
    }
    public static let native = try! Self(reference: "native", name: "HyperEVM", symbol: "HYPE", decimals: 18)
    static func decode(_ value: SolanaJSON) throws -> Self {
        guard value["type"].string == "ERC-20", let address = value["address_hash"].string,
              let decimals = value["decimals"].text.flatMap(Int.init) else { throw AnkrError.invalidResponse }
        return try Self(reference: address, name: value["name"].string ?? address, symbol: value["symbol"].string ?? String(address.prefix(8)), decimals: decimals, logo: value["icon_url"].string)
    }
}

public struct HyperEVMHolding: Codable, Sendable {
    public let token: HyperEVMToken
    /// A failed contract call is unknown, never zero.
    public let amount: String?
}
public struct HyperEVMInventory: Codable, Sendable {
    public let owner: String
    public let block: Int64
    public let blockHash: String
    public let observedAt: Date
    public let holdings: [HyperEVMHolding]
    public let complete: Bool
    /// Original index and RPC response bytes; request credentials are excluded.
    public let raw: Data
}
public enum HyperEVMHistoryStream: String, CaseIterable, Codable, Sendable {
    case transactions, transfers, internalTransactions = "internal-transactions"
}
public struct HyperEVMEvent: Codable, Sendable {
    public let id: String
    public let hash: String
    public let block: Int64
    public let timestamp: Double
    /// Nil only for receipt-verified logs whose contract exposes no decimals.
    /// The raw event remains durable; it must not be formatted as a guessed unit.
    public let token: HyperEVMToken?
    public let amount: String
    public let from: String
    public let to: String
    public let failed: Bool
    public let fee: String?
    public let raw: Data
}
public struct HyperEVMHistoryPage: Sendable {
    public let events: [HyperEVMEvent]
    public let next: String?
    public let raw: Data
}
public struct HyperEVMCatalog: Codable, Sendable {
    public let ids: [String: String]
    public init(ids: [String: String]) { self.ids = ids }
    public static let empty = Self(ids: [:])
    public func contains(_ reference: String) -> Bool { reference == "native" || ids[reference.lowercased()] != nil }
}
public struct HyperEVMPrice: Codable, Sendable {
    public let reference: String
    public let usd: String
    public let source: String
    public let fetchedAt: Date
}
