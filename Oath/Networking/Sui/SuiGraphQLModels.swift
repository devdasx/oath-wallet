import Foundation

struct SuiBalancesResponse: Decodable, Sendable {
    let address: Address?

    struct Address: Decodable, Sendable {
        let balances: Connection
    }

    struct Connection: Decodable, Sendable {
        let nodes: [Node]
        let pageInfo: SuiForwardPageInfo
    }

    struct Node: Decodable, Sendable {
        let coinType: TypeReference
        let totalBalance: String
    }
}

struct SuiCoinMetadataResponse: Decodable, Sendable {
    let coinMetadata: Metadata?

    struct Metadata: Decodable, Sendable {
        let name: String
        let symbol: String
        let decimals: Int
        let iconUrl: String?
    }
}

struct SuiTransactionsResponse: Decodable, Sendable {
    let address: Address?

    struct Address: Decodable, Sendable {
        let transactions: Connection
    }

    struct Connection: Decodable, Sendable {
        let nodes: [Node]
        let pageInfo: SuiBackwardPageInfo
    }

    struct Node: Decodable, Sendable {
        let digest: String
        let sender: Owner?
        let effects: Effects?
    }

    struct Effects: Decodable, Sendable {
        let status: String
        let timestamp: String?
        let balanceChanges: BalanceChanges
        let gasEffects: GasEffects?
    }

    struct BalanceChanges: Decodable, Sendable {
        let nodes: [BalanceChange]
        let pageInfo: SuiForwardPageInfo
    }

    struct BalanceChange: Decodable, Sendable {
        let owner: Owner?
        let coinType: TypeReference
        let amount: String
    }

    struct GasEffects: Decodable, Sendable {
        let gasSummary: GasSummary?
    }

    struct GasSummary: Decodable, Sendable {
        let computationCost: UInt64
        let storageCost: UInt64
        let storageRebate: UInt64
        let nonRefundableStorageFee: UInt64
    }
}

struct SuiBalanceChangesResponse: Decodable, Sendable {
    let transactionEffects: Effects?

    struct Effects: Decodable, Sendable {
        let balanceChanges: SuiTransactionsResponse.BalanceChanges
    }
}

struct SuiTransactionStatusResponse: Decodable, Sendable {
    let transactionEffects: Effects?

    struct Effects: Decodable, Sendable {
        let status: String
    }
}

struct SuiCoinObjectsResponse: Decodable, Sendable {
    let address: Address?

    struct Address: Decodable, Sendable {
        let objects: Connection
    }

    struct Connection: Decodable, Sendable {
        let nodes: [Node]
        let pageInfo: SuiForwardPageInfo
    }

    struct Node: Decodable, Sendable {
        let address: String
        let version: UInt64
        let digest: String
        let contents: Contents?
    }

    struct Contents: Decodable, Sendable {
        let json: CoinJSON?
    }

    struct CoinJSON: Decodable, Sendable {
        let balance: String
    }
}

struct SuiEpochResponse: Decodable, Sendable {
    let epoch: Epoch?

    struct Epoch: Decodable, Sendable {
        let referenceGasPrice: String
    }
}

struct SuiExecuteResponse: Decodable, Sendable {
    let executeTransaction: Result?

    struct Result: Decodable, Sendable {
        let effects: Effects?
    }

    struct Effects: Decodable, Sendable {
        let digest: String?
        let status: String
        let executionError: ExecutionError?
    }

    struct ExecutionError: Decodable, Sendable {
        let message: String
    }
}

struct TypeReference: Decodable, Sendable {
    let repr: String
}

struct Owner: Decodable, Sendable {
    let address: String
}

struct SuiForwardPageInfo: Decodable, Sendable {
    let hasNextPage: Bool
    let endCursor: String?
}

struct SuiBackwardPageInfo: Decodable, Sendable {
    let hasPreviousPage: Bool
    let startCursor: String?
}
