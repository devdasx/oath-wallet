import Foundation

enum ScannerPayloadPolicy {
    static func sendRequest(
        from payload: String
    ) throws -> SendPaymentRequest {
        try SendPaymentRequestParser.parse(payload)
    }

    static func importCredential(
        from payload: String,
        mode: ImportWalletCredentialScannerMode
    ) throws -> ImportCredentialScanReview {
        try ImportCredentialScanReview.parse(
            payload,
            mode: mode
        )
    }

    static func tokenContractAddress(
        from payload: String
    ) -> String? {
        let trimmed = payload.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty, trimmed.utf8.count <= 42 else {
            return nil
        }
        let normalized: String
        if trimmed.hasPrefix("0X") {
            normalized = "0x" + String(trimmed.dropFirst(2))
        } else {
            normalized = trimmed
        }
        let lowercased = normalized.lowercased()
        guard
            lowercased.utf8.count == 42,
            lowercased.hasPrefix("0x"),
            lowercased.dropFirst(2).allSatisfy(\.isHexDigit),
            SendAddressValidator.isValidEVMAddress(lowercased)
        else {
            return nil
        }
        return lowercased
    }

    static func deviceMigrationInvitation(
        from payload: String,
        now: Date = Date()
    ) throws -> DeviceMigrationInvitation {
        try DeviceMigrationInvitation.parse(
            payload,
            now: now
        )
    }
}
