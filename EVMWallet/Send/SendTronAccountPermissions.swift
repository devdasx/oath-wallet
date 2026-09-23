import Foundation

extension SendTronAPIClient {
    /// Reuses the authenticated REST provider and its mainnet fallback. No
    /// transaction is built, signed, or broadcast by this read-only request.
    func accountPermissions(address: String) async throws -> TronAccountPermissions {
        guard TronValueParser.accountHexAddress(address) != nil else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        let object = try await post(
            path: "wallet/getaccount",
            body: ["address": address, "visible": true]
        )
        try Task.checkCancellation()
        return try TronAccountPermissions.decode(
            JSONSerialization.data(withJSONObject: object), expectedAddress: address
        )
    }
}
