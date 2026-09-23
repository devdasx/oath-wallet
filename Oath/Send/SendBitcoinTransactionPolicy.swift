import Foundation

enum SendBitcoinTransactionPolicy {
    static let minimumAutomaticFeeRate: Int64 = 5

    static func changeOutputScriptSize(for type: BitcoinHDAddressType) -> Int {
        switch type {
        case .bip44, .brdLegacy: 25
        case .bip49: 23
        case .bip84, .brdSegwit: 22
        case .bip86: 34
        }
    }

    /// Apply the wallet's margin once, when a raw automatic quote is resolved.
    /// Built-in quotes already contain the floor; custom and authorized fees
    /// are separate paths and must retain the user's exact values.
    static func automaticFeeRate(_ rawRate: String, isBuiltIn: Bool) throws -> String {
        guard let rate = Int64(rawRate), rate > 0 else {
            throw SendTransactionSubmissionError.feeQuoteUnavailable("invalid_bitcoin_fee_rate")
        }
        let adjusted = rate.multipliedReportingOverflow(by: isBuiltIn ? 1 : 2)
        guard !adjusted.overflow else {
            throw SendTransactionSubmissionError.feeQuoteUnavailable("bitcoin_fee_rate_overflow")
        }
        return String(max(minimumAutomaticFeeRate, adjusted.partialValue))
    }

    /// Bitcoin Core's standard transaction weight ceiling, independent of
    /// its aggregate OP_RETURN script allowance. Witness bytes weigh less.
    static let maximumWeight: Int64 = 400_000

    static func validateWeight(_ weight: Int64) throws {
        guard weight > 0, weight <= maximumWeight else { throw oversizedTransaction }
    }

    static func validateVirtualSize(_ virtualSize: Int64) throws {
        guard virtualSize > 0, virtualSize <= maximumWeight / 4 else {
            throw oversizedTransaction
        }
    }

    static func validateEncoded(_ encoded: Data) throws {
        let transaction = try SendBitcoinNestedSegwitTransaction.finalize(
            encoded: encoded, nestedPublicKeysByOutpointID: [:]
        )
        try validateVirtualSize(transaction.virtualSize)
    }

    static func isSizeError(_ error: Error) -> Bool {
        guard let error = error as? SendTransactionSubmissionError,
              case let .signing(code, _) = error else { return false }
        return code == "bitcoin_transaction_too_large"
    }

    private static var oversizedTransaction: SendTransactionSubmissionError {
        .signing(
            code: "bitcoin_transaction_too_large",
            message: WalletLocalization.string("send.bitcoin.op_return.error.transaction_too_large")
        )
    }
}
