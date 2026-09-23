import Foundation

enum BitcoinFamilyAPIError: Error, Equatable, Sendable {
    case invalidResponse
    case blockchairAddressMismatch
    case invalidPagination
    case httpFailure(Int)
    case timeout

    var diagnosticDescription: String {
        switch self {
        case .invalidResponse:
            "invalid_response"
        case .blockchairAddressMismatch:
            "blockchair_address_mismatch"
        case .invalidPagination:
            "invalid_pagination"
        case let .httpFailure(statusCode):
            "http_status=\(statusCode)"
        case .timeout:
            "timeout"
        }
    }
}

enum BitcoinFamilySyncError: Error, Sendable {
    case providersFailed(
        indexedAPI: String,
        fallbackAPI: String,
        electrum: String
    )

    var diagnosticDescription: String {
        switch self {
        case let .providersFailed(indexedAPI, fallbackAPI, electrum):
            "indexed_api=(\(indexedAPI)) fallback_api=(\(fallbackAPI)) electrum=(\(electrum))"
        }
    }
}

enum BitcoinFamilyTransactionIdentityError: Error, Sendable {
    case invalidRequest
    case invalidResponse
    case providersFailed(blockchair: String, blockCypher: String)

    var diagnosticDescription: String {
        switch self {
        case .invalidRequest:
            "invalid_request"
        case .invalidResponse:
            "invalid_response"
        case let .providersFailed(blockchair, blockCypher):
            "blockchair=(\(blockchair)) blockcypher=(\(blockCypher))"
        }
    }
}

enum BitcoinFamilyErrorDiagnostics {
    static func description(for error: Error) -> String {
        if let error = error as? BitcoinFamilyAPIError {
            return error.diagnosticDescription
        }
        if let error = error as? BitcoinFamilySyncError {
            return error.diagnosticDescription
        }
        if let error = error as? BitcoinFamilyTransactionIdentityError {
            return error.diagnosticDescription
        }
        if let error = error as? BitcoinFamilyElectrumError {
            return error.diagnosticDescription
        }
        if let error = error as? BitcoinFamilyAtomicIntegerError {
            return "atomic_integer=\(error.diagnosticDescription)"
        }
        if let error = error as? ProviderReliabilityError {
            return error.diagnosticDescription
        }
        if let error = error as? URLError {
            return "url_error_code=\(error.code.rawValue)"
        }
        let nsError = error as NSError
        return "error_domain=\(nsError.domain) error_code=\(nsError.code)"
    }
}

struct BitcoinFamilyBlockchairResponse: Decodable, Sendable {
    let data: [String: BitcoinFamilyBlockchairDashboard]
}

struct BitcoinFamilyBlockchairDashboard: Decodable, Sendable {
    let address: BitcoinFamilyBlockchairAddress
    let transactions: [BitcoinFamilyBlockchairTransaction]
}

struct BitcoinFamilyBlockchairAddress: Decodable, Sendable {
    let balance: BitcoinFamilyAtomicInteger
}

struct BitcoinFamilyBlockchairTransaction: Decodable, Sendable {
    let hash: String
    let time: String?
    let balanceChange: BitcoinFamilyAtomicInteger
    let blockID: BitcoinFamilyLosslessInt64?

    private enum CodingKeys: String, CodingKey {
        case hash
        case time
        case balanceChange = "balance_change"
        case blockID = "block_id"
    }
}

struct BitcoinFamilyLosslessInt64: Decodable, Equatable, Sendable {
    let value: Int64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self),
           let integer = Int64(string) {
            value = integer
            return
        }
        if let integer = try? container.decode(Int64.self) {
            value = integer
            return
        }
        throw BitcoinFamilyAPIError.invalidResponse
    }
}

struct BitcoinFamilyBlockCypherResponse: Decodable, Sendable {
    let finalBalance: BitcoinFamilyAtomicInteger
    let txrefs: [BitcoinFamilyBlockCypherReference]?
    let unconfirmedTxrefs: [BitcoinFamilyBlockCypherReference]?
    let hasMore: Bool?

    private enum CodingKeys: String, CodingKey {
        case finalBalance = "final_balance"
        case txrefs
        case unconfirmedTxrefs = "unconfirmed_txrefs"
        case hasMore
    }
}

struct BitcoinFamilyBlockCypherReference: Decodable, Sendable {
    let hash: String
    let height: BitcoinFamilyLosslessInt64
    let confirmed: String?
    let value: BitcoinFamilyAtomicInteger
    let inputIndex: BitcoinFamilyLosslessInt64

    private enum CodingKeys: String, CodingKey {
        case hash = "tx_hash"
        case height = "block_height"
        case confirmed
        case value
        case inputIndex = "tx_input_n"
    }
}

struct BitcoinFamilyBlockchairTransactionIdentityResponse:
    Decodable, Sendable
{
    let data: [String: BitcoinFamilyBlockchairTransactionDetails]
}

struct BitcoinFamilyBlockchairTransactionDetails: Decodable, Sendable {
    struct Transaction: Decodable, Sendable {
        let hash: String
    }

    struct Endpoint: Decodable, Sendable {
        let recipient: String?
    }

    let transaction: Transaction
    let inputs: [Endpoint]
    let outputs: [Endpoint]
}

struct BitcoinFamilyBlockCypherTransactionDetails: Decodable, Sendable {
    struct Endpoint: Decodable, Sendable {
        let addresses: [String]?
    }

    let hash: String
    let inputs: [Endpoint]
    let outputs: [Endpoint]
}
