import Foundation

struct AptosIndexerBalancesResponse: Decodable, Sendable {
    let currentFungibleAssetBalances: [AptosIndexerBalance]

    enum CodingKeys: String, CodingKey {
        case currentFungibleAssetBalances = "current_fungible_asset_balances"
    }
}

struct AptosIndexerBalance: Decodable, Sendable {
    let storageID: String
    let amount: String
    let assetType: String
    let tokenStandard: String
    let isPrimary: Bool
    let isFrozen: Bool
    let metadata: AptosIndexerMetadata?

    enum CodingKeys: String, CodingKey {
        case storageID = "storage_id"
        case amount
        case assetType = "asset_type"
        case tokenStandard = "token_standard"
        case isPrimary = "is_primary"
        case isFrozen = "is_frozen"
        case metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storageID = try container.decode(String.self, forKey: .storageID)
        amount = try container.decodeLosslessInteger(forKey: .amount)
        assetType = try container.decode(String.self, forKey: .assetType)
        tokenStandard = try container.decode(
            String.self,
            forKey: .tokenStandard
        )
        isPrimary = try container.decode(Bool.self, forKey: .isPrimary)
        isFrozen = try container.decode(Bool.self, forKey: .isFrozen)
        metadata = try container.decodeIfPresent(
            AptosIndexerMetadata.self,
            forKey: .metadata
        )
    }
}

struct AptosIndexerActivitiesResponse: Decodable, Sendable {
    let fungibleAssetActivities: [AptosIndexerActivity]

    enum CodingKeys: String, CodingKey {
        case fungibleAssetActivities = "fungible_asset_activities"
    }
}

struct AptosIndexerActivity: Decodable, Sendable {
    let transactionVersion: String
    let eventIndex: String
    let ownerAddress: String?
    let assetType: String?
    let amount: String?
    let type: String
    let isTransactionSuccess: Bool
    let entryFunction: String?
    let timestamp: String
    let metadata: AptosIndexerMetadata?

    enum CodingKeys: String, CodingKey {
        case transactionVersion = "transaction_version"
        case eventIndex = "event_index"
        case ownerAddress = "owner_address"
        case assetType = "asset_type"
        case amount, type, metadata
        case isTransactionSuccess = "is_transaction_success"
        case entryFunction = "entry_function_id_str"
        case timestamp = "transaction_timestamp"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transactionVersion = try container.decodeLosslessInteger(
            forKey: .transactionVersion
        )
        eventIndex = try container.decodeLosslessInteger(forKey: .eventIndex)
        ownerAddress = try container.decodeIfPresent(
            String.self,
            forKey: .ownerAddress
        )
        assetType = try container.decodeIfPresent(
            String.self,
            forKey: .assetType
        )
        amount = try container.decodeLosslessIntegerIfPresent(forKey: .amount)
        type = try container.decode(String.self, forKey: .type)
        isTransactionSuccess = try container.decode(
            Bool.self,
            forKey: .isTransactionSuccess
        )
        entryFunction = try container.decodeIfPresent(
            String.self,
            forKey: .entryFunction
        )
        timestamp = try container.decode(String.self, forKey: .timestamp)
        metadata = try container.decodeIfPresent(
            AptosIndexerMetadata.self,
            forKey: .metadata
        )
    }
}

private struct AptosLosslessJSONInteger: Decodable {
    let text: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string
            return
        }
        if var decimal = try? container.decode(Decimal.self) {
            text = NSDecimalString(
                &decimal,
                Locale(identifier: "en_US_POSIX")
            )
            return
        }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected an exact JSON integer or string."
            )
        )
    }
}

private extension KeyedDecodingContainer {
    func decodeLosslessInteger(forKey key: Key) throws -> String {
        try decode(AptosLosslessJSONInteger.self, forKey: key).text
    }

    func decodeLosslessIntegerIfPresent(forKey key: Key) throws -> String? {
        try decodeIfPresent(AptosLosslessJSONInteger.self, forKey: key)?.text
    }
}

struct AptosIndexerMetadata: Decodable, Sendable {
    let assetType: String
    let name: String
    let symbol: String
    let decimals: Int
    let iconURI: String?
    let tokenStandard: String

    enum CodingKeys: String, CodingKey {
        case assetType = "asset_type"
        case name, symbol, decimals
        case iconURI = "icon_uri"
        case tokenStandard = "token_standard"
    }
}

struct AptosRESTAccountResponse: Decodable, Sendable {
    let sequenceNumber: String
    let authenticationKey: String

    enum CodingKeys: String, CodingKey {
        case sequenceNumber = "sequence_number"
        case authenticationKey = "authentication_key"
    }
}

struct AptosRESTGasResponse: Decodable, Sendable {
    let deprioritizedGasEstimate: UInt64
    let gasEstimate: UInt64
    let prioritizedGasEstimate: UInt64

    enum CodingKeys: String, CodingKey {
        case deprioritizedGasEstimate = "deprioritized_gas_estimate"
        case gasEstimate = "gas_estimate"
        case prioritizedGasEstimate = "prioritized_gas_estimate"
    }
}

struct AptosRESTTransactionResponse: Decodable, Sendable {
    let version: String
    let hash: String
    let sender: String?
    let gasUsed: String?
    let gasUnitPrice: String?
    let success: Bool
    let timestamp: String?
    let payload: AptosRESTTransactionPayload?

    enum CodingKeys: String, CodingKey {
        case version, hash, sender, success, timestamp, payload
        case gasUsed = "gas_used"
        case gasUnitPrice = "gas_unit_price"
    }
}

struct AptosRESTTransactionPayload: Decodable, Sendable {
    let function: String?
    let typeArguments: [String]
    let arguments: [String]

    enum CodingKeys: String, CodingKey {
        case function, arguments
        case typeArguments = "type_arguments"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        function = try container.decodeIfPresent(String.self, forKey: .function)
        typeArguments = (
            try? container.decode([String].self, forKey: .typeArguments)
        ) ?? []
        // Aptos transfer entry functions encode the recipient as the first
        // string argument. Other payload shapes remain valid history entries
        // but intentionally do not guess a counterparty.
        arguments = (try? container.decode([String].self, forKey: .arguments))
            ?? []
    }
}
