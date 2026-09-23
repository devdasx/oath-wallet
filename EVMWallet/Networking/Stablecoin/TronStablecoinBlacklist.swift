import Foundation

extension SendTronAPIClient {
    func stablecoinBlacklist(contract: String, address: String,
                             method: StablecoinBlacklistTarget.Method) async throws -> Bool {
        guard let hex = TronValueParser.accountHexAddress(address),
              TronValueParser.accountHexAddress(contract) != nil else {
            throw StablecoinCheckError.invalidAddress
        }
        let parameter = String(repeating: "0", count: 24) + hex.dropFirst(2)
        let object = try await post(path: "wallet/triggerconstantcontract", body: [
            "owner_address": address, "contract_address": contract,
            "function_selector": method.signature, "parameter": parameter, "visible": true
        ])
        return try Self.decodeStablecoinBlacklist(object)
    }

    static func decodeStablecoinBlacklist(_ object: [String: Any]) throws -> Bool {
        if let message = object["Error"] as? String {
            throw StablecoinCheckError.contract("provider_error", SendTransactionSubmissionError.sanitizedMessage(message))
        }
        if let result = object["result"] as? [String: Any],
           result["result"] as? Bool != true || result["message"] != nil || result["code"] != nil {
            throw StablecoinCheckError.contract(
                result["code"] as? String ?? "contract_execution_failed",
                SendTransactionSubmissionError.sanitizedMessage(
                    SendTronProviderMessage.decode(result["message"] as? String ?? "")
                )
            )
        }
        // A HTTP 200 is not a successful execution of the view function.
        guard let result = object["result"] as? [String: Any],
              let succeeded = result["result"] as? NSNumber,
              CFGetTypeID(succeeded) == CFBooleanGetTypeID(), succeeded.boolValue,
              result["code"] == nil, object["Error"] == nil,
              let values = object["constant_result"] as? [String], values.count == 1 else {
            throw StablecoinCheckError.invalidEnvelope
        }
        return try StablecoinBlacklistABI.boolean(values[0])
    }
}
