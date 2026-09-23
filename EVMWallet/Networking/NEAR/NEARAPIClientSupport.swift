import Foundation

extension NEARAPIClient {
    func nativeBalance(accountID: String) async throws -> String {
        try await accountState(accountID: accountID).amount
    }

    func accountState(accountID: String) async throws -> NEARAccountState {
        guard NEARAddress.isValid(accountID), let transport else {
            throw NEARProviderError.invalidAddress
        }
        let result = try await transport.request(
            method: "query",
            parameters: .object([
                "request_type": .string("view_account"),
                "finality": .string("final"),
                "account_id": .string(accountID)
            ])
        )
        guard let object = result.objectValue,
              let amountText = object["amount"]?.stringValue,
              let amount = ExactDecimalText.canonicalUnsignedInteger(
                  amountText
              ),
              let lockedText = object["locked"]?.stringValue,
              let locked = ExactDecimalText.canonicalUnsignedInteger(
                  lockedText
              ),
              let storageUsageValue = object["storage_usage"]?.integerValue,
              storageUsageValue >= 0,
              let storageUsage = UInt64(exactly: storageUsageValue)
        else { throw NEARProviderError.invalidResponse("account_balance") }
        return NEARAccountState(
            amount: amount,
            locked: locked,
            storageUsage: storageUsage
        )
    }

    func accountExists(accountID: String) async throws -> Bool {
        do {
            _ = try await accountState(accountID: accountID)
            return true
        } catch let error as NEARProviderError {
            if case let .rpc(_, message) = error,
               message == "unknown_account" {
                return false
            }
            throw error
        }
    }

    func protocolConfig() async throws -> NEARProtocolConfig {
        guard let transport else {
            throw NEARProviderError.missingConfiguration
        }
        let result = try await transport.request(
            method: "EXPERIMENTAL_protocol_config",
            parameters: .object(["finality": .string("final")])
        )
        guard let object = result.objectValue,
              let chainID = object["chain_id"]?.stringValue,
              chainID == "mainnet",
              let runtimeConfig = object["runtime_config"]?.objectValue,
              let storageText = runtimeConfig["storage_amount_per_byte"]?
                .stringValue,
              let storageAmountPerByte = ExactDecimalText
                .canonicalUnsignedInteger(storageText),
              storageAmountPerByte != "0"
        else { throw NEARProviderError.invalidResponse("protocol_config") }
        return NEARProtocolConfig(
            chainID: chainID,
            storageAmountPerByte: storageAmountPerByte
        )
    }

    static func userUnits(atomic: String, decimals: Int) throws -> String {
        guard let canonical = ExactDecimalText.canonicalUnsignedInteger(atomic),
              (0...38).contains(decimals)
        else { throw NEARProviderError.invalidResponse("amount") }
        guard canonical != "0", decimals > 0 else { return canonical }
        if canonical.count > decimals {
            let split = canonical.index(
                canonical.endIndex,
                offsetBy: -decimals
            )
            let whole = canonical[..<split]
            let fraction = canonical[split...]
            let trimmed = String(
                String(fraction).reversed()
                    .drop(while: { $0 == "0" }).reversed()
            )
            return trimmed.isEmpty ? String(whole) : "\(whole).\(trimmed)"
        }
        let zeros = String(repeating: "0", count: decimals - canonical.count)
        let fraction = String(
            (zeros + canonical).reversed()
                .drop(while: { $0 == "0" }).reversed()
        )
        return fraction.isEmpty ? "0" : "0.\(fraction)"
    }

    static func safeIconURL(_ value: String) -> URL? {
        guard value.utf8.count <= 2_048,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil
        else { return nil }
        return url
    }

    static func failureCode(_ error: Error) -> String {
        if let error = error as? NEARProviderError {
            return error.diagnosticDescription
        }
        return "near_history_unavailable"
    }
}
