import Foundation

actor SolanaRPCTransport {
    typealias RequestExecutor = @Sendable (
        URLRequest
    ) async throws -> (Data, URLResponse)

    static let shared = SolanaRPCTransport()

    private static let serviceID = "provider-routing.solana-sync-jsonrpc"

    private let configuredEndpoints: [URL]?
    private let batchReader: SolanaRPCBatchReader
    private let timeoutSeconds: Double

    init(
        endpoints: [URL]? = nil,
        timeoutSeconds: Double = 8,
        requestExecutor: RequestExecutor? = nil
    ) {
        configuredEndpoints = endpoints.map(Self.unique)
        self.timeoutSeconds = timeoutSeconds
        let executor: RequestExecutor
        if let requestExecutor {
            executor = requestExecutor
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 20
            let session = URLSession(configuration: configuration)
            executor = { request in
                try await session.data(for: request)
            }
        }
        batchReader = SolanaRPCBatchReader(executor: executor)
    }

    func batch(
        _ requests: [SolanaRPCRequest]
    ) async throws -> [SolanaRPCResponse] {
        try await executeBatch(requests, usesHedgedRead: false)
    }

    func batchBalance(
        _ requests: [SolanaRPCRequest]
    ) async throws -> [SolanaRPCResponse] {
        try await executeBatch(requests, usesHedgedRead: true)
    }

    private func executeBatch(
        _ requests: [SolanaRPCRequest],
        usesHedgedRead: Bool
    ) async throws -> [SolanaRPCResponse] {
        guard !requests.isEmpty else { return [] }
        let methods = Set(requests.map(\.method)).sorted().joined(separator: "_")
        let serviceID = AdaptiveProviderIdentity.scopedServiceID(
            Self.serviceID,
            operation: methods
        )
        let endpoints = configuredEndpoints ?? Self.defaultEndpoints()
        let accumulator = SolanaRPCReadAccumulator(requests: requests)
        let attempts = endpoints.enumerated().map { priority, endpoint in
            let identity = AdaptiveProviderEndpoint(
                serviceID: serviceID,
                endpointURL: endpoint,
                baselinePriority: priority
            )
            return AdaptiveProviderAttempt(endpoint: identity) {
                let pending = await accumulator.pending()
                let responses = try await self.batchReader.read(endpoint: endpoint, requests: pending) {
                    await accumulator.record($0)
                }
                return try await accumulator.accept(responses)
            }
        }
        if usesHedgedRead {
            return try await AdaptiveProviderRouter.shared.executeHedgedRead(
                serviceID: serviceID,
                attempts: attempts,
                timeoutSeconds: timeoutSeconds,
                maximumConcurrentAttempts: min(2, attempts.count),
                shouldFallback: Self.shouldFallback
            )
        }
        return try await AdaptiveProviderRouter.shared.executeRead(
            serviceID: serviceID,
            attempts: attempts,
            timeoutSeconds: timeoutSeconds,
            shouldFallback: Self.shouldFallback
        )
    }

    func call(
        method: String,
        params: [SolanaJSONValue]
    ) async throws -> SolanaJSONValue {
        let responses = try await batch([
            SolanaRPCRequest(method: method, params: params, id: 1)
        ])
        guard let result = responses.first?.result else {
            throw SolanaProviderError.malformedResponse(method: method)
        }
        return result
    }

    func transactionStatus(signature: String) async throws -> SendTransactionNetworkStatus {
        let request = SolanaRPCRequest(method: "getSignatureStatuses", params: [
            .array([.string(signature)]),
            .object(["searchTransactionHistory": .bool(true)])
        ], id: 1)
        let endpoints = configuredEndpoints ?? Self.defaultEndpoints()
        let attempts = endpoints.enumerated().map { priority, endpoint in
            AdaptiveProviderAttempt<SendTransactionNetworkStatus>(
                endpoint: AdaptiveProviderEndpoint(
                    serviceID: "provider-routing.solana-signature-status", endpointURL: endpoint,
                    baselinePriority: priority
                )
            ) { [batchReader] in
                let responses = try await batchReader.read(endpoint: endpoint, requests: [request])
                if let error = responses.first?.error {
                    throw AnkrAPIError.rpcFailure(code: error.code, message: error.message)
                }
                guard let response = responses.first, response.id == request.id,
                      let result = response.result else {
                    throw SolanaProviderError.malformedResponse(method: request.method)
                }
                return try SolanaTransactionStatusProvider.status(from: result)
            }
        }
        return try await SendStatusReadResolver.resolve(attempts: attempts, timeoutSeconds: timeoutSeconds)
    }

    private nonisolated static func shouldFallback(_ error: Error) -> Bool {
        if SolanaRPCBatchReader.isSizeError(error) { return true }
        if ProviderReliabilityClassification.isRetryableTransport(error) {
            return true
        }
        if let error = error as? AnkrAPIError {
            switch error {
            case let .httpFailure(statusCode, _):
                return ProviderReliabilityClassification
                    .isRetryableHTTPStatus(statusCode)
            case let .rpcFailure(code, message):
                if ProviderReliabilityClassification
                    .isRetryableJSONRPCError(
                        code: code,
                        message: message
                    ) {
                    return true
                }
                // Public Solana nodes sometimes encode endpoint policy/rate
                // blocking as Invalid params. Fail over only for that exact
                // provider condition; genuine caller parameter errors remain
                // final and are never hidden by another endpoint.
                return code == -32602
                    && message.localizedCaseInsensitiveContains(
                        "request blocked"
                    )
            case .invalidResponse:
                return true
            default:
                return false
            }
        }
        return error is DecodingError
    }

    private nonisolated static func defaultEndpoints() -> [URL] {
        var endpoints: [URL] = []
        if let configuration = try? AnkrConfiguration.runtime(),
           let configured = try? configuration.solanaJSONRPCEndpoint {
            endpoints.append(configured)
        }
        endpoints.append(
            URL(string: "https://solana-rpc.publicnode.com")!
        )
        endpoints.append(
            URL(string: "https://api.mainnet-beta.solana.com")!
        )
        return unique(endpoints)
    }

    private nonisolated static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

}

/// Keep authoritative siblings when a fallback only needs to recover failed IDs.
private actor SolanaRPCReadAccumulator {
    private let requests: [SolanaRPCRequest]
    private var values: [Int: SolanaRPCResponse] = [:]

    init(requests: [SolanaRPCRequest]) { self.requests = requests }

    func pending() -> [SolanaRPCRequest] { requests.filter { values[$0.id] == nil } }

    func record(_ responses: [SolanaRPCResponse]) {
        for response in responses where response.error == nil {
            if let id = response.id, values[id] == nil { values[id] = response }
        }
    }

    func accept(_ responses: [SolanaRPCResponse]) throws -> [SolanaRPCResponse] {
        record(responses)
        if values.count == requests.count { return requests.compactMap { values[$0.id] } }
        if let error = responses.compactMap(\.error).first {
            throw AnkrAPIError.rpcFailure(code: error.code, message: error.message)
        }
        throw AnkrAPIError.invalidResponse
    }
}
