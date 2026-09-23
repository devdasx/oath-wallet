import Foundation

struct NEARNearBlocksPage<Item: Decodable & Sendable>: Decodable, Sendable {
    struct Metadata: Decodable, Sendable {
        let nextPage: String?

        enum CodingKeys: String, CodingKey {
            case nextPage = "next_page"
        }
    }

    let data: [Item]
    let meta: Metadata?
}

struct NEARNearBlocksBlock: Decodable, Sendable {
    let blockHeight: String
    let blockTimestamp: String

    enum CodingKeys: String, CodingKey {
        case blockHeight = "block_height"
        case blockTimestamp = "block_timestamp"
    }
}

struct NEARNearBlocksAction: Decodable, Sendable {
    let action: String
}

struct NEARNearBlocksAggregate: Decodable, Sendable {
    let deposit: String?
}

struct NEARNearBlocksOutcome: Decodable, Sendable {
    let status: Bool
}

struct NEARNearBlocksOutcomeAggregate: Decodable, Sendable {
    let transactionFee: String?

    enum CodingKeys: String, CodingKey {
        case transactionFee = "transaction_fee"
    }
}

struct NEARNearBlocksTransaction: Decodable, Sendable {
    let actions: [NEARNearBlocksAction]
    let actionsAggregate: NEARNearBlocksAggregate
    let block: NEARNearBlocksBlock
    let outcome: NEARNearBlocksOutcome
    let outcomesAggregate: NEARNearBlocksOutcomeAggregate
    let receiverAccountID: String
    let signerAccountID: String
    let transactionHash: String

    enum CodingKeys: String, CodingKey {
        case actions
        case actionsAggregate = "actions_agg"
        case block
        case outcome = "outcomes"
        case outcomesAggregate = "outcomes_agg"
        case receiverAccountID = "receiver_account_id"
        case signerAccountID = "signer_account_id"
        case transactionHash = "transaction_hash"
    }
}

struct NEARNearBlocksReceipt: Decodable, Sendable {
    let actions: [NEARNearBlocksAction]
    let actionsAggregate: NEARNearBlocksAggregate
    let block: NEARNearBlocksBlock
    let includedInBlockTimestamp: String
    let outcome: NEARNearBlocksOutcome
    let predecessorAccountID: String
    let receiptID: String
    let receiverAccountID: String
    let transactionHash: String

    enum CodingKeys: String, CodingKey {
        case actions
        case actionsAggregate = "actions_agg"
        case block
        case includedInBlockTimestamp = "included_in_block_timestamp"
        case outcome
        case predecessorAccountID = "predecessor_account_id"
        case receiptID = "receipt_id"
        case receiverAccountID = "receiver_account_id"
        case transactionHash = "transaction_hash"
    }
}

struct NEARNearBlocksTokenMetadata: Decodable, Sendable {
    let contract: String
    let decimals: Int
    let icon: String?
    let name: String
    let symbol: String
}

struct NEARNearBlocksTokenTransfer: Decodable, Sendable {
    let affectedAccountID: String
    let block: NEARNearBlocksBlock
    let blockTimestamp: String
    let contractAccountID: String
    let deltaAmount: String
    let eventIndex: Int?
    let involvedAccountID: String?
    let metadata: NEARNearBlocksTokenMetadata?
    let receiptID: String?
    let transactionHash: String

    enum CodingKeys: String, CodingKey {
        case affectedAccountID = "affected_account_id"
        case block
        case blockTimestamp = "block_timestamp"
        case contractAccountID = "contract_account_id"
        case deltaAmount = "delta_amount"
        case eventIndex = "event_index"
        case involvedAccountID = "involved_account_id"
        case metadata = "meta"
        case receiptID = "receipt_id"
        case transactionHash = "transaction_hash"
    }
}
