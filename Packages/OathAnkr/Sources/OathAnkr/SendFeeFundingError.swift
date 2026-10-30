import Foundation
import OathDiagnostics

/// A verified shortage of the native asset needed for fees, separate from the
/// transferred asset, provider failures, and account activation/reserve rules.
/// Contains no account identifiers or provider payloads.
public enum SendFeeFundingError: Error, Sendable, Equatable {
    case insufficientNativeBalance
}

// This is an expected funding prerequisite shown to the user, not an app
// failure. Keep throwing it so quoting/signing stay blocked and the fee-funding
// message survives every boundary. Only this typed outcome is excluded; RPC
// failures, invalid balances, fee caps and untrusted lookalike errors remain
// reportable through their original diagnostics boundaries.
extension SendFeeFundingError: DiagnosticControlFlowError {
    public var isExpectedDiagnosticControlFlow: Bool {
        switch self {
        case .insufficientNativeBalance: true
        }
    }
}

extension SendFeeFundingError {
    static func isEVMFundingMessage(_ message: String?) -> Bool {
        guard let message, message.utf8.count <= 2_048 else { return false }
        let value = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["insufficient funds for gas * price + value", "insufficient funds for gas * price + value + gatewayfee",
                "insufficient funds for transfer", "insufficient balance to pay for gas"].contains {
            value == $0 || value.hasPrefix($0 + ":")
        }
    }
}
