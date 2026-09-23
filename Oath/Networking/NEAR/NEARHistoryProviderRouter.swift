import Foundation

struct NEARHistoryProviderRouter: Sendable {
    typealias Loader = @Sendable () async throws -> [NEARHistoryItem]

    private let router: AdaptiveProviderRouter
    private let serviceID: String
    private let timeoutSeconds: Double

    init(
        router: AdaptiveProviderRouter = .shared,
        serviceID: String = "near_complete_history",
        timeoutSeconds: Double = 10
    ) {
        self.router = router
        self.serviceID = serviceID
        self.timeoutSeconds = timeoutSeconds
    }

    func history(
        fastNEAR: @escaping Loader,
        nearBlocks: @escaping Loader
    ) async throws -> [NEARHistoryItem] {
        let fastEndpoint = AdaptiveProviderEndpoint(
            serviceID: serviceID,
            endpointURL: NEARConstants.fastNEARTxBase,
            baselinePriority: 0
        )
        let nearBlocksEndpoint = AdaptiveProviderEndpoint(
            serviceID: serviceID,
            endpointURL: NEARConstants.nearBlocksAPIBase,
            baselinePriority: 1
        )
        return try await router.executeRead(
            serviceID: serviceID,
            attempts: [
                AdaptiveProviderAttempt(
                    endpoint: fastEndpoint,
                    operation: fastNEAR
                ),
                AdaptiveProviderAttempt(
                    endpoint: nearBlocksEndpoint,
                    operation: nearBlocks
                )
            ],
            timeoutSeconds: timeoutSeconds,
            shouldFallback: Self.shouldFallback
        )
    }

    private static func shouldFallback(_ error: Error) -> Bool {
        if ProviderReliabilityClassification.isRetryableTransport(error) {
            return true
        }
        guard let error = error as? NEARProviderError else { return false }
        switch error {
        case let .http(status, _):
            return ProviderReliabilityClassification
                .isRetryableHTTPStatus(status)
        case .invalidResponse, .providerRejected, .missingConfiguration,
             .invalidConfiguration:
            return true
        case .invalidAddress, .invalidContract, .rpc,
             .insufficientFunds:
            return false
        }
    }
}
