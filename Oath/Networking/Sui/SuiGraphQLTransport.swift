import Foundation

struct SuiGraphQLTransport: Sendable {
    private let endpoints: [URL]
    private let router: AdaptiveProviderRouter
    private let executor:
        @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        router: AdaptiveProviderRouter = .shared,
        executor: @escaping @Sendable (URLRequest) async throws
            -> (Data, URLResponse) = SuiGraphQLTransport.defaultExecutor
    ) {
        endpoints = [SuiConstants.publicGraphQLURL]
        self.router = router
        self.executor = executor
    }

    init(
        endpoint: URL,
        router: AdaptiveProviderRouter = .shared,
        executor: @escaping @Sendable (URLRequest) async throws
            -> (Data, URLResponse) = SuiGraphQLTransport.defaultExecutor
    ) throws {
        guard endpoint.scheme == "https",
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.fragment == nil
        else {
            throw SuiProviderError.invalidConfiguration
        }
        self.endpoints = [endpoint]
        self.router = router
        self.executor = executor
    }

    func request<Response: Decodable & Sendable>(
        query: String,
        variables: [String: SuiGraphQLValue],
        as: Response.Type = Response.self
    ) async throws -> Response {
        try await perform(
            query: query,
            variables: variables,
            mode: .read,
            as: Response.self
        )
    }

    /// Signed Sui mutations are one-shot operations. A timeout or transport
    /// failure is ambiguous because the selected full node may have accepted
    /// the transaction, so this path must never retry or fail over.
    func submit<Response: Decodable & Sendable>(
        query: String,
        variables: [String: SuiGraphQLValue],
        as: Response.Type = Response.self
    ) async throws -> Response {
        try await perform(
            query: query,
            variables: variables,
            mode: .submission,
            as: Response.self
        )
    }

    private func perform<Response: Decodable & Sendable>(
        query: String,
        variables: [String: SuiGraphQLValue],
        mode: SuiGraphQLRequestMode,
        as: Response.Type
    ) async throws -> Response {
        let body = try JSONEncoder().encode(
            SuiGraphQLRequest(query: query, variables: variables)
        )
        let serviceID = AdaptiveProviderIdentity.scopedServiceID(
            mode == .read
                ? "sui_graphql_read" : "sui_graphql_submission",
            operation: AdaptiveProviderIdentity.responseTypeOperation(
                Response.self
            )
        )
        let attempts = endpoints.enumerated().map { priority, endpoint in
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(
                "Aperture-iOS-Sui/1.0",
                forHTTPHeaderField: "User-Agent"
            )
            request.httpBody = body
            let endpointRequest = request
            let healthEndpoint = AdaptiveProviderEndpoint(
                serviceID: serviceID,
                endpointURL: endpoint,
                baselinePriority: priority
            )
            return AdaptiveProviderAttempt<Response>(
                endpoint: healthEndpoint
            ) {
                let (data, response) = try await executor(endpointRequest)
                guard let http = response as? HTTPURLResponse else {
                    throw SuiProviderError.invalidResponse("not_http")
                }
                guard 200..<300 ~= http.statusCode else {
                    throw SuiProviderError.http(
                        status: http.statusCode,
                        code: Self.publicErrorCode(data)
                    )
                }
                let envelope: SuiGraphQLEnvelope<Response>
                do {
                    envelope = try JSONDecoder().decode(
                        SuiGraphQLEnvelope<Response>.self,
                        from: data
                    )
                } catch {
                    throw SuiProviderError.invalidResponse("decoding")
                }
                if let error = envelope.errors?.first {
                    throw SuiProviderError.graphQL(
                        Self.sanitizedCode(error.message)
                    )
                }
                guard let value = envelope.data else {
                    throw SuiProviderError.invalidResponse("missing_data")
                }
                return value
            }
        }
        switch mode {
        case .read:
            return try await router.executeRead(
                serviceID: serviceID,
                attempts: attempts,
                timeoutSeconds: 8,
                shouldFallback: Self.isReliabilityFailure
            )
        case .submission:
            return try await router.executeSubmission(
                serviceID: serviceID,
                attempts: attempts,
                timeoutSeconds: 8,
                isReliabilityFailure: Self.isReliabilityFailure
            )
        }
    }

    private static func defaultExecutor(
        _ request: URLRequest
    ) async throws -> (Data, URLResponse) {
        try await sharedSession.data(for: request)
    }

    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }()

    private static func publicErrorCode(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            return "invalid_body"
        }
        let candidate = dictionary["error"] as? String
            ?? dictionary["message"] as? String
            ?? "provider_error"
        return sanitizedCode(candidate)
    }

    private static func sanitizedCode(_ value: String) -> String {
        let allowed = value.lowercased().map {
            $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_"
        }
        let compact = String(allowed)
            .split(separator: "_")
            .prefix(8)
            .joined(separator: "_")
        return String(compact.prefix(120))
    }

    private static func isReliabilityFailure(_ error: Error) -> Bool {
        if ProviderReliabilityClassification.isRetryableTransport(error) {
            return true
        }
        guard let providerError = error as? SuiProviderError else {
            return false
        }
        switch providerError {
        case .invalidResponse:
            return true
        case let .http(status, _):
            return ProviderReliabilityClassification
                .isRetryableHTTPStatus(status)
        case let .graphQL(code):
            let normalized = code.lowercased()
            return normalized.contains("timeout")
                || normalized.contains("unavailable")
                || normalized.contains("overloaded")
                || normalized.contains("rate_limit")
                || normalized.contains("internal")
                || normalized.contains("service_busy")
        default:
            return false
        }
    }
}

private enum SuiGraphQLRequestMode: Sendable {
    case read
    case submission
}

enum SuiGraphQLValue: Encodable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private struct SuiGraphQLRequest: Encodable {
    let query: String
    let variables: [String: SuiGraphQLValue]
}

private struct SuiGraphQLEnvelope<Value: Decodable>: Decodable {
    let data: Value?
    let errors: [SuiGraphQLError]?
}

private struct SuiGraphQLError: Decodable {
    let message: String
}
