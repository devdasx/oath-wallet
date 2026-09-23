import Foundation

/// Funding stays bound to the account and chain whose permission was reviewed.
struct EVMApprovalGasFunding: Identifiable {
    let address: String
    let network: ReceiveNetwork

    var id: String { "\(network.id):\(address.lowercased())" }
    var paymentPayload: String {
        ReceiveAddressResolver.paymentPayload(
            address: address, network: network, contractAddress: nil
        )
    }

    init?(address: String, networkID: String) {
        guard let network = ReceiveNetworkCatalog.network(for: networkID),
              network.blockchain.isEVM,
              AnkrAPIClient.isValidAddress(address) else { return nil }
        self.address = address
        self.network = network
    }

    /// Runs before signing on every EVM chain. The intrinsic floor is only a
    /// lower bound; the successful estimate still determines the complete fee.
    static func validatedEstimate(
        networkID: String,
        nativeBalance: String,
        feePerGas: String,
        estimate: () async throws -> String
    ) async throws -> String {
        guard SendAtomicAmount.isCanonical(nativeBalance),
              SendAtomicAmount.isCanonical(feePerGas), feePerGas != "0" else {
            throw SendTransactionSubmissionError.feeQuoteUnavailable("invalid_evm_fee")
        }
        let minimumFee = try SendAtomicAmount.multiply(feePerGas, by: 21_000)
        guard SendAtomicAmount.compare(nativeBalance, minimumFee) != .orderedAscending else {
            throw SendTransactionSubmissionError.insufficientNetworkFeeBalance
        }
        do {
            return try await estimate()
        } catch let error as SendTransactionSubmissionError {
            if isInsufficientGas(
                error, networkID: networkID,
                nativeBalance: nativeBalance, feePerGas: feePerGas
            ) {
                throw SendTransactionSubmissionError.insufficientNetworkFeeBalance
            }
            throw error
        }
    }

    static func isInsufficientGas(
        _ error: SendTransactionSubmissionError,
        networkID: String,
        nativeBalance: String? = nil,
        feePerGas: String? = nil
    ) -> Bool {
        guard !error.submissionMayHaveSucceeded else { return false }
        switch error {
        case .insufficientNetworkFeeBalance:
            return true
        case let .provider(errorNetwork, code, message):
            guard errorNetwork == networkID, code.hasPrefix("rpc_") else { return false }
            return isNativeBalanceMessage(message)
                || isBalanceCappedEstimate(
                    message, nativeBalance: nativeBalance, feePerGas: feePerGas
                )
        case let .broadcastRejected(_, message, _):
            return isNativeBalanceMessage(message)
        default:
            return false
        }
    }

    private static func isBalanceCappedEstimate(
        _ message: String,
        nativeBalance: String?,
        feePerGas: String?
    ) -> Bool {
        guard let nativeBalance, let feePerGas,
              SendAtomicAmount.isCanonical(nativeBalance),
              SendAtomicAmount.isCanonical(feePerGas), feePerGas != "0"
        else { return false }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefix = "gas required exceeds allowance ("
        guard message.hasPrefix(prefix), message.hasSuffix(")") else { return false }
        let digits = String(message.dropFirst(prefix.count).dropLast())
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let cap = UInt64(digits), cap < UInt64.max,
              let lowerBound = try? SendAtomicAmount.multiply(feePerGas, by: cap),
              let upperBound = try? SendAtomicAmount.multiply(feePerGas, by: cap + 1)
        else { return false }
        // Geth caps gas at floor(balance / feeCap) for our zero-value call.
        // Only map the ambiguous error when the observed balance proves this
        // exact cap. RPC/block gas ceilings must keep their original error.
        return SendAtomicAmount.compare(nativeBalance, lowerBound) != .orderedAscending
            && SendAtomicAmount.compare(nativeBalance, upperBound) == .orderedAscending
    }

    private static func isNativeBalanceMessage(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Only recognize native-balance rejection messages. A contract revert
        // mentioning a token balance, or an RPC code alone, is not proof.
        return normalized == "insufficient funds"
            || normalized.hasPrefix("insufficient funds for gas")
            || normalized.hasPrefix("insufficient funds for transfer")
            || normalized.hasPrefix("insufficient funds for intrinsic transaction cost")
            || normalized.hasPrefix("insufficient balance for transaction gas")
            || normalized.hasPrefix("insufficient balance to pay for gas")
    }
}
