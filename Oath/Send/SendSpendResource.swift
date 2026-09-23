import Foundation

/// A pending send consumes resources, not the whole wallet account.
struct SendSpendResource: Hashable, Sendable {
    enum Kind: String, Sendable {
        case outpoint, sequence, objectVersion, transactionID
    }

    let kind: Kind
    let value: String

    static func sequence(_ value: String) -> Self {
        Self(kind: .sequence, value: value)
    }

    static func object(_ object: SuiCoinObject) -> Self {
        Self(kind: .objectVersion, value: "\(object.objectID.lowercased()):\(object.version)")
    }

    static func bitcoinInputs(
        rawHex: String,
        transactionID: String
    ) throws -> Set<Self> {
        guard let transaction = BitcoinRawTransaction(hex: rawHex),
              transaction.transactionID.caseInsensitiveCompare(transactionID) == .orderedSame,
              !transaction.inputs.isEmpty else {
            throw WalletDataStoreError.invalidState
        }
        return Set(transaction.inputs.map {
            Self(kind: .outpoint, value: SendBitcoinOutpoint(
                transactionHash: $0.previousHash,
                outputIndex: $0.previousIndex
            ).id)
        })
    }

    static func availableBitcoinOutputs(
        _ outputs: [SendBitcoinUTXO],
        excluding resources: Set<Self>
    ) -> [SendBitcoinUTXO] {
        // Height zero is a spendable mempool output. Never exclude it just
        // because its parent is unconfirmed. Only exclude consumed outpoints.
        outputs.filter { !resources.contains(Self(kind: .outpoint, value: $0.id)) }
    }

    static func nextSequence(
        networkValue: String,
        pending: Set<Self>
    ) throws -> String {
        guard SendAtomicAmount.isCanonical(networkValue) else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        var next = networkValue
        // Fill the first unused slot, including a gap left by a definitively
        // rejected send. Never replace a locally submitted, still-pending nonce.
        while pending.contains(.sequence(next)) {
            next = SendAtomicAmount.add(next, "1")
        }
        guard SendAtomicAmount.isCanonical(next) else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return next
    }
}

extension SendSpendSubmissionReserving {
    // Lightweight service test doubles have no persisted pending submissions.
    func pendingSpendResources() async throws -> Set<SendSpendResource> { [] }

    func nextSequence(networkValue: String) async throws -> String {
        try await SendSpendResource.nextSequence(
            networkValue: networkValue,
            pending: pendingSpendResources()
        )
    }
}
