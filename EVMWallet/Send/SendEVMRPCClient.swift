import Foundation

private struct SendEVMRPCRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [AnyEncodable]
}

private struct SendEVMRPCResponse: Decodable {
    let id: Int?
    let result: JSONValue?
    let error: SendEVMRPCErrorPayload?
    let containsResult: Bool

    private enum CodingKeys: String, CodingKey {
        case id, result, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        containsResult = container.contains(.result)
        result = try container.decodeIfPresent(
            JSONValue.self,
            forKey: .result
        )
        error = try container.decodeIfPresent(
            SendEVMRPCErrorPayload.self,
            forKey: .error
        )
    }
}

private struct SendEVMRPCErrorPayload: Decodable {
    let code: Int
    let message: String
}

actor SendEVMRPCClient {
    private let networkID: String
    private let endpoints: [URL]
    private let submissionEndpoints: [URL]
    private let session: URLSession
    private var requestID = 0

    init(
        networkID: String,
        session: URLSession? = nil,
        endpoints: [URL]? = nil,
        submissionEndpoints: [URL]? = nil
    ) throws {
        guard let resolvedEndpoints = endpoints
                ?? Self.endpointSets[networkID],
              !resolvedEndpoints.isEmpty
        else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        let resolvedSubmissionEndpoints: [URL]
        if let submissionEndpoints {
            resolvedSubmissionEndpoints = submissionEndpoints
        } else if endpoints != nil {
            resolvedSubmissionEndpoints = resolvedEndpoints
        } else {
            resolvedSubmissionEndpoints =
                Self.submissionEndpointSets[networkID]
                ?? resolvedEndpoints
        }
        guard !resolvedSubmissionEndpoints.isEmpty else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        self.networkID = networkID
        self.endpoints = Self.unique(resolvedEndpoints)
        self.submissionEndpoints = Self.unique(
            resolvedSubmissionEndpoints
        )
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 25
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func chainID() async throws -> String {
        try await stringResult(method: "eth_chainId")
    }

    func transactionCount(address: String) async throws -> String {
        try await stringResult(
            method: "eth_getTransactionCount",
            params: [AnyEncodable(address), AnyEncodable("pending")]
        )
    }

    func confirmedTransactionCount(address: String) async throws -> String {
        try await stringResult(method: "eth_getTransactionCount",
            params: [AnyEncodable(address), AnyEncodable("latest")])
    }

    /// Nonce consumption alone does not prove replacement: an indexer may lag.
    /// Require a mined transaction with the same sender and nonce. Old conflicts
    /// outside this bounded window remain Not Found, eligible for later checks.
    func confirmedReplacement(hash: String, sender: String, nonce: Int64) async throws -> String? {
        guard nonce >= 0, SendAddressValidator.isValidEVMAddress(sender) else { return nil }
        let session = session
        let networkID = networkID
        for endpoint in endpoints.prefix(2) {
            let identity = AdaptiveProviderEndpoint(serviceID: "replacement.\(networkID)", endpointURL: endpoint, baselinePriority: 0)
            do {
                return try await ProviderRequestDeadline.run(seconds: 12, endpoint: identity) {
                    func read(_ method: String, _ params: [AnyEncodable]) async throws -> JSONValue? {
                        var request = URLRequest(url: endpoint)
                        request.httpMethod = "POST"
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.httpBody = try JSONEncoder().encode(SendEVMRPCRequest(id: 1, method: method, params: params))
                        let (data, response) = try await session.data(for: request)
                        try Task.checkCancellation()
                        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8_388_608 else {
                            throw SendTransactionStatusProviderError.invalidResponse(networkID: networkID, code: "replacement_http")
                        }
                        let value = try JSONDecoder().decode(SendEVMRPCResponse.self, from: data)
                        guard value.id == 1, value.containsResult, value.error == nil else {
                            throw SendTransactionStatusProviderError.invalidResponse(networkID: networkID, code: "replacement_envelope")
                        }
                        return value.result
                    }
                    guard let tipHex = try await read("eth_blockNumber", [])?.string,
                          let tip = UInt64(try SendAtomicAmount.decimalFromHexQuantity(tipHex)) else { return nil }
                    for offset in 0...min(tip, 15) {
                        let height = tip - offset
                        guard let block = try await read("eth_getBlockByNumber", [AnyEncodable("0x" + String(height, radix: 16)), AnyEncodable(true)])?.object,
                              let blockNumber = block["number"]?.string,
                              try SendAtomicAmount.decimalFromHexQuantity(blockNumber) == String(height),
                              let blockHash = block["hash"]?.string,
                              SendTransactionStatusValidation.isHexHash(blockHash, byteCount: 32, allowsPrefix: true),
                              let transactions = block["transactions"]?.array else { continue }
                        for value in transactions {
                            guard let tx = value.object, let other = tx["hash"]?.string,
                                  other.lowercased() != hash.lowercased(),
                                  SendTransactionStatusValidation.isHexHash(other, byteCount: 32, allowsPrefix: true),
                                  tx["from"]?.string?.lowercased() == sender.lowercased(),
                                  tx["blockHash"]?.string?.lowercased() == blockHash.lowercased(),
                                  let txNonce = tx["nonce"]?.string,
                                  try SendAtomicAmount.decimalFromHexQuantity(txNonce) == String(nonce) else { continue }
                            return other
                        }
                    }
                    return nil
                }
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        return nil
    }

    func transactionNonce(hash: String, fromAddress: String) async throws -> String {
        guard SendTransactionStatusValidation.isHexHash(hash, byteCount: 32, allowsPrefix: true),
              hash.hasPrefix("0x"), SendAddressValidator.isValidEVMAddress(fromAddress) else {
            throw SendTransactionStatusProviderError.invalidTransactionHash(networkID: networkID)
        }
        let value = try await stringResult(
            method: "eth_getTransactionByHash", params: [AnyEncodable(hash)],
            transactionIdentity: (hash, fromAddress)
        )
        return try SendAtomicAmount.decimalFromHexQuantity(value)
    }

    func nativeBalance(address: String) async throws -> String {
        try await stringResult(
            method: "eth_getBalance",
            params: [AnyEncodable(address), AnyEncodable("latest")]
        )
    }

    func tokenBalance(
        ownerAddress: String,
        contractAddress: String
    ) async throws -> String {
        let owner = try Self.abiAddress(ownerAddress)
        let data = "0x70a08231" + owner
        return try await stringResult(
            method: "eth_call",
            params: [
                AnyEncodable([
                    "to": contractAddress,
                    "data": data
                ]),
                AnyEncodable("latest")
            ]
        )
    }

    /// Raw `eth_call` result for a string-returning ERC-20 view such as
    /// `name()` (`0x06fdde03`) or `symbol()` (`0x95d89b41`).
    func tokenStringMetadata(
        contractAddress: String,
        selector: String
    ) async throws -> String {
        try await stringResult(
            method: "eth_call",
            params: [
                AnyEncodable([
                    "to": contractAddress,
                    "data": selector
                ]),
                AnyEncodable("latest")
            ]
        )
    }

    func tokenDecimals(contractAddress: String) async throws -> Int {
        let result = try await stringResult(
            method: "eth_call",
            params: [
                AnyEncodable([
                    "to": contractAddress,
                    "data": "0x313ce567"
                ]),
                AnyEncodable("latest")
            ]
        )
        let value = try SendAtomicAmount
            .decimalFromABIUnsignedInteger(result)
        guard let decimals = Int(value), (0...255).contains(decimals) else {
            throw SendTransactionSubmissionError.provider(
                networkID: networkID,
                code: "token_decimals_invalid",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        return decimals
    }

    func callContract(
        contractAddress: String,
        data: String
    ) async throws -> String {
        guard SendAddressValidator.isValidEVMAddress(contractAddress),
              data.hasPrefix("0x"),
              data.dropFirst(2).allSatisfy({ $0.isHexDigit }),
              data.dropFirst(2).count.isMultiple(of: 2)
        else {
            throw SendTransactionSubmissionError.provider(
                networkID: networkID,
                code: "eth_call_invalid_parameters",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        return try await stringResult(
            method: "eth_call",
            params: [
                AnyEncodable([
                    "to": contractAddress,
                    "data": data
                ]),
                AnyEncodable("latest")
            ]
        )
    }

    func estimateGas(
        from: String,
        to: String,
        value: String,
        data: String?,
        gasPrice: String? = nil,
        maximumFeePerGas: String? = nil,
        priorityFeePerGas: String? = nil
    ) async throws -> String {
        var call = [
            "from": from,
            "to": to,
            "value": value
        ]
        if let data {
            call["data"] = data
        }
        if let gasPrice {
            call["gasPrice"] = gasPrice
        }
        if let maximumFeePerGas {
            call["maxFeePerGas"] = maximumFeePerGas
        }
        if let priorityFeePerGas {
            call["maxPriorityFeePerGas"] = priorityFeePerGas
        }
        return try await stringResult(
            method: "eth_estimateGas",
            params: [AnyEncodable(call)]
        )
    }

    func broadcast(rawTransaction: String) async throws -> String {
        try await stringResult(
            method: "eth_sendRawTransaction",
            params: [AnyEncodable(rawTransaction)],
            isBroadcast: true
        )
    }

    func transactionStatus(
        hash: String
    ) async throws -> SendTransactionNetworkStatus {
        let normalizedHash = hash.lowercased()
        guard SendTransactionStatusValidation.isHexHash(
            normalizedHash,
            byteCount: 32,
            allowsPrefix: true
        ), normalizedHash.hasPrefix("0x") else {
            throw SendTransactionStatusProviderError
                .invalidTransactionHash(networkID: networkID)
        }
        requestID += 1
        let expectedID = requestID
        let payload = SendEVMRPCRequest(
            id: expectedID,
            method: "eth_getTransactionReceipt",
            params: [AnyEncodable(normalizedHash)]
        )
        let requestBody = try JSONEncoder().encode(payload)
        let serviceID = "provider-routing.evm.\(networkID).jsonrpc-status"
        let currentNetworkID = networkID
        let currentSession = session
        let attempts = endpoints.enumerated().map { index, endpoint in
            let identity = AdaptiveProviderEndpoint(
                serviceID: serviceID,
                endpointURL: endpoint,
                baselinePriority: index
            )
            return AdaptiveProviderAttempt(endpoint: identity) {
                try await Self.performTransactionStatus(
                    endpoint: endpoint,
                    requestBody: requestBody,
                    expectedID: expectedID,
                    networkID: currentNetworkID,
                    expectedHash: normalizedHash,
                    session: currentSession
                )
            }
        }
        do {
            return try await SendStatusReadResolver.resolve(attempts: attempts)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SendTransactionSubmissionError {
            throw error
        } catch {
            throw SendTransactionSubmissionError.provider(
                networkID: networkID,
                code: Self.errorCode(error),
                message: WalletLocalization.string(
                    "send.submit.error.provider_transport"
                )
            )
        }
    }

    private func stringResult(
        method: String,
        params: [AnyEncodable] = [],
        isBroadcast: Bool = false,
        transactionIdentity: (hash: String, from: String)? = nil
    ) async throws -> String {
        requestID += 1
        let expectedID = requestID
        let payload = SendEVMRPCRequest(
            id: expectedID,
            method: method,
            params: params
        )
        let requestBody = try JSONEncoder().encode(payload)
        let serviceID = "provider-routing.evm.\(networkID).jsonrpc"
        let currentNetworkID = networkID
        let currentSession = session
        let requestEndpoints = isBroadcast
            ? submissionEndpoints
            : endpoints
        let attempts = requestEndpoints.enumerated().map { index, endpoint in
            let identity = AdaptiveProviderEndpoint(
                serviceID: serviceID,
                endpointURL: endpoint,
                baselinePriority: index
            )
            return AdaptiveProviderAttempt(endpoint: identity) {
                try await Self.perform(
                    endpoint: endpoint,
                    requestBody: requestBody,
                    expectedID: expectedID,
                    networkID: currentNetworkID,
                    session: currentSession,
                    isBroadcast: isBroadcast,
                    transactionIdentity: transactionIdentity
                )
            }
        }
        do {
            if isBroadcast {
                return try await AdaptiveProviderRouter.shared
                    .executeSubmission(
                        serviceID: serviceID,
                        attempts: attempts,
                        timeoutSeconds: 15,
                        isReliabilityFailure: Self.isReliabilityFailure
                    )
            }
            return try await AdaptiveProviderRouter.shared.executeRead(
                serviceID: serviceID,
                attempts: attempts,
                timeoutSeconds: 8,
                shouldFallback: Self.isReliabilityFailure
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SendTransactionSubmissionError {
            throw error
        } catch {
            if isBroadcast {
                throw SendTransactionSubmissionError
                    .broadcastOutcomeUnknown(
                        networkID: networkID,
                        code: Self.errorCode(error)
                    )
            }
            throw SendTransactionSubmissionError.provider(
                networkID: networkID,
                code: Self.errorCode(error),
                message: WalletLocalization.string(
                    "send.submit.error.provider_transport"
                )
            )
        }
    }

    private nonisolated static func perform(
        endpoint: URL,
        requestBody: Data,
        expectedID: Int,
        networkID: String,
        session: URLSession,
        isBroadcast: Bool,
        transactionIdentity: (hash: String, from: String)? = nil
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.httpBody = requestBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if isBroadcast {
                throw SendTransactionSubmissionError
                    .broadcastOutcomeUnknown(
                        networkID: networkID,
                        code: Self.errorCode(error)
                    )
            }
            throw error
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            if isBroadcast {
                throw SendTransactionSubmissionError
                    .broadcastOutcomeUnknown(
                        networkID: networkID,
                        code: "non_http_response"
                    )
            }
            throw SendTransactionSubmissionError.provider(
                networkID: networkID,
                code: "non_http_response",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }

        let envelope = try? JSONDecoder().decode(
            SendEVMRPCResponse.self,
            from: data
        )
        if let error = envelope?.error {
            if isBroadcast {
                let code = "rpc_\(error.code)"
                if SendEVMSubmissionErrorClassifier.isDefinitiveRPCRejection(
                    code: error.code,
                    message: error.message
                ) {
                    throw SendTransactionSubmissionError.broadcastRejected(
                        code: code,
                        message: Self.sanitize(error.message)
                    )
                }
                throw SendTransactionSubmissionError
                    .broadcastOutcomeUnknown(
                        networkID: networkID,
                        code: code
                    )
            }
            throw SendTransactionSubmissionError.provider(
                networkID: networkID,
                code: "rpc_\(error.code)",
                message: Self.sanitize(error.message)
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            if isBroadcast {
                throw SendTransactionSubmissionError
                    .broadcastOutcomeUnknown(
                        networkID: networkID,
                        code: "http_\(http.statusCode)"
                    )
            }
            throw SendTransactionSubmissionError.provider(
                networkID: networkID,
                code: "http_\(http.statusCode)",
                message: Self.sanitize(
                    String(data: data, encoding: .utf8)
                        ?? WalletLocalization.string(
                            "send.submit.error.provider_invalid_response"
                        )
                )
            )
        }
        let resultValue: String?
        if let transactionIdentity {
            let transaction = envelope?.result?.object
            guard transaction?["hash"]?.string?.lowercased() == transactionIdentity.hash.lowercased(),
                  transaction?["from"]?.string?.lowercased() == transactionIdentity.from.lowercased() else {
                throw SendTransactionSubmissionError.provider(
                    networkID: networkID, code: "transaction_identity_unavailable",
                    message: WalletLocalization.string("send.submit.error.provider_invalid_response")
                )
            }
            resultValue = transaction?["nonce"]?.string
        } else {
            resultValue = envelope?.result?.string
        }
        guard let envelope,
              envelope.id == expectedID,
              let result = resultValue,
              !result.isEmpty
        else {
            if isBroadcast {
                throw SendTransactionSubmissionError
                    .broadcastOutcomeUnknown(
                        networkID: networkID,
                        code: "invalid_result"
                    )
            }
            throw SendTransactionSubmissionError.provider(
                networkID: networkID,
                code: "invalid_result",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        return result
    }

    private nonisolated static func performTransactionStatus(
        endpoint: URL,
        requestBody: Data,
        expectedID: Int,
        networkID: String,
        expectedHash: String,
        session: URLSession
    ) async throws -> SendTransactionNetworkStatus {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.httpBody = requestBody
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw SendTransactionSubmissionError.provider(
                networkID: networkID,
                code: "non_http_response",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        let envelope = try? JSONDecoder().decode(
            SendEVMRPCResponse.self,
            from: data
        )
        if let error = envelope?.error {
            throw SendTransactionSubmissionError.provider(
                networkID: networkID,
                code: "rpc_\(error.code)",
                message: Self.sanitize(error.message)
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SendTransactionSubmissionError.provider(
                networkID: networkID,
                code: "http_\(http.statusCode)",
                message: Self.sanitize(
                    String(data: data, encoding: .utf8)
                        ?? WalletLocalization.string(
                            "send.submit.error.provider_invalid_response"
                        )
                )
            )
        }
        guard let envelope, envelope.id == expectedID else {
            throw SendTransactionStatusProviderError.invalidResponse(
                networkID: networkID,
                code: "receipt_envelope"
            )
        }
        guard envelope.containsResult else {
            throw SendTransactionStatusProviderError.invalidResponse(
                networkID: networkID,
                code: "receipt_result_missing"
            )
        }
        guard let result = envelope.result else {
            // A null receipt is normal for an actual mempool transaction. Ask
            // for that identity before distinguishing pending from not found.
            let lookup = SendEVMRPCRequest(id: expectedID, method: "eth_getTransactionByHash",
                params: [AnyEncodable(expectedHash)])
            request.httpBody = try JSONEncoder().encode(lookup)
            let (lookupData, lookupResponse) = try await session.data(for: request)
            guard let lookupHTTP = lookupResponse as? HTTPURLResponse, lookupHTTP.statusCode == 200,
                  lookupData.count <= 1_048_576 else {
                throw SendTransactionStatusProviderError.invalidResponse(networkID: networkID, code: "transaction_lookup_http")
            }
            let lookupEnvelope = try JSONDecoder().decode(SendEVMRPCResponse.self, from: lookupData)
            guard lookupEnvelope.id == expectedID, lookupEnvelope.containsResult, lookupEnvelope.error == nil else {
                throw SendTransactionStatusProviderError.invalidResponse(networkID: networkID, code: "transaction_lookup_envelope")
            }
            guard let transaction = lookupEnvelope.result else { return .notFound }
            guard transaction.object?["hash"]?.string?.lowercased() == expectedHash.lowercased() else {
                throw SendTransactionStatusProviderError.invalidResponse(networkID: networkID, code: "transaction_lookup_identity")
            }
            return .pending
        }
        return try transactionStatus(
            from: result,
            expectedHash: expectedHash,
            networkID: networkID
        )
    }

    nonisolated static func transactionStatus(
        from result: JSONValue,
        expectedHash: String,
        networkID: String
    ) throws -> SendTransactionNetworkStatus {
        guard let object = result.object,
              object["transactionHash"]?.string?.lowercased()
                == expectedHash.lowercased(),
              let blockNumber = object["blockNumber"]?.string,
              blockNumber.hasPrefix("0x"),
              let height = UInt64(blockNumber.dropFirst(2), radix: 16),
              height > 0,
              let status = object["status"]?.string?.lowercased() else {
            throw SendTransactionStatusProviderError.invalidResponse(
                networkID: networkID,
                code: "receipt"
            )
        }
        switch status {
        case "0x1":
            return .confirmed
        case "0x0":
            return .failed
        default:
            throw SendTransactionStatusProviderError.invalidResponse(
                networkID: networkID,
                code: "receipt_status"
            )
        }
    }

    private nonisolated static func isReliabilityFailure(
        _ error: Error
    ) -> Bool {
        if ProviderReliabilityClassification
            .isRetryableTransport(error) {
            return true
        }
        if let statusError = error
                as? SendTransactionStatusProviderError,
           case .invalidResponse = statusError {
            return true
        }
        guard let submissionError = error
                as? SendTransactionSubmissionError
        else { return false }
        switch submissionError {
        case let .provider(_, code, message):
            if code == "non_http_response" { return true }
            let normalizedMessage = message.lowercased()
            if normalizedMessage.contains("archive request")
                && normalizedMessage.contains("personal token") {
                return true
            }
            if code.hasPrefix("http_"),
               let status = Int(code.dropFirst(5)) {
                return ProviderReliabilityClassification
                    .isRetryableHTTPStatus(status)
            }
            if code.hasPrefix("rpc_"),
               let rpcCode = Int(code.dropFirst(4)) {
                return ProviderReliabilityClassification
                    .isRetryableJSONRPCError(
                        code: rpcCode,
                        message: message
                    )
            }
            return false
        case .broadcastOutcomeUnknown:
            return true
        default:
            return false
        }
    }

    private static func abiAddress(_ address: String) throws -> String {
        let normalized = address.lowercased()
        guard normalized.hasPrefix("0x"),
              normalized.count == 42,
              normalized.dropFirst(2).allSatisfy(\.isHexDigit)
        else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        return String(repeating: "0", count: 24)
            + normalized.dropFirst(2)
    }

    private static func sanitize(_ message: String) -> String {
        SendTransactionSubmissionError.sanitizedMessage(
            String(message.prefix(300))
        )
    }

    private static func errorCode(_ error: Error) -> String {
        SendTransactionSubmissionError.sanitizedErrorType(error)
    }

    private nonisolated static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    private static let endpointSets: [String: [URL]] = [
        "eth": [
            URL(string: "https://ethereum-rpc.publicnode.com")!,
            URL(string: "https://eth.drpc.org")!,
            URL(string: "https://rpc.flashbots.net")!
        ],
        "bsc": [
            URL(string: "https://bsc-dataseed.bnbchain.org")!,
            URL(string: "https://bsc-dataseed.binance.org")!,
            URL(string: "https://bsc-dataseed.nariox.org")!,
            URL(string: "https://bsc-dataseed.defibit.io")!
        ],
        "arbitrum": [
            URL(string: "https://arbitrum-one-rpc.publicnode.com")!,
            URL(string: "https://arb1.arbitrum.io/rpc")!
        ],
        "base": [
            URL(string: "https://base-rpc.publicnode.com")!,
            URL(string: "https://mainnet.base.org")!
        ],
        "polygon": [
            URL(string: "https://polygon-bor-rpc.publicnode.com")!,
            URL(string: "https://polygon.drpc.org")!
        ],
        "optimism": [
            URL(string: "https://optimism-rpc.publicnode.com")!,
            URL(string: "https://mainnet.optimism.io")!
        ],
        "avalanche": [
            URL(string: "https://avalanche-c-chain-rpc.publicnode.com")!,
            URL(string: "https://api.avax.network/ext/bc/C/rpc")!
        ],
        "gnosis": [
            URL(string: "https://gnosis-rpc.publicnode.com")!,
            URL(string: "https://rpc.gnosischain.com")!
        ],
        "linea": [
            URL(string: "https://linea-rpc.publicnode.com")!,
            URL(string: "https://rpc.linea.build")!
        ],
        "scroll": [
            URL(string: "https://scroll-rpc.publicnode.com")!,
            URL(string: "https://rpc.scroll.io")!,
            URL(string: "https://scroll.drpc.org")!
        ],
        "taiko": [
            URL(string: "https://taiko-rpc.publicnode.com")!,
            URL(string: "https://rpc.mainnet.taiko.xyz")!
        ],
        "telos": [
            URL(string: "https://rpc.telos.net")!,
            URL(string: "https://rpc1.us.telos.net/evm")!
        ],
        "xlayer": [
            URL(string: "https://rpc.xlayer.tech")!,
            URL(string: "https://xlayer.drpc.org")!,
            URL(string: "https://xlayerrpc.okx.com")!
        ],
        "arc": [
            URL(string: "https://rpc.mainnet.arc.io")!,
            URL(string: "https://arc-rpc.publicnode.com")!,
            URL(string: "https://arc.drpc.org")!
        ]
    ]

    /// Protect-style relays are useful independent read fallbacks, but Send
    /// must submit a signed payload to one ordinary public-mempool endpoint.
    /// Keeping this set separate also preserves one-shot broadcast semantics.
    private static let submissionEndpointSets: [String: [URL]] = [
        "eth": [
            URL(string: "https://ethereum-rpc.publicnode.com")!,
            URL(string: "https://eth.drpc.org")!
        ]
    ]
}

enum SendEVMSubmissionErrorClassifier {
    static func isDefinitiveRPCRejection(
        code: Int,
        message: String
    ) -> Bool {
        if [-32_700, -32_600, -32_601, -32_602].contains(code) {
            return true
        }
        let value = message.lowercased()
        if isKnownTransactionMessage(value) { return true }
        if value.contains("replacement transaction underpriced") {
            return false
        }
        return [
            "nonce too high",
            "insufficient funds",
            "intrinsic gas too low",
            "exceeds block gas limit",
            "invalid sender",
            "invalid signature",
            "invalid transaction",
            "rlp",
            "transaction type not supported",
            "max fee per gas less than block base fee",
            "transaction underpriced"
        ].contains { value.contains($0) }
    }

    static func isKnownTransactionMessage(_ message: String) -> Bool {
        let value = message.lowercased()
        return value.contains("already known")
            || value.contains("known transaction")
            || value.contains("already imported")
    }
}
