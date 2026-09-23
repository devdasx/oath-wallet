import Foundation

struct SolanaAccountMaterial: Hashable, Sendable {
    let kind: SolanaDerivationKind
    let address: String
    let publicKey: String
    let derivationPath: String?
}

struct SolanaAccountSet: Sendable {
    let primary: SolanaAccountMaterial
    let alternatives: [SolanaAccountMaterial]

    var all: [SolanaAccountMaterial] {
        [primary] + alternatives
    }

    func account(for kind: SolanaDerivationKind) -> SolanaAccountMaterial? {
        all.first { $0.kind == kind }
    }
}

struct SolanaTokenBalance: Sendable {
    let mint: String
    let tokenAccountAddresses: [String]
    let name: String
    let symbol: String
    let decimals: Int
    let amount: Decimal
    let atomicAmount: String
    let catalogRank: Int?
}

struct SolanaBalanceBatchAuthority: Equatable, Sendable {
    static let expectedResponseCount = 3
    static let expectedTokenProgramResponseCount = 2
    static let complete = Self(
        receivedResponseCount: expectedResponseCount,
        tokenProgramResponseCount: expectedTokenProgramResponseCount
    )

    let receivedResponseCount: Int
    let tokenProgramResponseCount: Int

    var isComplete: Bool {
        receivedResponseCount == Self.expectedResponseCount
            && tokenProgramResponseCount
                == Self.expectedTokenProgramResponseCount
    }
}

struct SolanaAddressSnapshot: Sendable {
    let material: SolanaAccountMaterial
    let solBalance: Decimal
    let solAtomicBalance: String
    let tokenBalances: [SolanaTokenBalance]
    let balanceAuthority: SolanaBalanceBatchAuthority
}

struct SolanaHistoryItem: Sendable {
    let signature: String
    let sourceAddress: String
    let slot: Int64
    let timestamp: Double?
    let failed: Bool
    let from: String?
    let to: String?
    let mint: String?
    let symbol: String
    let decimals: Int
    let amount: Decimal
    let atomicAmount: String
    let fee: Decimal
}

struct SolanaHistoryCursor: Sendable {
    let queriedAddress: String
    let ownerKind: SolanaDerivationKind
    let newestSignature: String?
    let oldestSignature: String?
    let providerHistoryComplete: Bool
}

struct SolanaWalletSnapshot: Sendable {
    let accounts: SolanaAccountSet
    let spendable: SolanaAddressSnapshot
    let addressSnapshots: [SolanaAddressSnapshot]
    let history: [SolanaHistoryItem]
    let historyCursors: [SolanaHistoryCursor]

    var solBalance: Decimal {
        spendable.solBalance
    }

    var solAtomicBalance: String {
        spendable.solAtomicBalance
    }

    var tokens: [SolanaTokenBalance] {
        spendable.tokenBalances
    }

    init(
        accounts: SolanaAccountSet,
        addressSnapshots: [SolanaAddressSnapshot],
        history: [SolanaHistoryItem],
        historyCursors: [SolanaHistoryCursor]
    ) throws {
        guard addressSnapshots.allSatisfy({
            $0.balanceAuthority.isComplete
        }) else {
            throw SolanaProviderError.incompleteBalanceBatch(
                expected: SolanaBalanceBatchAuthority.expectedResponseCount,
                actual: addressSnapshots.map {
                    $0.balanceAuthority.receivedResponseCount
                }.min() ?? 0
            )
        }
        let expectedKeys = Set(accounts.all.map(Self.accountKey))
        let actualKeys = Set(
            addressSnapshots.map { Self.accountKey($0.material) }
        )
        guard
            expectedKeys.count == accounts.all.count,
            actualKeys.count == addressSnapshots.count,
            expectedKeys == actualKeys
        else {
            throw SolanaProviderError.incompleteBalanceCoverage(
                expected: accounts.all.count,
                actual: addressSnapshots.count
            )
        }
        guard
            let spendable = addressSnapshots.first(where: {
                Self.accountKey($0.material)
                    == Self.accountKey(accounts.primary)
            })
        else {
            throw SolanaProviderError.primaryBalanceUnavailable
        }
        self.accounts = accounts
        self.spendable = spendable
        self.addressSnapshots = addressSnapshots
        self.history = history
        self.historyCursors = historyCursors
    }

    private static func accountKey(
        _ material: SolanaAccountMaterial
    ) -> String {
        "\(material.kind.rawValue):\(material.address)"
    }
}

enum SolanaProviderError: Error, Sendable {
    case malformedResponse(method: String)
    case accountDerivationUnavailable
    case incompleteBalanceBatch(expected: Int, actual: Int)
    case unexpectedBalanceBatchResponse
    case duplicateBalanceBatchResponse(responseID: Int)
    case invalidBalanceBatchResponse(responseID: Int, field: String)
    case tokenBalanceOverflow(responseID: Int, itemIndex: Int)
    case incompleteBalanceCoverage(expected: Int, actual: Int)
    case primaryBalanceUnavailable
    case historyPrunedByProvider(oldestAvailableSignature: String?)

    var diagnosticDescription: String {
        switch self {
        case let .malformedResponse(method):
            "solana_malformed_response method=\(method)"
        case .accountDerivationUnavailable:
            "solana_account_derivation_unavailable"
        case let .incompleteBalanceBatch(expected, actual):
            "solana_incomplete_balance_batch expected=\(expected) actual=\(actual)"
        case .unexpectedBalanceBatchResponse:
            "solana_unexpected_balance_batch_response"
        case let .duplicateBalanceBatchResponse(responseID):
            "solana_duplicate_balance_batch_response id=\(responseID)"
        case let .invalidBalanceBatchResponse(responseID, field):
            "solana_invalid_balance_batch_response id=\(responseID) field=\(field)"
        case let .tokenBalanceOverflow(responseID, itemIndex):
            "solana_token_balance_overflow id=\(responseID) item=\(itemIndex)"
        case let .incompleteBalanceCoverage(expected, actual):
            "solana_incomplete_balance_coverage expected=\(expected) actual=\(actual)"
        case .primaryBalanceUnavailable:
            "solana_primary_balance_unavailable"
        case let .historyPrunedByProvider(signature):
            "solana_history_pruned_by_provider oldest_signature=\(signature ?? "none")"
        }
    }
}

enum SolanaSnapshotPersistenceError: Error, Sendable {
    case spendableSourceMismatch
    case incompleteBalanceSnapshot

    var diagnosticDescription: String {
        switch self {
        case .spendableSourceMismatch:
            "solana_spendable_source_mismatch"
        case .incompleteBalanceSnapshot:
            "solana_incomplete_balance_snapshot"
        }
    }
}
