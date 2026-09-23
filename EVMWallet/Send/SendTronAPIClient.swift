import Foundation
import WalletCore

struct SendTronUnsignedTransaction: Sendable {
    let json: String
    let transactionID: String
    let rawDataBytes: Int
}

struct SendTronAccountResource: Sendable {
    let freeBandwidthRemaining: UInt64
    let stakedBandwidthRemaining: UInt64
    let energyRemaining: UInt64
}

struct SendTronProtocolParameters: Codable, Hashable, Sendable {
    let energyPrice: UInt64
    let bandwidthPrice: UInt64
    let accountCreationFee: UInt64
    let accountCreationBandwidthFee: UInt64
    let accountCreationBandwidthRate: UInt64

    static let defaults = Self(energyPrice: 100, bandwidthPrice: 1_000,
        accountCreationFee: 1_000_000, accountCreationBandwidthFee: 100_000,
        accountCreationBandwidthRate: 1)

    var isValid: Bool {
        energyPrice > 0 && bandwidthPrice > 0 && accountCreationBandwidthRate > 0
    }
}

actor SendTronAPIClient {
    private enum UnsignedContractExpectation {
        case native(
            ownerAddress: String,
            recipientAddress: String,
            amount: UInt64
        )
        case trc20(
            ownerAddress: String,
            contractAddress: String,
            data: String,
            feeLimit: UInt64
        )

        var type: String {
            switch self {
            case .native:
                "TransferContract"
            case .trc20:
                "TriggerSmartContract"
            }
        }

        var typeURL: String {
            "type.googleapis.com/protocol.\(type)"
        }

        var addresses: [String: String] {
            switch self {
            case let .native(ownerAddress, recipientAddress, _):
                [
                    "owner_address": ownerAddress,
                    "to_address": recipientAddress
                ]
            case let .trc20(ownerAddress, contractAddress, _, _):
                [
                    "owner_address": ownerAddress,
                    "contract_address": contractAddress
                ]
            }
        }

        func validatesPayload(
            value: [String: Any],
            rawData: [String: Any]
        ) -> Bool {
            switch self {
            case let .native(_, _, expectedAmount):
                guard let amount = value["amount"],
                      let decoded = try? SendTronAPIClient.uint64(
                          amount,
                          code: "native_transfer_amount"
                      )
                else {
                    return false
                }
                return decoded == expectedAmount
            case let .trc20(_, _, expectedData, expectedFeeLimit):
                guard let data = value["data"] as? String,
                      data.caseInsensitiveCompare(expectedData) == .orderedSame,
                      SendTronAPIClient.isZeroOrMissing(
                          value["call_value"],
                          code: "trc20_call_value"
                      ),
                      SendTronAPIClient.isZeroOrMissing(
                          value["call_token_value"],
                          code: "trc20_call_token_value"
                      ),
                      SendTronAPIClient.isZeroOrMissing(
                          value["token_id"],
                          code: "trc20_token_id"
                      ),
                      let feeLimit = rawData["fee_limit"],
                      let decoded = try? SendTronAPIClient.uint64(
                          feeLimit,
                          code: "trc20_fee_limit"
                      )
                else {
                    return false
                }
                return decoded == expectedFeeLimit
            }
        }
    }

    private static let trc20TransferSelector = "a9059cbb"

    private let session: URLSession
    private let router: AdaptiveProviderRouter
    private let retrySleep: SendTronRequestRetrier.Sleep

    init(
        session: URLSession? = nil,
        router: AdaptiveProviderRouter = .shared,
        retrySleep: @escaping SendTronRequestRetrier.Sleep = SendTronRequestRetrier.sleep
    ) {
        self.router = router
        self.retrySleep = retrySleep
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 12
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func accountBalance(address: String) async throws -> UInt64 {
        let object = try await post(
            path: "wallet/getaccount",
            body: [
                "address": address,
                "visible": true
            ]
        )
        guard let value = object["balance"] else { return 0 }
        return try Self.uint64(value, code: "account_balance")
    }

    func accountExists(address: String) async throws -> Bool {
        guard let expected = TronValueParser.accountHexAddress(address)
        else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        let object = try await post(
            path: "wallet/getaccount",
            body: [
                "address": address,
                "visible": true
            ]
        )
        guard !object.isEmpty else { return false }
        guard let returned = object["address"] as? String,
              let canonical = Self.canonicalSigningAddress(returned),
              canonical.caseInsensitiveCompare(expected) == .orderedSame
        else {
            throw invalidResponse("account_identity")
        }
        return true
    }
    func protocolParameters() async throws -> SendTronProtocolParameters {
        let object = try await post(
            path: "wallet/getchainparameters",
            body: [:],
            publicOnly: true
        )
        guard let rows = object["chainParameter"] as? [[String: Any]]
        else {
            throw invalidResponse("chain_parameters")
        }
        var values: [String: UInt64] = [:]
        for row in rows {
            guard let key = row["key"] as? String,
                  [
                    "getEnergyFee", "getTransactionFee", "getCreateAccountFee",
                    "getCreateNewAccountFeeInSystemContract",
                    "getCreateNewAccountBandwidthRate"
                  ].contains(key),
                  let rawValue = row["value"]
            else { continue }
            let value = try Self.uint64(
                rawValue,
                code: "chain_parameter"
            )
            if let previous = values.updateValue(value, forKey: key),
               previous != value {
                throw invalidResponse("chain_parameter_duplicate")
            }
        }
        guard let energyPrice = values["getEnergyFee"],
              let bandwidthPrice = values["getTransactionFee"],
              let accountCreationFee = values[
                "getCreateNewAccountFeeInSystemContract"
              ],
              let accountCreationBandwidthFee = values[
                "getCreateAccountFee"
              ],
              let accountCreationBandwidthRate = values[
                "getCreateNewAccountBandwidthRate"
              ],
              energyPrice > 0,
              bandwidthPrice > 0,
              accountCreationBandwidthRate > 0
        else {
            throw invalidResponse("chain_parameter_values")
        }
        return SendTronProtocolParameters(
            energyPrice: energyPrice,
            bandwidthPrice: bandwidthPrice,
            accountCreationFee: accountCreationFee,
            accountCreationBandwidthFee: accountCreationBandwidthFee,
            accountCreationBandwidthRate: accountCreationBandwidthRate
        )
    }

    func accountResource(
        address: String
    ) async throws -> SendTronAccountResource {
        let object = try await post(
            path: "wallet/getaccountresource",
            body: [
                "address": address,
                "visible": true
            ]
        )
        let freeLimit = try Self.optionalUInt64(
            object["freeNetLimit"],
            code: "free_net_limit"
        )
        let freeUsed = try Self.optionalUInt64(
            object["freeNetUsed"],
            code: "free_net_used"
        )
        let netLimit = try Self.optionalUInt64(
            object["NetLimit"],
            code: "net_limit"
        )
        let netUsed = try Self.optionalUInt64(
            object["NetUsed"],
            code: "net_used"
        )
        let energyLimit = try Self.optionalUInt64(
            object["EnergyLimit"],
            code: "energy_limit"
        )
        let energyUsed = try Self.optionalUInt64(
            object["EnergyUsed"],
            code: "energy_used"
        )
        return SendTronAccountResource(
            freeBandwidthRemaining: freeLimit > freeUsed
                ? freeLimit - freeUsed : 0,
            stakedBandwidthRemaining: netLimit > netUsed
                ? netLimit - netUsed : 0,
            energyRemaining: energyLimit > energyUsed
                ? energyLimit - energyUsed : 0
        )
    }

    func trc20Balance(
        ownerAddress: String,
        contractAddress: String
    ) async throws -> String {
        let parameter = try Self.abiAddress(ownerAddress)
        let object = try await post(
            path: "wallet/triggerconstantcontract",
            body: [
                "owner_address": ownerAddress,
                "contract_address": contractAddress,
                "function_selector": "balanceOf(address)",
                "parameter": parameter,
                "visible": true
            ]
        )
        try Self.validateContractResult(object)
        guard
            let values = object["constant_result"] as? [Any],
            let hexadecimal = values.first as? String,
            hexadecimal.count <= 64,
            !hexadecimal.isEmpty,
            hexadecimal.allSatisfy(\.isHexDigit)
        else {
            throw invalidResponse("trc20_balance")
        }
        return try SendAtomicAmount.decimalFromHexQuantity(
            "0x" + hexadecimal
        )
    }

    func estimatedEnergy(
        ownerAddress: String,
        contractAddress: String,
        recipientAddress: String,
        amountAtomic: String
    ) async throws -> UInt64 {
        let parameter = try Self.transferParameter(
            recipientAddress: recipientAddress,
            amountAtomic: amountAtomic
        )
        do {
            let estimate = try await post(
                path: "wallet/estimateenergy",
                body: [
                    "owner_address": ownerAddress,
                    "contract_address": contractAddress,
                    "function_selector": "transfer(address,uint256)",
                    "parameter": parameter,
                    "visible": true
                ]
            )
            try Self.validateContractResult(estimate)
            if let value = estimate["energy_required"] {
                return try Self.uint64(
                    value,
                    code: "estimated_energy"
                )
            }
        } catch let error as SendTransactionSubmissionError {
            if case let .provider(_, code, _) = error,
               code != "rpc_contract_rejected" {
                throw error
            }
        }

        let constant = try await post(
            path: "wallet/triggerconstantcontract",
            body: [
                "owner_address": ownerAddress,
                "contract_address": contractAddress,
                "function_selector": "transfer(address,uint256)",
                "parameter": parameter,
                "visible": true
            ]
        )
        try Self.validateContractResult(constant)
        guard let energyUsed = constant["energy_used"] else {
            throw invalidResponse("constant_energy")
        }
        return try Self.uint64(
            energyUsed,
            code: "constant_energy"
        )
    }

    func createNativeTransfer(
        ownerAddress: String,
        recipientAddress: String,
        amountAtomic: UInt64
    ) async throws -> SendTronUnsignedTransaction {
        guard let ownerHexAddress = TronValueParser.accountHexAddress(
            ownerAddress
        ) else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        guard let recipientHexAddress = TronValueParser.accountHexAddress(
            recipientAddress
        ) else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        return try await unsignedTransaction(
            path: "wallet/createtransaction",
            body: [
                "owner_address": ownerHexAddress,
                "to_address": recipientHexAddress,
                "amount": String(amountAtomic),
                "visible": false
            ],
            directBody: [
                "owner_address": ownerHexAddress,
                "to_address": recipientHexAddress,
                "amount": amountAtomic,
                "visible": false
            ],
            expectation: .native(
                ownerAddress: ownerHexAddress,
                recipientAddress: recipientHexAddress,
                amount: amountAtomic
            )
        )
    }

    func createTRC20Transfer(
        ownerAddress: String,
        recipientAddress: String,
        contractAddress: String,
        amountAtomic: String,
        feeLimit: UInt64
    ) async throws -> SendTronUnsignedTransaction {
        guard let ownerHexAddress = TronValueParser.accountHexAddress(
            ownerAddress
        ) else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        guard let contractHexAddress = TronValueParser.accountHexAddress(
            contractAddress
        ) else {
            throw SendTransactionSubmissionError.unsupportedAsset
        }
        let parameter = try Self.transferParameter(
            recipientAddress: recipientAddress,
            amountAtomic: amountAtomic
        )
        let object = try await post(
            path: "wallet/triggersmartcontract",
            body: [
                "owner_address": ownerHexAddress,
                "contract_address": contractHexAddress,
                "function_selector": "transfer(address,uint256)",
                "parameter": parameter,
                "fee_limit": String(feeLimit),
                "call_value": "0",
                "visible": false
            ],
            directBody: [
                "owner_address": ownerHexAddress,
                "contract_address": contractHexAddress,
                "function_selector": "transfer(address,uint256)",
                "parameter": parameter,
                "fee_limit": feeLimit,
                "call_value": 0,
                "visible": false
            ]
        )
        try Self.validateContractResult(object)
        guard let transaction = object["transaction"]
            as? [String: Any] else {
            throw invalidResponse("trc20_transaction")
        }
        return try Self.unsignedTransaction(
            from: transaction,
            expectation: .trc20(
                ownerAddress: ownerHexAddress,
                contractAddress: contractHexAddress,
                data: Self.trc20TransferSelector + parameter,
                feeLimit: feeLimit
            )
        )
    }

    func broadcast(signedJSON: String) async throws -> String {
        guard let data = signedJSON.data(using: .utf8),
              let body = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let expectedTransactionID = body["txID"] as? String,
              Self.validTransactionID(expectedTransactionID)
        else {
            throw SendTransactionSubmissionError.signing(
                code: "invalid_tron_signed_json",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        let response = try await post(
            path: "wallet/broadcasttransaction",
            body: [
                "signed_transaction_json": signedJSON
            ],
            directBody: body,
            directEncodedBody: data,
            isBroadcast: true
        )
        guard let transactionID = response["txid"] as? String,
              Self.validTransactionID(transactionID)
        else {
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: TronConstants.networkID,
                    code: "invalid_transaction_id"
                )
        }
        return transactionID.lowercased()
    }

    private func unsignedTransaction(
        path: String,
        body: [String: Any],
        directBody: [String: Any]? = nil,
        expectation: UnsignedContractExpectation
    ) async throws -> SendTronUnsignedTransaction {
        let object = try await post(
            path: path,
            body: body,
            directBody: directBody
        )
        return try Self.unsignedTransaction(
            from: object,
            expectation: expectation
        )
    }

    private static func unsignedTransaction(
        from object: [String: Any],
        expectation: UnsignedContractExpectation
    ) throws -> SendTronUnsignedTransaction {
        let signingObject = try canonicalSigningObject(
            object,
            expectation: expectation
        )
        guard let transactionID = signingObject["txID"] as? String,
              validTransactionID(transactionID),
              let rawDataHex = signingObject["raw_data_hex"] as? String,
              rawDataHex.count.isMultiple(of: 2),
              rawDataHex.allSatisfy(\.isHexDigit),
              JSONSerialization.isValidJSONObject(signingObject)
        else {
            throw invalidResponse("unsigned_transaction")
        }
        let data = try JSONSerialization.data(
            withJSONObject: signingObject,
            options: [.sortedKeys]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw invalidResponse("unsigned_transaction_encoding")
        }
        return SendTronUnsignedTransaction(
            json: json,
            transactionID: transactionID.lowercased(),
            rawDataBytes: rawDataHex.count / 2
        )
    }

    private static func canonicalSigningObject(
        _ object: [String: Any],
        expectation: UnsignedContractExpectation
    ) throws -> [String: Any] {
        guard var rawData = object["raw_data"] as? [String: Any],
              let contracts = rawData["contract"] as? [Any],
              contracts.count == 1,
              var contract = contracts[0] as? [String: Any],
              contract["type"] as? String == expectation.type,
              var parameter = contract["parameter"] as? [String: Any],
              parameter["type_url"] as? String == expectation.typeURL,
              var value = parameter["value"] as? [String: Any],
              isZeroOrMissing(
                  contract["Permission_id"],
                  code: "contract_permission_id"
              ),
              isEmptyOrMissing(contract["provider"]),
              isEmptyOrMissing(contract["ContractName"]),
              isEmptyOrMissing(rawData["data"])
        else {
            throw invalidResponse("unsigned_contract")
        }

        for (field, expectedAddress) in expectation.addresses {
            guard let encodedAddress = value[field] as? String,
                  let canonicalAddress = canonicalSigningAddress(
                      encodedAddress
                  ),
                  canonicalAddress.caseInsensitiveCompare(
                      expectedAddress
                  ) == .orderedSame
            else {
                throw invalidResponse("unsigned_contract_\(field)")
            }
            value[field] = canonicalAddress
        }
        guard expectation.validatesPayload(
            value: value,
            rawData: rawData
        ) else {
            throw invalidResponse("unsigned_contract_payload")
        }

        parameter["value"] = value
        contract["parameter"] = parameter
        rawData["contract"] = [contract]
        var signingObject = object
        signingObject["raw_data"] = rawData
        signingObject["visible"] = false
        return signingObject
    }

    private static func canonicalSigningAddress(
        _ address: String
    ) -> String? {
        let normalized = address.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if let decoded = TronValueParser.accountHexAddress(normalized) {
            return decoded.lowercased()
        }
        guard normalized.count == 42,
              normalized.hasPrefix("41"),
              normalized.allSatisfy(\.isHexDigit)
        else {
            return nil
        }
        return normalized.lowercased()
    }

    private static func isZeroOrMissing(
        _ value: Any?,
        code: String
    ) -> Bool {
        guard let value else { return true }
        return (try? uint64(value, code: code)) == 0
    }

    private static func isEmptyOrMissing(_ value: Any?) -> Bool {
        guard let value else { return true }
        return (value as? String)?.isEmpty == true
    }

    func post(
        path: String,
        body: [String: Any],
        directBody: [String: Any]? = nil,
        directEncodedBody: Data? = nil,
        isBroadcast: Bool = false,
        publicOnly: Bool = false
    ) async throws -> [String: Any] {
        guard !path.isEmpty,
              !path.contains(".."),
              JSONSerialization.isValidJSONObject(body)
        else {
            throw Self.invalidResponse("request")
        }
        let proxyData = try JSONSerialization.data(withJSONObject: body)
        let directObject = directBody ?? body
        guard JSONSerialization.isValidJSONObject(directObject) else {
            throw Self.invalidResponse("direct_request")
        }
        let directData = try directEncodedBody
            ?? JSONSerialization.data(withJSONObject: directObject)
        var prepared: [(url: URL, request: URLRequest, priority: Int)] = []
        if !publicOnly,
           let ankr = try? AnkrConfiguration.runtime(),
           let url = try? ankr.tronRESTEndpoint(path: path) {
            prepared.append((
                url,
                Self.request(
                    url: url,
                    body: ankr.usesTronRESTProxy ? proxyData : directData,
                    timeout: isBroadcast ? 12 : 8
                ),
                0
            ))
        }
        for (index, host) in [
            "https://api.trongrid.io",
            "https://tron-rpc.publicnode.com"
        ].enumerated() {
            let publicURL = URL(string: host)!
                .appending(path: path, directoryHint: .notDirectory)
            guard !prepared.contains(where: { $0.url == publicURL }) else { continue }
            prepared.append((
                publicURL,
                Self.request(
                    url: publicURL,
                    body: directData,
                    timeout: isBroadcast ? 12 : 8
                ),
                index + 1
            ))
        }
        let serviceID = isBroadcast
            ? "tron_rest_submission"
            : "tron_rest_read_" + path.replacingOccurrences(
                of: "/",
                with: "_"
            )
        let session = session
        let router = router
        let expectedTransactionID = (directObject["txID"] as? String)?.lowercased()
        let attempts: [AdaptiveProviderAttempt<Data>] = prepared.map {
            prepared in
            let endpoint = AdaptiveProviderEndpoint(
                serviceID: serviceID,
                endpointURL: prepared.url,
                baselinePriority: prepared.priority
            )
            return AdaptiveProviderAttempt(endpoint: endpoint) {
                try await Self.perform(
                    prepared.request,
                    session: session,
                    isBroadcast: isBroadcast,
                    expectedTransactionID: expectedTransactionID
                )
            }
        }
        do {
            let ranked = await router.ordered(
                attempts.map(\.endpoint), allowExploration: !isBroadcast
            )
            let byEndpoint = Dictionary(uniqueKeysWithValues: attempts.map { ($0.endpoint, $0) })
            let retries: [SendTronRequestRetrier.Attempt<Data>] = ranked.compactMap { endpoint in
                guard let attempt = byEndpoint[endpoint] else { return nil }
                return {
                    do {
                        // Each attempt reuses the original request bytes. In particular,
                        // broadcasts never rebuild or sign a second transaction.
                        if isBroadcast {
                            return try await router.executeSubmission(
                                serviceID: serviceID, attempts: [attempt],
                                timeoutSeconds: 12,
                                isReliabilityFailure: Self.isReliabilityFailure
                            )
                        }
                        return try await router.executeRead(
                            serviceID: serviceID, attempts: [attempt],
                            timeoutSeconds: 8,
                            shouldFallback: Self.isReliabilityFailure
                        )
                    } catch let failure as SendTronRetryableFailure {
                        throw failure
                    } catch {
                        guard Self.isReliabilityFailure(error) else { throw error }
                        throw SendTronRetryableFailure(
                            underlying: Self.normalizedPostFailure(error, isBroadcast: isBroadcast),
                            submissionMayHaveSucceeded: isBroadcast
                        )
                    }
                }
            }
            let responseData = try await SendTronRequestRetrier.execute(
                attempts: retries, sleep: retrySleep
            )
            guard let object = try? JSONSerialization.jsonObject(
                with: responseData
            ) as? [String: Any] else {
                throw Self.invalidResponse("json_after_routing")
            }
            return object
        } catch {
            throw Self.normalizedPostFailure(
                error,
                isBroadcast: isBroadcast
            )
        }
    }

    nonisolated static func normalizedPostFailure(
        _ error: Error,
        isBroadcast: Bool
    ) -> Error {
        if let submissionError = error as? SendTransactionSubmissionError {
            return submissionError
        }
        if isBroadcast {
            return SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: TronConstants.networkID,
                code: error is CancellationError
                    ? "cancelled_after_broadcast_started"
                    : SendTransactionSubmissionError
                        .sanitizedErrorType(error)
            )
        }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return CancellationError()
        }
        return SendTransactionSubmissionError.provider(
            networkID: TronConstants.networkID,
            code: SendTransactionSubmissionError.sanitizedErrorType(error),
            message: WalletLocalization.string(
                "send.submit.error.provider_transport"
            )
        )
    }

    private static func request(
        url: URL,
        body: Data,
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Aperture", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        return request
    }

    private static func perform(
        _ request: URLRequest,
        session: URLSession,
        isBroadcast: Bool,
        expectedTransactionID: String?
    ) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            if isBroadcast {
                throw SendTransactionSubmissionError
                    .broadcastOutcomeUnknown(
                        networkID: TronConstants.networkID,
                        code: "non_http_response"
                    )
            }
            throw Self.invalidResponse("non_http")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            let details = Self.providerErrorDetails(
                object ?? [:],
                statusCode: http.statusCode,
                rawData: data
            )
            let temporary = ProviderReliabilityClassification.isRetryableHTTPStatus(http.statusCode)
                || SendTronRequestRetrier.isTemporary(code: details.code, message: details.message)
            throw providerFailure(
                code: details.code, message: details.message,
                isBroadcast: isBroadcast, temporary: temporary,
                retryAfter: SendTronRequestRetrier.retryAfter(http)
            )
        }
        guard let object else {
            if isBroadcast {
                throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                    networkID: TronConstants.networkID, code: "invalid_json"
                )
            }
            throw Self.invalidResponse("json")
        }
        let contractResult = object["result"] as? [String: Any]
        if object["Error"] != nil || object["error"] != nil
            || object["result"] as? Bool == false
            || contractResult?["result"] as? Bool == false {
            let details = providerErrorDetails(
                contractResult ?? object, statusCode: http.statusCode, rawData: data
            )
            throw providerFailure(
                code: details.code, message: details.message,
                isBroadcast: isBroadcast,
                temporary: SendTronRequestRetrier.isTemporary(code: details.code, message: details.message),
                retryAfter: SendTronRequestRetrier.retryAfter(http)
            )
        }
        if isBroadcast {
            guard object["result"] as? Bool == true,
                  let transactionID = object["txid"] as? String,
                  validTransactionID(transactionID),
                  transactionID.lowercased() == expectedTransactionID else {
                throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                    networkID: TronConstants.networkID, code: "invalid_transaction_id"
                )
            }
        }
        return data
    }

    private static func providerFailure(
        code: String, message: String, isBroadcast: Bool,
        temporary: Bool, retryAfter: TimeInterval?
    ) -> Error {
        let error: SendTransactionSubmissionError
        if isBroadcast {
            error = temporary
                ? .broadcastOutcomeUnknown(networkID: TronConstants.networkID, code: code)
                : .broadcastRejected(code: code, message: message)
        } else {
            error = .provider(networkID: TronConstants.networkID, code: code, message: message)
        }
        return temporary ? SendTronRetryableFailure(
            underlying: error, retryAfter: retryAfter,
            submissionMayHaveSucceeded: isBroadcast
        ) : error
    }

    private static func isReliabilityFailure(_ error: Error) -> Bool {
        if error is SendTronRetryableFailure { return true }
        if case SendTransactionSubmissionError.broadcastOutcomeUnknown = error { return true }
        if ProviderReliabilityClassification.isRetryableTransport(error) {
            return true
        }
        guard case let SendTransactionSubmissionError.provider(
            _, code, message
        ) = error else {
            return false
        }
        if code.hasPrefix("invalid_")
            || SendTronRequestRetrier.isTemporary(code: code, message: message) {
            return true
        }
        guard code.hasPrefix("http_") else { return false }
        let statusText = code.dropFirst("http_".count).prefix {
            $0.isNumber
        }
        return Int(statusText).map(
            ProviderReliabilityClassification.isRetryableHTTPStatus
        ) ?? false
    }

    private static func providerErrorDetails(
        _ object: [String: Any],
        statusCode: Int,
        rawData: Data
    ) -> (code: String, message: String) {
        let fallbackCode = "http_\(statusCode)"
        var code = object["code"] as? String ?? fallbackCode
        var message = ""
        if let error = object["error"] as? [String: Any] {
            if let value = error["code"] as? String,
               !value.isEmpty {
                code = value
            } else if let value = error["code"] as? NSNumber {
                code = value.stringValue
            }
            message = error["message"] as? String ?? ""
        } else if let value = object["error"] as? String {
            message = value
        } else if let value = object["Error"] as? String {
            message = value
        } else if let value = object["message"] as? String {
            message = value
        }
        if message.isEmpty {
            message = String(data: rawData, encoding: .utf8) ?? ""
        }
        return (
            SendTransactionSubmissionError.sanitized(code),
            SendTransactionSubmissionError.sanitizedMessage(SendTronProviderMessage.decode(message))
        )
    }

    private static func validateContractResult(
        _ object: [String: Any]
    ) throws {
        if let result = object["result"] as? [String: Any],
           result["result"] as? Bool != true {
            throw SendTransactionSubmissionError.provider(
                networkID: TronConstants.networkID,
                code: "rpc_contract_rejected",
                message: SendTransactionSubmissionError
                    .sanitizedMessage(
                        SendTronProviderMessage.decode(result["message"] as? String ?? "")
                    )
            )
        }
    }

    private static func transferParameter(
        recipientAddress: String,
        amountAtomic: String
    ) throws -> String {
        try abiAddress(recipientAddress)
            + SendAtomicAmount.fixedWidthData(
                amountAtomic,
                byteCount: 32
            ).hexString
    }

    private static func abiAddress(_ address: String) throws -> String {
        guard let data = TronValueParser.accountAddressData(address) else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        return Data(repeating: 0, count: 12).hexString
            + data.dropFirst().map {
                String(format: "%02x", $0)
            }.joined()
    }

    private static func optionalUInt64(
        _ value: Any?,
        code: String
    ) throws -> UInt64 {
        guard let value else { return 0 }
        return try uint64(value, code: code)
    }

    private static func uint64(
        _ value: Any,
        code: String
    ) throws -> UInt64 {
        if let number = value as? NSNumber {
            let text = number.stringValue
            guard !text.hasPrefix("-"),
                  !text.contains("."),
                  !text.contains("e"),
                  !text.contains("E"),
                  let result = UInt64(text)
            else {
                throw invalidResponse(code)
            }
            return result
        }
        if let text = value as? String,
           let result = UInt64(text) {
            return result
        }
        throw invalidResponse(code)
    }

    private static func validTransactionID(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func invalidResponse(
        _ code: String
    ) -> SendTransactionSubmissionError {
        .provider(
            networkID: TronConstants.networkID,
            code: "invalid_\(code)",
            message: WalletLocalization.string(
                "send.submit.error.provider_invalid_response"
            )
        )
    }

    private func invalidResponse(
        _ code: String
    ) -> SendTransactionSubmissionError {
        Self.invalidResponse(code)
    }
}
