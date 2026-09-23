import Foundation

actor TronAPITransport {
    typealias RequestExecutor = @Sendable (
        URLRequest
    ) async throws -> (Data, URLResponse)

    static let shared = TronAPITransport()

    private static let jsonRPCServiceID =
        "provider-routing.tron-sync-jsonrpc"

    private let configuredJSONRPCEndpoints: [URL]?
    private let configuredRESTBaseURLs: [URL]?
    private let requestExecutor: RequestExecutor
    private let timeoutSeconds: Double

    init(
        jsonRPCEndpoints: [URL]? = nil,
        restBaseURLs: [URL]? = nil,
        timeoutSeconds: Double = 8,
        requestExecutor: RequestExecutor? = nil
    ) {
        configuredJSONRPCEndpoints = jsonRPCEndpoints.map(Self.unique)
        configuredRESTBaseURLs = restBaseURLs.map(Self.unique)
        self.timeoutSeconds = timeoutSeconds
        if let requestExecutor {
            self.requestExecutor = requestExecutor
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 12
            let session = URLSession(configuration: configuration)
            self.requestExecutor = { request in
                try await session.data(for: request)
            }
        }
    }

    func rpc(
        method: String,
        params: [TronJSONValue]
    ) async throws -> String {
        let responses = try await rpcBatch([
            TronRPCRequest(method: method, params: params, id: 1)
        ])
        guard let response = responses.first else {
            throw AnkrAPIError.invalidResponse
        }
        if let error = response.error { throw error }
        guard let result = response.result else {
            throw AnkrAPIError.invalidResponse
        }
        return result
    }

    func rpcBatch(
        _ requests: [TronRPCRequest]
    ) async throws -> [TronRPCResponse] {
        guard !requests.isEmpty else { return [] }
        let envelope: RequestEnvelope = requests.count == 1
            ? .single(requests[0]) : .batch(requests)
        let body = try JSONEncoder().encode(envelope)
        let methods = Set(requests.map(\.method)).sorted().joined(separator: "_")
        let serviceID = AdaptiveProviderIdentity.scopedServiceID(
            Self.jsonRPCServiceID,
            operation: methods
        )
        let endpoints = configuredJSONRPCEndpoints
            ?? Self.defaultJSONRPCEndpoints()
        let attempts = endpoints.enumerated().map { priority, endpoint in
            let identity = AdaptiveProviderEndpoint(
                serviceID: serviceID,
                endpointURL: endpoint,
                baselinePriority: priority
            )
            return AdaptiveProviderAttempt(endpoint: identity) {
                try await Self.performRPCBatch(
                    endpoint: endpoint,
                    body: body,
                    isSingleRequest: requests.count == 1,
                    executor: self.requestExecutor
                )
            }
        }
        return try await AdaptiveProviderRouter.shared.executeRead(
            serviceID: serviceID,
            attempts: attempts,
            timeoutSeconds: timeoutSeconds,
            shouldFallback: Self.isReliabilityFailure
        )
    }

    func rest<Result: Decodable & Sendable>(
        path: String,
        body: [String: String]
    ) async throws -> Result {
        guard !path.isEmpty, !path.contains("..") else {
            throw AnkrAPIError.invalidResponse
        }
        let data = try JSONEncoder().encode(body)
        let endpoints = try Self.restEndpoints(
            path: path,
            configuredBaseURLs: configuredRESTBaseURLs
        )
        let serviceID = "provider-routing.tron-rest-" + path
            .replacingOccurrences(of: "/", with: "-")
        let attempts = endpoints.enumerated().map { priority, endpoint in
            let identity = AdaptiveProviderEndpoint(
                serviceID: serviceID,
                endpointURL: endpoint,
                baselinePriority: priority
            )
            return AdaptiveProviderAttempt<Result>(endpoint: identity) {
                try await Self.performREST(
                    endpoint: endpoint,
                    body: data,
                    executor: self.requestExecutor
                )
            }
        }
        return try await AdaptiveProviderRouter.shared.executeRead(
            serviceID: serviceID,
            attempts: attempts,
            timeoutSeconds: timeoutSeconds,
            shouldFallback: Self.isReliabilityFailure
        )
    }

    private enum RequestEnvelope: Encodable {
        case single(TronRPCRequest)
        case batch([TronRPCRequest])

        func encode(to encoder: Encoder) throws {
            switch self {
            case let .single(value): try value.encode(to: encoder)
            case let .batch(value): try value.encode(to: encoder)
            }
        }
    }

    private nonisolated static func performRPCBatch(
        endpoint: URL,
        body: Data,
        isSingleRequest: Bool,
        executor: RequestExecutor
    ) async throws -> [TronRPCResponse] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await executor(request)
        try validate(response, data: data, endpoint: endpoint)
        if isSingleRequest {
            return [try JSONDecoder().decode(TronRPCResponse.self, from: data)]
        }
        return try JSONDecoder().decode([TronRPCResponse].self, from: data)
    }

    private nonisolated static func performREST<Result: Decodable & Sendable>(
        endpoint: URL,
        body: Data,
        executor: RequestExecutor
    ) async throws -> Result {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await executor(request)
        try validate(response, data: data, endpoint: endpoint)
        return try JSONDecoder().decode(Result.self, from: data)
    }

    private nonisolated static func defaultJSONRPCEndpoints() -> [URL] {
        var endpoints: [URL] = []
        if let configuration = try? AnkrConfiguration.runtime() {
            endpoints.append(configuration.tronJSONRPCEndpoint)
        }
        endpoints.append(URL(string: "https://api.trongrid.io/jsonrpc")!)
        return unique(endpoints)
    }

    private nonisolated static func restEndpoints(
        path: String,
        configuredBaseURLs: [URL]?
    ) throws -> [URL] {
        if let configuredBaseURLs {
            return configuredBaseURLs.map {
                $0.appending(path: path, directoryHint: .notDirectory)
            }
        }
        var endpoints: [URL] = []
        if let configuration = try? AnkrConfiguration.runtime(),
           let endpoint = try? configuration.tronRESTEndpoint(path: path) {
            endpoints.append(endpoint)
        }
        endpoints.append(
            URL(string: "https://api.trongrid.io")!
                .appending(path: path, directoryHint: .notDirectory)
        )
        return unique(endpoints)
    }

    private nonisolated static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func validate(
        _ response: URLResponse,
        data: Data,
        endpoint: URL
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AnkrAPIError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            throw AnkrAPIError.httpFailure(
                statusCode: http.statusCode,
                message: providerMessage(
                    from: data,
                    endpoint: endpoint
                )
            )
        }
    }

    private static func providerMessage(
        from data: Data,
        endpoint: URL
    ) -> String? {
        guard let envelope = try? JSONDecoder().decode(
            AnkrHTTPErrorResponse.self,
            from: data
        ) else {
            return tronGridProviderMessage(from: data)
        }
        let rawValue = envelope.error?.message
            ?? envelope.error?.code
            ?? envelope.message
        guard var value = rawValue?
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        value = value.replacingOccurrences(
            of: endpoint.absoluteString,
            with: "<endpoint>"
        )
        for component in endpoint.pathComponents where
            component.count >= 32
                && component.unicodeScalars.allSatisfy({
                    CharacterSet.alphanumerics.contains($0)
                }) {
            value = value.replacingOccurrences(
                of: component,
                with: "<credential>"
            )
        }
        return String(value.prefix(500))
    }

    private static func tronGridProviderMessage(
        from data: Data
    ) -> String? {
        struct ErrorEnvelope: Decodable {
            let error: String?
        }
        guard
            let envelope = try? JSONDecoder().decode(
                ErrorEnvelope.self,
                from: data
            ),
            let rawValue = envelope.error
        else {
            return nil
        }
        let value = rawValue
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.prefix(500))
    }

    private nonisolated static func isReliabilityFailure(
        _ error: Error
    ) -> Bool {
        if ProviderReliabilityClassification.isRetryableTransport(error) {
            return true
        }
        if let apiError = error as? AnkrAPIError {
            switch apiError {
            case let .httpFailure(statusCode, _):
                return ProviderReliabilityClassification
                    .isRetryableHTTPStatus(statusCode)
            case .invalidResponse:
                return true
            default:
                return false
            }
        }
        return error is DecodingError
    }

}
