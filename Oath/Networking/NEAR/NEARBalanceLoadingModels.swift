import Foundation

struct FastAccount: Decodable, Sendable {
    struct State: Decodable, Sendable {
        let balance: String
    }

    struct Token: Decodable, Sendable {
        let balance: String
        let contractID: String

        enum CodingKeys: String, CodingKey {
            case balance
            case contractID = "contract_id"
        }
    }

    let state: State
    let tokens: [Token]
}

struct NativeBalanceLoad: Sendable {
    let atomicAmount: String?
    let failureCode: String?
}

struct FastAccountLoad: Sendable {
    let nativeAtomicAmount: String?
    let tokens: [FastAccount.Token]
    let succeeded: Bool
    let failureCode: String?
}

struct TokenBalanceLoad: Sendable {
    let balances: [NEARAssetBalance]
    let successfulAssetIDs: Set<String>
    let failureCodes: [String]
}

struct BalanceLoad: Sendable {
    let balances: [NEARAssetBalance]
    let successfulAssetIDs: Set<String>
    let isAuthoritative: Bool
    let failureCodes: [String]
}

enum InitialBalanceLoad: Sendable {
    case rpc(NativeBalanceLoad)
    case index(FastAccountLoad)
}
