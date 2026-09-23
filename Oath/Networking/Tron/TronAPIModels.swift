import Foundation

enum TronHistoryError: Error, Equatable, Sendable {
    case unsuccessfulResponse

    var diagnosticDescription: String {
        switch self {
        case .unsuccessfulResponse:
            "unsuccessful_response"
        }
    }
}

struct TronRPCRequest: Encodable, Sendable {
    let jsonrpc = "2.0"
    let method: String
    let params: [TronJSONValue]
    let id: Int
}

struct TronRPCResponse: Decodable, Sendable {
    let id: Int?
    let result: String?
    let error: TronRPCError?
}

struct TronRPCError: Decodable, Error, Sendable {
    let code: Int
    let message: String
}

enum TronJSONValue: Codable, Sendable {
    case string(String)
    case object([String: TronJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .object(
                try container.decode([String: TronJSONValue].self)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

struct TronGridEnvelope<Record: Decodable & Sendable>: Decodable, Sendable {
    let data: [Record]
    let success: Bool
    let meta: TronGridMetadata?
}

struct TronGridMetadata: Decodable, Sendable {
    let fingerprint: String?
}

struct TronGridTokenTransfer: Decodable, Sendable {
    struct TokenInfo: Decodable, Sendable {
        let symbol: String?
        let address: String?
        let decimals: Int?
        let name: String?
    }

    let transactionID: String
    let tokenInfo: TokenInfo
    let blockTimestamp: Double
    let from: String
    let to: String
    let type: String
    let value: String

    private enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case tokenInfo = "token_info"
        case blockTimestamp = "block_timestamp"
        case from, to, type, value
    }
}

struct TronGridTransaction: Decodable, Sendable {
    struct ReturnValue: Decodable, Sendable {
        let contractRet: String?
        let fee: Int64?
    }

    struct RawData: Decodable, Sendable {
        struct Contract: Decodable, Sendable {
            struct Parameter: Decodable, Sendable {
                struct Value: Decodable, Sendable {
                    let ownerAddress: String?
                    let toAddress: String?
                    let amount: Int64?
                    let assetName: String?

                    private enum CodingKeys: String, CodingKey {
                        case ownerAddress = "owner_address"
                        case toAddress = "to_address"
                        case amount
                        case assetName = "asset_name"
                    }
                }

                let value: Value
            }

            let type: String
            let parameter: Parameter
        }

        let contract: [Contract]
    }

    let txID: String
    let blockNumber: Int64?
    let blockTimestamp: Double
    let ret: [ReturnValue]?
    let rawData: RawData

    private enum CodingKeys: String, CodingKey {
        case txID, blockNumber
        case blockTimestamp = "block_timestamp"
        case ret
        case rawData = "raw_data"
    }
}
