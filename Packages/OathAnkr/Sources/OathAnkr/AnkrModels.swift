import Foundation

/// Explicit aliases prevent unsupported networks or testnet money entering a
/// mainnet wallet. Coverage is method-specific, not the ordinary RPC catalog.
public enum AnkrChain: String, CaseIterable, Codable, Sendable {
    case arbitrum, avalanche, base, bsc, eth, fantom, flare, gnosis, linea, optimism, polygon, scroll
    case somnia = "somnia_mainnet", story = "story_mainnet"
    case taiko, telos, xlayer
    public var networkID: String {
        switch self { case .eth: "ethereum"; case .bsc: "bnb"; case .somnia: "somnia"; case .story: "story"; default: rawValue }
    }
    public init?(networkID: String) {
        guard let value = Self.allCases.first(where: { $0.networkID == networkID }) else { return nil }
        self = value
    }
}

public enum AnkrError: Error, Equatable, Sendable {
    case configurationMissing, invalidAddress, invalidResponse, wrongAccount, wrongChain
    case http(Int), rpc(Int), transport, responseTooLarge, paginationLoop, incompleteInventory
}

public struct AnkrSyncStatus: Codable, Sendable, Equatable {
    public let timestamp: Double?
    public let blockNumber: Int64?
    public let lag: String?
    public let status: String?

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decodeIfPresent(Double.self, forKey: .timestamp)
        blockNumber = try c.decodeIfPresent(Int64.self, forKey: .blockNumber)
        lag = try c.decodeIfPresent(String.self, forKey: .lag)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        guard timestamp.map({ $0.isFinite && $0 >= 0 && $0 <= Double(Int.max / 2) }) ?? true,
              blockNumber.map({ $0 >= 0 }) ?? true else { throw AnkrError.invalidResponse }
    }
}

public struct AnkrAsset: Codable, Sendable, Equatable {
    public let blockchain: String
    public let tokenName: String
    public let tokenSymbol: String
    public let tokenDecimals: Int
    public let tokenType: String
    public let contractAddress: String
    public let holderAddress: String
    public let balance: String
    public let balanceRawInteger: String
    public let balanceUsd: String
    public let tokenPrice: String
    public let thumbnail: String?
    public var reference: String { tokenType == "NATIVE" ? "native" : contractAddress.lowercased() }
}

public struct AnkrBalanceResult: Decodable, Sendable {
    public let totalBalanceUsd: String
    public let totalCount: Int?
    public let assets: [AnkrAsset]
    public let nextPageToken: String?
    public let syncStatus: AnkrSyncStatus?
}

public struct AnkrTransaction: Decodable, Sendable {
    public let blockchain: String
    public let hash: String
    public let from: String
    public let to: String?
    public let value: String
    public let blockNumber: String?
    public let blockHash: String?
    public let timestamp: String?
    public let status: String?
    public let gasUsed: String?
    public let gasPrice: String?
    public let effectiveGasPrice: String?
    public let nonce: String?
    public let input: String?
    // Nonprojected fields (logs, signatures, L2 fees, decoded
    // calls and future additions) are retained in the original response bytes.
}

public struct AnkrTransfer: Decodable, Sendable {
    public let blockchain: String
    public let fromAddress: String
    public let toAddress: String
    public let contractAddress: String
    public let value: String
    public let valueRawInteger: String
    public let tokenName: String
    public let tokenSymbol: String
    public let tokenDecimals: Int
    public let thumbnail: String?
    public let transactionHash: String
    public let blockHeight: Int64
    public let logIndex: Int
    public let timestamp: Double
    public let direction: String?
}

public struct AnkrTransactionResult: Decodable, Sendable {
    public let transactions: [AnkrTransaction]
    public let nextPageToken: String?
    public let syncStatus: AnkrSyncStatus?
}
public struct AnkrTransferResult: Decodable, Sendable {
    public let transfers: [AnkrTransfer]
    public let nextPageToken: String?
    public let syncStatus: AnkrSyncStatus?
}
public struct AnkrPage<Value: Sendable>: Sendable {
    public let value: Value
    /// Exact JSON-RPC envelope, including unknown properties and numeric
    /// spellings. Credentials and request URLs are never part of this data.
    public let raw: Data
    public let fetchedAt: Date
}

/// Decimal integer conversion without Double/Decimal rounding at 256 bits.
public enum AnkrQuantity {
    public static func decimal(_ input: String) throws -> String {
        if input.hasPrefix("0x") {
            let hex = input.dropFirst(2)
            guard !hex.isEmpty, hex.utf8.count <= 64, hex.utf8.allSatisfy(isASCIIHex) else { throw AnkrError.invalidResponse }
            var digits = [0]
            for char in hex {
                guard let value = char.hexDigitValue else { throw AnkrError.invalidResponse }
                var carry = value
                for i in digits.indices { let n = digits[i] * 16 + carry; digits[i] = n % 10; carry = n / 10 }
                while carry > 0 { digits.append(carry % 10); carry /= 10 }
            }
            while digits.count > 1, digits.last == 0 { digits.removeLast() }
            return digits.reversed().map(String.init).joined()
        }
        guard !input.isEmpty, input.count <= 78, input.utf8.allSatisfy({ (48...57).contains($0) }) else { throw AnkrError.invalidResponse }
        let result = input.drop(while: { $0 == "0" })
        return result.isEmpty ? "0" : String(result)
    }
    public static func multiply(_ lhs: String, _ rhs: String) throws -> String {
        let a = try decimal(lhs).reversed().map { Int(String($0))! }
        let b = try decimal(rhs).reversed().map { Int(String($0))! }
        var result = [Int](repeating: 0, count: a.count + b.count + 1)
        for i in a.indices { for j in b.indices { result[i+j] += a[i] * b[j] } }
        for i in 0..<(result.count-1) { result[i+1] += result[i] / 10; result[i] %= 10 }
        while result.count > 1, result.last == 0 { result.removeLast() }
        let value = result.reversed().map(String.init).joined()
        guard value.count <= 78 else { throw AnkrError.invalidResponse }
        return value
    }
    public static func address(_ value: String) -> Bool {
        value.utf8.count == 42 && value.hasPrefix("0x") && value.utf8.dropFirst(2).allSatisfy(isASCIIHex)
    }
    public static func hash(_ value: String) -> Bool {
        value.utf8.count == 66 && value.hasPrefix("0x") && value.utf8.dropFirst(2).allSatisfy(isASCIIHex)
    }
    private static func isASCIIHex(_ c: UInt8) -> Bool { (48...57).contains(c) || (65...70).contains(c) || (97...102).contains(c) }
}
