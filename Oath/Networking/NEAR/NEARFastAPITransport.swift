import Foundation

struct NEARFastAPIResponse: Sendable {
    let data: Data
    let statusCode: Int
}

struct NEARFastAPITransport: Sendable {
    typealias Executor = @Sendable (URLRequest) async throws
        -> (Data, URLResponse)

    private let executor: Executor

    init(session: URLSession? = nil) {
        let resolvedSession: URLSession
        if let session {
            resolvedSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 10
            resolvedSession = URLSession(configuration: configuration)
        }
        executor = { try await resolvedSession.data(for: $0) }
    }

    init(executor: @escaping Executor) {
        self.executor = executor
    }

    func response(
        for request: URLRequest,
        serviceID: String,
        acceptedStatusCodes: Set<Int> = []
    ) async throws -> NEARFastAPIResponse {
        guard let url = request.url else {
            throw NEARProviderError.invalidConfiguration
        }
        let endpoint = AdaptiveProviderEndpoint(
            serviceID: serviceID,
            endpointURL: url,
            identityURL: AdaptiveProviderIdentity.originURL(for: url),
            baselinePriority: 0
        )
        return try await AdaptiveProviderRouter.shared.executeRead(
            serviceID: serviceID,
            attempts: [
                AdaptiveProviderAttempt(endpoint: endpoint) {
                    let (data, response) = try await executor(request)
                    guard let http = response as? HTTPURLResponse else {
                        throw NEARProviderError.invalidResponse(
                            "fast_api_not_http"
                        )
                    }
                    guard 200..<300 ~= http.statusCode
                            || acceptedStatusCodes.contains(http.statusCode)
                    else {
                        throw NEARProviderError.http(
                            status: http.statusCode,
                            code: serviceID
                        )
                    }
                    return NEARFastAPIResponse(
                        data: data,
                        statusCode: http.statusCode
                    )
                }
            ],
            timeoutSeconds: 8,
            shouldFallback: Self.isReliabilityFailure
        )
    }

    private static func isReliabilityFailure(_ error: Error) -> Bool {
        if ProviderReliabilityClassification.isRetryableTransport(error) {
            return true
        }
        if case let NEARProviderError.http(status, _) = error {
            return ProviderReliabilityClassification
                .isRetryableHTTPStatus(status)
        }
        if case NEARProviderError.invalidResponse = error {
            return true
        }
        return false
    }
}
