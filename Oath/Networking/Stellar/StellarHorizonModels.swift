import Foundation

struct StellarHorizonAccount: Decodable, Sendable {
    struct Balance: Decodable, Sendable {
        let balance: String
        let sellingLiabilities: String
        let buyingLiabilities: String?
        let limit: String?
        let assetType: String
        let assetCode: String?
        let assetIssuer: String?
        let isAuthorized: Bool?

        enum CodingKeys: String, CodingKey {
            case balance
            case sellingLiabilities = "selling_liabilities"
            case buyingLiabilities = "buying_liabilities"
            case limit
            case assetType = "asset_type"
            case assetCode = "asset_code"
            case assetIssuer = "asset_issuer"
            case isAuthorized = "is_authorized"
        }
    }

    let accountID: String
    let sequence: String
    let subentryCount: Int64
    let numSponsoring: Int64
    let numSponsored: Int64
    let balances: [Balance]

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case sequence
        case subentryCount = "subentry_count"
        case numSponsoring = "num_sponsoring"
        case numSponsored = "num_sponsored"
        case balances
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try values.decode(String.self, forKey: .accountID)
        sequence = try values.decode(String.self, forKey: .sequence)
        subentryCount = try values.decodeIfPresent(
            Int64.self,
            forKey: .subentryCount
        ) ?? 0
        numSponsoring = try values.decodeIfPresent(
            Int64.self,
            forKey: .numSponsoring
        ) ?? 0
        numSponsored = try values.decodeIfPresent(
            Int64.self,
            forKey: .numSponsored
        ) ?? 0
        balances = try values.decode([Balance].self, forKey: .balances)
    }
}

struct StellarHorizonPaymentPage: Decodable, Sendable {
    struct Embedded: Decodable, Sendable { let records: [Payment] }
    struct Links: Decodable, Sendable { let next: Link }
    struct Link: Decodable, Sendable { let href: String }
    struct Payment: Decodable, Sendable {
        let id: String
        let pagingToken: String
        let transactionHash: String
        let createdAt: String
        let type: String
        let assetType: String?
        let assetCode: String?
        let assetIssuer: String?
        let amount: String?
        let from: String?
        let to: String?
        let sourceAccount: String?
        let account: String?
        let startingBalance: String?
        let transaction: StellarHorizonTransaction?

        enum CodingKeys: String, CodingKey {
            case id
            case pagingToken = "paging_token"
            case transactionHash = "transaction_hash"
            case createdAt = "created_at"
            case type, amount, from, to, account
            case assetType = "asset_type"
            case assetCode = "asset_code"
            case assetIssuer = "asset_issuer"
            case sourceAccount = "source_account"
            case startingBalance = "starting_balance"
            case transaction
        }
    }
    let embedded: Embedded
    let links: Links

    enum CodingKeys: String, CodingKey {
        case embedded = "_embedded"
        case links = "_links"
    }
}

struct StellarHorizonTransaction: Decodable, Sendable {
    let hash: String
    let ledger: Int64
    let createdAt: String
    let feeCharged: String
    let successful: Bool
    let memoType: String
    let memo: String?
    let sourceAccount: String
    let sourceAccountSequence: String

    enum CodingKeys: String, CodingKey {
        case hash, ledger, successful, memo
        case createdAt = "created_at"
        case feeCharged = "fee_charged"
        case memoType = "memo_type"
        case sourceAccount = "source_account"
        case sourceAccountSequence = "source_account_sequence"
    }
}

struct StellarHorizonFeeStats: Decodable, Sendable {
    struct Charged: Decodable, Sendable { let p95: String }
    let feeCharged: Charged
    enum CodingKeys: String, CodingKey { case feeCharged = "fee_charged" }
}

struct StellarHorizonLedgerPage: Decodable, Sendable {
    struct Embedded: Decodable, Sendable { let records: [Ledger] }
    struct Ledger: Decodable, Sendable {
        let baseReserveInStroops: Int64
        enum CodingKeys: String, CodingKey {
            case baseReserveInStroops = "base_reserve_in_stroops"
        }
    }
    let embedded: Embedded
    enum CodingKeys: String, CodingKey { case embedded = "_embedded" }
}

struct StellarHorizonSubmitResponse: Decodable, Sendable {
    let hash: String
    let ledger: Int64?
    let successful: Bool
}

struct StellarHorizonProblem: Decodable, Sendable {
    struct Extras: Decodable, Sendable {
        struct ResultCodes: Decodable, Sendable {
            let transaction: String?
            let operations: [String]?
        }
        let resultCodes: ResultCodes?
        enum CodingKeys: String, CodingKey { case resultCodes = "result_codes" }
    }
    let title: String?
    let status: Int?
    let detail: String?
    let extras: Extras?
}
