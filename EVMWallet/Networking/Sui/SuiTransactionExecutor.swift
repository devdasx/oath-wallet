import Foundation

struct SuiTransactionExecutor: Sendable {
    static let executionPath = "sui.rpc.v2.TransactionExecutionService/ExecuteTransaction"
    static let mainnetChainIdentifier = "4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S"
    private let endpoints: [URL]
    private let executor: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let router: AdaptiveProviderRouter

    init(
        endpoints: [URL]? = nil,
        router: AdaptiveProviderRouter = .shared,
        executor: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = defaultExecutor
    ) {
        var defaults = [
            URL(string: "https://fullnode.mainnet.sui.io")!,
            URL(string: "https://sui-mainnet.nodeinfra.com")!
        ]
        if let proxy = try? AnkrConfiguration.runtime().suiGRPCEndpoint {
            defaults.append(proxy)
        }
        self.endpoints = endpoints ?? defaults
        self.executor = executor
        self.router = router
    }

    func execute(transaction: String, signature: String) async throws -> String {
        let payload = try SuiRPCWire.executionRequest(transaction: transaction, signature: signature)
        let service = "sui_grpc_execution_v2"
        let candidates = endpoints.enumerated().map {
            AdaptiveProviderEndpoint(serviceID: service, endpointURL: $0.element, baselinePriority: $0.offset)
        }
        let ranked = await router.ordered(candidates, allowExploration: false)
        var lastError: Error = SuiProviderError.invalidConfiguration
        for candidate in ranked {
            try Task.checkCancellation()
            guard let index = candidates.firstIndex(of: candidate) else { continue }
            let endpoint = endpoints[index]
            guard endpoint.scheme == "https", endpoint.host != nil,
                  endpoint.user == nil, endpoint.password == nil,
                  endpoint.query == nil, endpoint.fragment == nil else {
                throw SuiProviderError.invalidConfiguration
            }
            // Read-only capability/mainnet check before exposing a signed payload.
            do {
                let info = try await call(endpoint, path: "sui.rpc.v2.LedgerService/GetServiceInfo", payload: Data())
                guard try SuiRPCWire.text(1, in: info) == Self.mainnetChainIdentifier,
                      try SuiRPCWire.text(2, in: info) == "mainnet" else {
                    throw SuiProviderError.invalidResponse("wrong_chain")
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                lastError = error
                continue // Nothing was submitted to this endpoint.
            }
            do {
                return try await router.executeSubmission(
                    serviceID: service,
                    attempts: [AdaptiveProviderAttempt(endpoint: candidate) {
                        let response = try await call(endpoint, path: Self.executionPath, payload: payload)
                        return try SuiRPCWire.executionDigest(response)
                    }],
                    timeoutSeconds: 30,
                    isReliabilityFailure: { _ in true }
                )
            } catch {
                guard Self.isDefinitiveAccessDenial(error) else { throw error }
                // Only an explicit gateway denial permits sequential failover.
                // Every attempt uses exactly the same bytes/signature. No re-signing.
                lastError = error
            }
        }
        throw SuiProviderError.submissionUnavailable(Self.diagnosticCode(lastError))
    }

    static func isDefinitiveAccessDenial(_ error: Error) -> Bool {
        guard let error = error as? SuiProviderError else { return false }
        switch error {
        case let .http(status, _): return [401, 403, 404, 405, 429].contains(status)
        case let .grpc(status): return [7, 12, 16].contains(status)
        default: return false
        }
    }

    private func call(_ endpoint: URL, path: String, payload: Data) async throws -> Data {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = path == Self.executionPath ? 30 : 8
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        request.setValue("Aperture-iOS-Sui/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = SuiRPCWire.frame(payload)
        let (data, response) = try await executor(request)
        guard let http = response as? HTTPURLResponse else {
            throw SuiProviderError.invalidResponse("not_http")
        }
        guard 200..<300 ~= http.statusCode else {
            throw SuiProviderError.http(status: http.statusCode, code: "grpc_gateway")
        }
        return try SuiRPCWire.response(data, http: http)
    }

    private static func diagnosticCode(_ error: Error) -> String {
        (error as? SuiProviderError)?.diagnosticDescription
            ?? SendTransactionSubmissionError.sanitizedErrorType(error)
    }

    private static func defaultExecutor(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 35
        return URLSession(configuration: configuration, delegate: SuiSubmissionRedirectPolicy(), delegateQueue: nil)
    }()
}

private final class SuiSubmissionRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
