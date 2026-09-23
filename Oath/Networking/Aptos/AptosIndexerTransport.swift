import Foundation

actor AptosIndexerTransport {
    private struct Envelope<Response: Decodable>: Decodable {
        struct GraphQLError: Decodable { let message: String }
        let data: Response?
        let errors: [GraphQLError]?
    }

    private struct RequestBody: Encodable {
        let query: String
        let variables: [String: AptosGraphQLValue]
    }

    private let endpoints: [URL]
    private let session: URLSession
    private let router: AdaptiveProviderRouter

    init(
        endpoint: URL? = nil,
        session: URLSession? = nil,
        router: AdaptiveProviderRouter = .shared
    ) {
        self.endpoints = endpoint.map { [$0] } ?? [
            AptosConstants.defaultIndexerURL,
            AptosConstants.fallbackIndexerURL
        ]
        self.router = router
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

    func request<Response: Decodable & Sendable>(
        query: String,
        variables: [String: AptosGraphQLValue]
    ) async throws -> Response {
        let body = try JSONEncoder().encode(
            RequestBody(query: query, variables: variables)
        )
        let serviceID = AdaptiveProviderIdentity.scopedServiceID(
            "aptos_indexer_read",
            operation: AdaptiveProviderIdentity.responseTypeOperation(
                Response.self
            )
        )
        let attempts = endpoints.enumerated().map { index, endpoint in
            let provider = AdaptiveProviderEndpoint(
                serviceID: serviceID,
                endpointURL: endpoint,
                baselinePriority: index
            )
            return AdaptiveProviderAttempt<Response>(
                endpoint: provider,
                operation: { [session] in
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
                    request.httpBody = body
                    return try await Self.perform(request, session: session)
                }
            )
        }
        return try await router.executeRead(
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
            throw AptosProviderError.invalidResponse("indexer_http")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AptosProviderError.http(
                status: http.statusCode,
                code: "indexer"
            )
        }
        let envelope: Envelope<Response>
        do { envelope = try JSONDecoder().decode(Envelope<Response>.self, from: data) }
        catch { throw AptosProviderError.invalidResponse("indexer_decode") }
        if let message = envelope.errors?.first?.message {
            throw AptosProviderError.indexer(
                AptosRESTTransport.publicCode(message)
            )
        }
        guard let result = envelope.data else {
            throw AptosProviderError.invalidResponse("indexer_data")
        }
        return result
    }

    private static func isReliabilityFailure(_ error: Error) -> Bool {
        if ProviderReliabilityClassification.isRetryableTransport(error) {
            return true
        }
        guard let providerError = error as? AptosProviderError else {
            return false
        }
        switch providerError {
        case let .http(status, _):
            return ProviderReliabilityClassification
                .isRetryableHTTPStatus(status)
        case let .indexer(code), let .invalidResponse(code):
            let normalized = code.lowercased()
            return normalized.contains("timeout")
                || normalized.contains("timed_out")
                || normalized.contains("unavailable")
                || normalized.contains("overloaded")
                || normalized.contains("rate_limit")
                || normalized.contains("internal")
                || normalized.contains("decode")
        default:
            return false
        }
    }
}

enum AptosGraphQLValue: Encodable, Sendable {
    case string(String)
    case integer(Int)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        }
    }
}
