import OathArtworkSource
import Foundation

/// Mainnet identity is explicit on every inventory, page, catalog and price.
/// These networks have RPC access at ANKR, but no Advanced Account API alias.
public enum IndexedEVMChain: String, Codable, CaseIterable, Sendable {
    case unichain, monad, celo, chiliz, filecoin, sei, zerog, iotex
    public var chainID: UInt64 { switch self { case .unichain: 130; case .monad: 143; case .iotex: 4689; case .zerog: 16661; case .sei: 1329; case .filecoin: 314; case .chiliz: 88888; case .celo: 42220 } }
    public var name: String { switch self { case .unichain: "Unichain"; case .monad: "Monad"; case .iotex: "IoTeX"; case .zerog: "0G"; case .sei: "Sei"; case .filecoin: "Filecoin"; case .chiliz: "Chiliz"; case .celo: "Celo" } }
    public var symbol: String { switch self { case .unichain: "ETH"; case .monad: "MON"; case .iotex: "IOTX"; case .zerog: "0G"; case .sei: "SEI"; case .filecoin: "FIL"; case .chiliz: "CHZ"; case .celo: "CELO" } }
    public var nativeCoinID: String { self == .zerog ? "zero-gravity" : self == .unichain ? "ethereum" : self == .sei ? "sei-network" : rawValue }
    public var rpcPath: String { self == .zerog ? "0g_mainnet_evm" : self == .sei ? "sei_evm" : [.celo, .chiliz, .filecoin, .iotex].contains(self) ? rawValue : rawValue + "_mainnet" }
    public var catalogPlatform: String { self == .zerog ? "0g" : self == .sei ? "sei-v2" : rawValue }
    public var dexNetwork: String { self == .zerog ? "0g" : self == .sei ? "seiv2" : rawValue }
    public var batchLimit: Int { self == .monad ? 10 : 30 }
    /// CELO's ERC-20 interface is the native balance, not a second holding.
    public var nativeERC20: String? { self == .celo ? "0x471ece3750da237f93b8e339c536989b8978a438" : nil }
    public var wrappedNative: String {
        switch self {
        case .unichain: "0x4200000000000000000000000000000000000006"
        case .monad: "0x3bd359c1119da7da1d913d1c4d2b7c461115433a"
        case .chiliz: "0x677f7e16c7dd57be1d4c8ad1244883214953dc47"
        case .iotex: "0xa00744882684c3e4747faefd68d283ea44099d03"
        case .zerog: "0x1cd0690ff9a693f5ef2dd976660a8dafc81a109c"
        case .sei: "0xe30fedd158a2e3b13e9badaeabafc5516e95e8c7"
        case .filecoin: "0x60e1773636cf5e4a227d9ac24f20feca034ee25a"
        case .celo: "0x471ece3750da237f93b8e339c536989b8978a438"
        }
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
    /// Optional Celo fee-currency units, independent of native CELO.
    public var feeCurrency: IndexedEVMToken? = nil
    public var feeCurrencyAmount: String? = nil
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
