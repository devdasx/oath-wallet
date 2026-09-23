import Foundation

enum WalletSyncDiagnosticErrorDetail {
    static func value(for error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        if let error = error as? AnkrAPIError {
            return "ankr_error=\(error.diagnosticDescription)"
        }
        if let error = error as? AnkrBalanceSnapshotError {
            return error.diagnosticDescription
        }
        if let error = error as? HistoryPaginationError {
            return "history_pagination_error=\(error.diagnosticDescription)"
        }
        if let error = error as? TronHistoryError {
            return "tron_history_error=\(error.diagnosticDescription)"
        }
        if let error = error as? TronUInt256Error {
            return "tron_uint256_error=\(error.diagnosticDescription)"
        }
        if let error = error as? TronRPCError {
            return "tron_rpc_error_code=\(error.code)"
        }
        if let error = error as? SolanaProviderError {
            return error.diagnosticDescription
        }
        if let error = error as? SolanaSnapshotPersistenceError {
            return error.diagnosticDescription
        }
        if let error = error as? SolanaTokenEligibilityError {
            return error.diagnosticDescription
        }
        if let error = error as? WalletSnapshotPersistenceError {
            return "wallet_snapshot_persistence_error=\(error.diagnosticDescription)"
        }
        if let error = error as? WalletSynchronizationReportError {
            let details = error.report.failures.map {
                "\($0.source.rawValue):\($0.stage.rawValue):\($0.publicCode)"
            }
            .joined(separator: ",")
            return "chain_synchronization_failures=\(details)"
        }
        if let error = error as? BitcoinFamilySyncError {
            return "bitcoin_family_error=\(error.diagnosticDescription)"
        }
        if let error = error as? BitcoinFamilyAPIError {
            return "bitcoin_family_error=\(error.diagnosticDescription)"
        }
        if let error = error as? BitcoinFamilyElectrumError {
            return "bitcoin_family_error=\(error.diagnosticDescription)"
        }
        if let error = error as? BitcoinFamilyAtomicIntegerError {
            return "bitcoin_family_atomic_error=\(error.diagnosticDescription)"
        }
        if let error = error as? WalletSecretVaultError {
            return "keychain_error=\(error.diagnosticDescription)"
        }
        if let error = error as? ReceiveAddressResolutionError {
            return "receive_address_error=\(error.diagnosticDescription)"
        }
        if let error = error as? URLError {
            return "url_error_code=\(error.code.rawValue)"
        }
        if let error = error as? DecodingError {
            return decodingDetail(error)
        }
        let nsError = error as NSError
        return "error_domain=\(nsError.domain) error_code=\(nsError.code)"
    }

    private static func decodingDetail(_ error: DecodingError) -> String {
        switch error {
        case let .keyNotFound(key, context):
            "decoding_error=missing_key:\(key.stringValue) path=\(path(context))"
        case let .typeMismatch(_, context):
            "decoding_error=type_mismatch path=\(path(context))"
        case let .valueNotFound(_, context):
            "decoding_error=missing_value path=\(path(context))"
        case let .dataCorrupted(context):
            "decoding_error=data_corrupted path=\(path(context))"
        @unknown default:
            "decoding_error=unknown"
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let value = context.codingPath.map(\.stringValue).joined(separator: ".")
        return value.isEmpty ? "<root>" : value
    }
}
