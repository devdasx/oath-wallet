import Foundation

actor TronHistoryAPITransport {
    typealias RequestExecutor = @Sendable (URLRequest) async throws
        -> (Data, URLResponse)

    static let shared = TronHistoryAPITransport()

    private let tronGridBaseURL: URL
    private let tronScanBaseURL: URL
    private let timeoutSeconds: Double
    private let requestExecutor: RequestExecutor

    init(
        tronGridBaseURL: URL = URL(
            string: "https://api.trongrid.io"
        )!,
        tronScanBaseURL: URL = URL(
            string: "https://apilist.tronscanapi.com"
        )!,
        timeoutSeconds: Double = 7.5,
        requestExecutor: RequestExecutor? = nil
    ) {
        self.tronGridBaseURL = tronGridBaseURL
        self.tronScanBaseURL = tronScanBaseURL
        self.timeoutSeconds = timeoutSeconds
        if let requestExecutor {
            self.requestExecutor = requestExecutor
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeoutSeconds
            configuration.timeoutIntervalForResource = timeoutSeconds + 1
            let session = URLSession(configuration: configuration)
            self.requestExecutor = { request in
                try await session.data(for: request)
            }
        }
    }

    func nativeHistory(address: String) async throws
        -> [TronHistoryItem] {
        let serviceID = "provider-routing.tron-native-history"
        return try await executeRead(
            serviceID: serviceID,
            operations: [
                providerAttempt(
                    serviceID: serviceID,
                    baseURL: tronScanBaseURL,
                    priority: 0
                ) {
                    try await self.tronScanNativeHistory(
                        address: address
                    )
                },
                providerAttempt(
                    serviceID: serviceID,
                    baseURL: tronGridBaseURL,
                    priority: 1
                ) {
                    try await self.tronGridNativeHistory(
                        address: address
                    )
                }
            ]
        )
    }

    func tokenHistory(address: String) async throws
        -> [TronHistoryItem] {
        let serviceID = "provider-routing.tron-token-history"
        return try await executeRead(
            serviceID: serviceID,
            operations: [
                providerAttempt(
                    serviceID: serviceID,
                    baseURL: tronScanBaseURL,
                    priority: 0
                ) {
                    try await self.tronScanTokenHistory(
                        address: address
                    )
                },
                providerAttempt(
                    serviceID: serviceID,
                    baseURL: tronGridBaseURL,
                    priority: 1
                ) {
                    try await self.tronGridTokenHistory(
                        address: address
                    )
                }
            ]
        )
    }

    private func executeRead(
        serviceID: String,
        operations: [AdaptiveProviderAttempt<[TronHistoryItem]>]
    ) async throws -> [TronHistoryItem] {
        try await AdaptiveProviderRouter.shared.executeRead(
            serviceID: serviceID,
            attempts: operations,
            timeoutSeconds: timeoutSeconds,
            shouldFallback: Self.isReliabilityFailure
        )
    }

    private func providerAttempt(
        serviceID: String,
        baseURL: URL,
        priority: Int,
        operation: @escaping @Sendable () async throws
            -> [TronHistoryItem]
    ) -> AdaptiveProviderAttempt<[TronHistoryItem]> {
        AdaptiveProviderAttempt(
            endpoint: AdaptiveProviderEndpoint(
                serviceID: serviceID,
                endpointURL: baseURL,
                identityURL: AdaptiveProviderIdentity.originURL(
                    for: baseURL
                ),
                baselinePriority: priority
            ),
            operation: operation
        )
    }

    private func tronGridNativeHistory(
        address: String
    ) async throws -> [TronHistoryItem] {
        let result: HistoryPaginationResult<TronHistoryItem> =
            try await HistoryPaginator.collect(
                service: "TRON",
                stream: "trongrid_native_transfers",
                maximumReportedItems: 100
            ) { (fingerprint: String?) in
                var queryItems = Self.tronGridQueryItems
                if let fingerprint {
                    queryItems.append(
                        URLQueryItem(
                            name: "fingerprint",
                            value: fingerprint
                        )
                    )
                }
                let envelope: TronGridEnvelope<TronGridTransaction> =
                    try await self.get(
                        baseURL: self.tronGridBaseURL,
                        path: "v1/accounts/\(address)/transactions",
                        queryItems: queryItems
                    )
                guard envelope.success else {
                    throw TronHistoryError.unsuccessfulResponse
                }
                return HistoryPage(
                    items: TronHistoryMapper.nativeTransfers(
                        from: envelope.data
                    ),
                    nextCursor: Self.normalizedCursor(
                        envelope.meta?.fingerprint
                    ),
                    reportedItemCount: envelope.data.count
                )
            }
        return result.items
    }

    private func tronGridTokenHistory(
        address: String
    ) async throws -> [TronHistoryItem] {
        let result: HistoryPaginationResult<TronHistoryItem> =
            try await HistoryPaginator.collect(
                service: "TRON",
                stream: "trongrid_trc20_transfers",
                maximumReportedItems: 100
            ) { (fingerprint: String?) in
                var queryItems = Self.tronGridQueryItems
                if let fingerprint {
                    queryItems.append(
                        URLQueryItem(
                            name: "fingerprint",
                            value: fingerprint
                        )
                    )
                }
                let envelope: TronGridEnvelope<TronGridTokenTransfer> =
                    try await self.get(
                        baseURL: self.tronGridBaseURL,
                        path: "v1/accounts/\(address)/transactions/trc20",
                        queryItems: queryItems
                    )
                guard envelope.success else {
                    throw TronHistoryError.unsuccessfulResponse
                }
                return HistoryPage(
                    items: try TronHistoryMapper.tokenTransfers(
                        from: envelope.data
                    ),
                    nextCursor: Self.normalizedCursor(
                        envelope.meta?.fingerprint
                    ),
                    reportedItemCount: envelope.data.count
                )
            }
        return result.items
    }

    private func tronScanNativeHistory(
        address: String
    ) async throws -> [TronHistoryItem] {
        let limit = 50
        let result: HistoryPaginationResult<TronHistoryItem> =
            try await HistoryPaginator.collect(
                service: "TRON",
                stream: "tronscan_native_transfers",
                initialCursor: 0,
                maximumReportedItems: 100
            ) { (start: Int?) in
                let offset = start ?? 0
                let envelope: TronScanNativeHistoryEnvelope =
                    try await self.get(
                        baseURL: self.tronScanBaseURL,
                        path: "api/transfer/trx",
                        queryItems: [
                            URLQueryItem(
                                name: "address",
                                value: address
                            ),
                            URLQueryItem(
                                name: "start",
                                value: String(offset)
                            ),
                            URLQueryItem(
                                name: "limit",
                                value: String(limit)
                            ),
                            URLQueryItem(name: "direction", value: "0"),
                            URLQueryItem(name: "reverse", value: "true")
                        ]
                    )
                let count = envelope.data.count
                return HistoryPage(
                    items: TronScanHistoryMapper.nativeTransfers(
                        from: envelope.data
                    ),
                    nextCursor: count < limit ? nil : offset + count,
                    reportedItemCount: count
                )
            }
        return result.items
    }

    private func tronScanTokenHistory(
        address: String
    ) async throws -> [TronHistoryItem] {
        let limit = 50
        let result: HistoryPaginationResult<TronHistoryItem> =
            try await HistoryPaginator.collect(
                service: "TRON",
                stream: "tronscan_trc20_transfers",
                initialCursor: 0,
                maximumReportedItems: 100
            ) { (start: Int?) in
                let offset = start ?? 0
                let envelope: TronScanTokenHistoryEnvelope =
                    try await self.get(
                        baseURL: self.tronScanBaseURL,
                        path: "api/token_trc20/transfers",
                        queryItems: [
                            URLQueryItem(
                                name: "relatedAddress",
                                value: address
                            ),
                            URLQueryItem(
                                name: "start",
                                value: String(offset)
                            ),
                            URLQueryItem(
                                name: "limit",
                                value: String(limit)
                            )
                        ]
                    )
                let count = envelope.transfers.count
                let nextOffset = offset + count
                let hasMore = count == limit
                    && envelope.total.map { nextOffset < $0 } != false
                return HistoryPage(
                    items: try TronScanHistoryMapper.tokenTransfers(
                        from: envelope.transfers
                    ),
                    nextCursor: hasMore ? nextOffset : nil,
                    reportedItemCount: count
                )
            }
        return result.items
    }

    private func get<Result: Decodable & Sendable>(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem]
    ) async throws -> Result {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw AnkrAPIError.invalidResponse
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw AnkrAPIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await requestExecutor(request)
        try Self.validate(response, data: data)
        do {
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            throw AnkrAPIError.invalidResponse
        }
    }

    private nonisolated static let tronGridQueryItems = [
        // Pending transfers are user-visible activity and must not be hidden
        // behind block confirmation. The mapper already preserves the
        // provider's confirmed/failed state for presentation.
        URLQueryItem(name: "only_confirmed", value: "false"),
        URLQueryItem(name: "visible", value: "true"),
        URLQueryItem(name: "limit", value: "200"),
        URLQueryItem(name: "order_by", value: "block_timestamp,desc")
    ]

    private nonisolated static func normalizedCursor(
        _ rawValue: String?
    ) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value.isEmpty ? nil : value
    }

    private nonisolated static func validate(
        _ response: URLResponse,
        data: Data
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AnkrAPIError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            throw AnkrAPIError.httpFailure(
                statusCode: http.statusCode,
                message: providerMessage(from: data)
            )
        }
    }

    private nonisolated static func providerMessage(
        from data: Data
    ) -> String? {
        struct ErrorEnvelope: Decodable {
            let error: String?
            let message: String?
        }
        guard let envelope = try? JSONDecoder().decode(
            ErrorEnvelope.self,
            from: data
        ) else {
            return nil
        }
        let raw = envelope.error ?? envelope.message
        let value = raw?
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return String(value.prefix(500))
    }

    private nonisolated static func isReliabilityFailure(
        _ error: Error
    ) -> Bool {
        if ProviderReliabilityClassification.isRetryableTransport(error) {
            return true
        }
        if error is TronHistoryError
            || error is HistoryPaginationError
            || error is DecodingError {
            return true
        }
        guard let apiError = error as? AnkrAPIError else {
            return false
        }
        switch apiError {
        case let .httpFailure(statusCode, _):
            return ProviderReliabilityClassification
                .isRetryableHTTPStatus(statusCode)
                || statusCode == 400
        case .invalidResponse:
            return true
        default:
            return false
        }
    }
}
