import Foundation

actor AptosRESTTransport {
    private let baseURLs: [URL]
    private let session: URLSession

    init(baseURL: URL? = nil, session: URLSession? = nil) {
        self.baseURLs = baseURL.map { [$0] } ?? [
            AptosConstants.defaultRESTBaseURL,
            AptosConstants.fallbackRESTBaseURL
        ]
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 10
            self.session = URLSession(configuration: configuration)
        }
    }

    func get<Response: Decodable & Sendable>(
        path: String,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        try await performRead(path: path, query: query, method: "GET")
    }

    func post<Response: Decodable & Sendable, Body: Encodable>(
        path: String,
        body: Body,
        contentType: String = "application/json"
    ) async throws -> Response {
        let encodedBody = try JSONEncoder().encode(body)
        return try await performRead(
            path: path,
            method: "POST",
            contentType: contentType,
            body: encodedBody
        )
    }

    func submit(signedTransaction: Data) async throws -> AptosSubmitResult {
        let attempts = try baseURLs.enumerated().map { index, baseURL in
            var request = try request(
                baseURL: baseURL,
                path: "transactions",
                method: "POST"
            )
            request.setValue(
                "application/x.aptos.signed_transaction+bcs",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = signedTransaction
            let submissionRequest = request
            let endpoint = AdaptiveProviderEndpoint(
                serviceID: "aptos_rest_submission",
                endpointURL: baseURL,
                baselinePriority: index
            )
            return AdaptiveProviderAttempt<AptosSubmittedTransaction>(
                endpoint: endpoint,
                operation: { [session] in
                    try await Self.perform(
                        submissionRequest,
                        session: session
                    )
                }
            )
        }
        let response = try await AdaptiveProviderRouter.shared
            .executeSubmission(
                serviceID: "aptos_rest_submission",
                attempts: attempts,
                timeoutSeconds: 10,
                isReliabilityFailure: Self.isReliabilityFailure
            )
        // `POST /transactions` returns the `PendingTransaction` schema
        // directly. Unlike the transaction lookup union, that response does
        // not require a `type` discriminator. Some fullnodes still include
        // one, so accept it only when it has the expected value.
        guard (response.type == nil || response.type == "pending_transaction"),
              response.hash.hasPrefix("0x"),
              response.hash.count == 66
        else { throw AptosProviderError.invalidResponse("submit") }
        return AptosSubmitResult(transactionHash: response.hash.lowercased())
    }

    func simulate(
        signedTransaction: Data
    ) async throws -> AptosSimulationResult {
        guard signedTransaction.count > 64 else {
            throw AptosProviderError.invalidResponse("simulation_signature")
        }
        var simulationBytes = signedTransaction
        simulationBytes.replaceSubrange(
            (simulationBytes.count - 64)..<simulationBytes.count,
            with: repeatElement(UInt8(0), count: 64)
        )
        let response: [AptosSimulatedTransaction] = try await performRead(
            path: "transactions/simulate",
            method: "POST",
            contentType: "application/x.aptos.signed_transaction+bcs",
            body: simulationBytes
        )
        guard response.count == 1,
              let transaction = response.first,
              let sender = AptosAddress.canonical(transaction.sender),
              let sequenceNumber = UInt64(transaction.sequenceNumber),
              let maximumGasAmount = UInt64(transaction.maximumGasAmount),
              let gasUnitPrice = UInt64(transaction.gasUnitPrice),
              let gasUsed = UInt64(transaction.gasUsed),
              gasUsed <= maximumGasAmount
        else {
            throw AptosProviderError.invalidResponse("simulation")
        }
        return AptosSimulationResult(
            sender: sender,
            sequenceNumber: sequenceNumber,
            maximumGasAmount: maximumGasAmount,
            gasUnitPrice: gasUnitPrice,
            gasUsed: gasUsed,
            succeeded: transaction.success,
            vmStatus: transaction.vmStatus
        )
    }

    private func request(
        baseURL: URL,
        path: String,
        query: [URLQueryItem] = [],
        method: String
    ) throws -> URLRequest {
        guard !path.contains("..") else {
            throw AptosProviderError.invalidConfiguration
        }
        let url = baseURL.appending(path: path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw AptosProviderError.invalidConfiguration }
        components.queryItems = query.isEmpty ? nil : query
        guard let finalURL = components.url else {
            throw AptosProviderError.invalidConfiguration
        }
        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func performRead<Response: Decodable & Sendable>(
        path: String,
        query: [URLQueryItem] = [],
        method: String,
        contentType: String? = nil,
        body: Data? = nil
    ) async throws -> Response {
        let operation = "\(method)_" + AdaptiveProviderIdentity
            .responseTypeOperation(Response.self)
        let serviceID = AdaptiveProviderIdentity.scopedServiceID(
            "aptos_rest_read",
            operation: operation
        )
        let attempts = try baseURLs.enumerated().map { index, baseURL in
            var request = try request(
                baseURL: baseURL,
                path: path,
                query: query,
                method: method
            )
            if let contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            request.httpBody = body
            let endpointRequest = request
            let endpoint = AdaptiveProviderEndpoint(
                serviceID: serviceID,
                endpointURL: baseURL,
                baselinePriority: index
            )
            return AdaptiveProviderAttempt<Response>(
                endpoint: endpoint,
                operation: { [session] in
                    try await Self.perform(endpointRequest, session: session)
                }
            )
        }
        return try await AdaptiveProviderRouter.shared.executeRead(
            serviceID: serviceID,
            attempts: attempts,
            timeoutSeconds: 4,
            overallTimeoutSeconds: 8,
            shouldFallback: Self.isReliabilityFailure
        )
    }

    private static func perform<Response: Decodable & Sendable>(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> Response {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw error }
        guard let http = response as? HTTPURLResponse else {
            throw AptosProviderError.invalidResponse("http")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AptosProviderError.http(
                status: http.statusCode,
                code: Self.providerCode(data)
            )
        }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw AptosProviderError.invalidResponse("decode") }
    }

    private static func isReliabilityFailure(_ error: Error) -> Bool {
        if ProviderReliabilityClassification.isRetryableTransport(error) {
            return true
        }
        guard let providerError = error as? AptosProviderError else {
            return error is DecodingError
        }
        switch providerError {
        case .invalidResponse:
            return true
        case let .http(status, _):
            return ProviderReliabilityClassification
                .isRetryableHTTPStatus(status)
        default:
            return false
        }
    }

    private static func providerCode(_ data: Data) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any]
        else { return "provider_error" }
        return publicCode(
            (object["error_code"] as? String)
                ?? (object["message"] as? String)
                ?? "provider_error"
        )
    }

    static func publicCode(_ value: String) -> String {
        let normalized = value.lowercased().map {
            $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_"
        }
        let joined = String(normalized).replacingOccurrences(
            of: "_+",
            with: "_",
            options: .regularExpression
        )
        return String(joined.prefix(96)).trimmingCharacters(
            in: CharacterSet(charactersIn: "_")
        )
    }
}

private struct AptosSubmittedTransaction: Decodable, Sendable {
    let type: String?
    let hash: String
}

private struct AptosSimulatedTransaction: Decodable, Sendable {
    let sender: String
    let sequenceNumber: String
    let maximumGasAmount: String
    let gasUnitPrice: String
    let gasUsed: String
    let success: Bool
    let vmStatus: String

    enum CodingKeys: String, CodingKey {
        case sender
        case sequenceNumber = "sequence_number"
        case maximumGasAmount = "max_gas_amount"
        case gasUnitPrice = "gas_unit_price"
        case gasUsed = "gas_used"
        case success
        case vmStatus = "vm_status"
    }
}
