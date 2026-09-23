import Foundation

struct TronScanNativeHistoryEnvelope: Decodable, Sendable {
    let data: [TronScanNativeTransfer]
    let pageSize: Int?

    private enum CodingKeys: String, CodingKey {
        case data
        case pageSize = "page_size"
    }
}

struct TronScanNativeTransfer: Decodable, Sendable {
    let amount: String
    let blockTimestamp: Double
    let block: Int64?
    let from: String
    let to: String
    let transactionID: String
    let confirmed: Int?
    let contractType: String?
    let revert: Int?
    let contractResult: String?

    private enum CodingKeys: String, CodingKey {
        case amount, block, from, to, confirmed, revert
        case blockTimestamp = "block_timestamp"
        case transactionID = "hash"
        case contractType = "contract_type"
        case contractResult = "contract_ret"
    }
}

struct TronScanTokenHistoryEnvelope: Decodable, Sendable {
    let transfers: [TronScanTokenTransfer]
    let total: Int?

    private enum CodingKeys: String, CodingKey {
        case transfers = "token_transfers"
        case total
    }
}

struct TronScanTokenTransfer: Decodable, Sendable {
    struct TokenInfo: Decodable, Sendable {
        let identity: String?
        let symbol: String?
        let name: String?
        let decimals: Int?

        private enum CodingKeys: String, CodingKey {
            case identity = "tokenId"
            case symbol = "tokenAbbr"
            case name = "tokenName"
            case decimals = "tokenDecimal"
        }
    }

    let transactionID: String
    let blockTimestamp: Double
    let from: String
    let to: String
    let block: Int64?
    let contractAddress: String
    let atomicAmount: String
    let eventType: String
    let confirmed: Bool
    let contractResult: String?
    let reverted: Bool?
    let tokenInfo: TokenInfo

    private enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case blockTimestamp = "block_ts"
        case from = "from_address"
        case to = "to_address"
        case block
        case contractAddress = "contract_address"
        case atomicAmount = "quant"
        case eventType = "event_type"
        case confirmed
        case contractResult = "contractRet"
        case reverted = "revert"
        case tokenInfo
    }
}
