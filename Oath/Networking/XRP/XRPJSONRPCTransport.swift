import Foundation

struct XRPJSONRPCTransport: Sendable {
    private struct RequestBody: Encodable {
        let jsonrpc = "2.0"
        let id = 1
        let method: String
        let params: [XRPJSONValue]
    }

    private struct ResponseBody: Decodable {
        struct RPCError: Decodable {
            let code: Int
            let message: String
        }

        let result: XRPJSONValue?
        let error: RPCError?
    }

    private let endpoints: [URL]
    private let router: AdaptiveProviderRouter
    private let executor:
        @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        endpoint: URL? = nil,
        fallbackEndpoints: [URL]? = nil,
        router: AdaptiveProviderRouter = .shared,
        executor: @escaping @Sendable (URLRequest) async throws
            -> (Data, URLResponse) = XRPJSONRPCTransport.defaultExecutor
    ) throws {
        let resolved: URL
        if let endpoint {
            resolved = endpoint
        } else {
            do {
                resolved = try AnkrConfiguration.runtime()
                    .xrpJSONRPCEndpoint
            } catch AnkrAPIError.missingConfiguration {
                throw XRPProviderError.missingConfiguration
            } catch {
                throw XRPProviderError.invalidConfiguration
            }
        }
        let configuredFallbacks = fallbackEndpoints
            ?? (endpoint == nil ? XRPConstants.publicJSONRPCReadURLs : [])
        let candidates = [resolved] + configuredFallbacks
        for candidate in candidates {
            guard candidate.scheme == "https",
                  candidate.host != nil,
                  candidate.user == nil,
                  candidate.password == nil,
                  candidate.query == nil,
                  candidate.fragment == nil
            else {
                throw XRPProviderError.invalidConfiguration
            }
        }
        self.endpoints = candidates.reduce(into: []) { result, candidate in
            guard !result.contains(candidate) else { return }
            result.append(candidate)
        }
        self.router = router
        self.executor = executor
    }

    func request(
        method: String,
        parameters: [String: XRPJSONValue]
    ) async throws -> [String: XRPJSONValue] {
        let body = try JSONEncoder().encode(
            RequestBody(
                method: method,
                params: [.object(parameters)]
            )
        )
        let serviceID = AdaptiveProviderIdentity.scopedServiceID(
            method == "submit"
                ? "xrp_jsonrpc_submission" : "xrp_jsonrpc_read",
            operation: method
        )
        let attempts = endpoints.enumerated().map { priority, endpoint in
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
            request.setValue(
                "Aperture-iOS-XRP/1.0",
                forHTTPHeaderField: "User-Agent"
            )
            request.httpBody = body
            let endpointRequest = request
            let healthEndpoint = AdaptiveProviderEndpoint(
                serviceID: serviceID,
                endpointURL: endpoint,
                baselinePriority: priority
            )
            return AdaptiveProviderAttempt<[String: XRPJSONValue]>(
                endpoint: healthEndpoint
            ) {
                let (data, response) = try await executor(endpointRequest)
                return try Self.decode(data: data, response: response)
            }
        }
        if method == "submit" {
            return try await router.executeSubmission(
                serviceID: serviceID,
                attempts: attempts,
                timeoutSeconds: 12,
                isReliabilityFailure: Self.isReliabilityFailure
            )
        }
        return try await router.executeRead(
            serviceID: serviceID,
            attempts: attempts,
            timeoutSeconds: 8,
            shouldFallback: Self.isReliabilityFailure
        )
    }

    private static func defaultExecutor(
        _ request: URLRequest
    ) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        return URLSession(configuration: configuration)
    }()

    private static func publicErrorCode(_ data: Data) -> String {
        guard let decoded = try? JSONDecoder().decode(
            ResponseBody.self,
            from: data
        ) else {
            return "invalid_body"
        }
        return XRPErrorCode.sanitize(
            decoded.error?.message ?? "provider_error"
        )
    }

    private static func decode(
        data: Data,
        response: URLResponse
    ) throws -> [String: XRPJSONValue] {
        guard let http = response as? HTTPURLResponse else {
            throw XRPProviderError.invalidResponse("not_http")
        }
        guard 200..<300 ~= http.statusCode else {
            throw XRPProviderError.http(
                status: http.statusCode,
                code: publicErrorCode(data)
            )
        }
        let envelope: ResponseBody
        do {
            envelope = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw XRPProviderError.invalidResponse("decoding")
        }
        if let error = envelope.error {
            throw XRPProviderError.rpc(
                code: error.code,
                message: error.message
            )
        }
        guard let result = envelope.result?.objectValue else {
            throw XRPProviderError.invalidResponse("missing_result")
        }
        if result["status"]?.stringValue == "error" {
            let code = result["error"]?.stringValue ?? "provider_error"
            if code == "actNotFound" {
                throw XRPProviderError.providerRejected("account_not_found")
            }
            throw XRPProviderError.providerRejected(
                XRPErrorCode.sanitize(code)
            )
        }
        return result
    }

    private static func isReliabilityFailure(_ error: Error) -> Bool {
        if ProviderReliabilityClassification.isRetryableTransport(error) {
            return true
        }
        guard let providerError = error as? XRPProviderError else {
            return false
        }
        switch providerError {
        case .invalidResponse:
            return true
        case let .http(status, _):
            return ProviderReliabilityClassification
                .isRetryableHTTPStatus(status)
        case let .rpc(code, message):
            return ProviderReliabilityClassification
                .isRetryableJSONRPCError(
                    code: code,
                    message: message
                )
                || (-32099 ... -32000).contains(code)
        case let .providerRejected(code):
            return XRPSubmissionErrorClassifier
                .isReliabilityRejection(code)
        default:
            return false
        }
    }
}
