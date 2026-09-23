import Foundation

actor StellarHorizonTransport {
    private let readBaseURLs: [URL]
    private let submissionBaseURL: URL
    private let session: URLSession

    init(
        baseURL: URL = StellarConstants.horizonBaseURL,
        readFallbackBaseURLs: [URL]? = nil,
        session: URLSession? = nil
    ) {
        precondition(baseURL.scheme == "https")
        let configuredFallbacks = readFallbackBaseURLs
            ?? (baseURL == StellarConstants.horizonBaseURL
                ? [StellarConstants.horizonFallbackBaseURL] : [])
        let candidates = [baseURL] + configuredFallbacks
        precondition(candidates.allSatisfy { $0.scheme == "https" })
        self.readBaseURLs = candidates.reduce(into: []) { result, candidate in
            guard !result.contains(candidate) else { return }
            result.append(candidate)
        }
        self.submissionBaseURL = baseURL
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: configuration)
    }

    func account(_ address: String) async throws -> StellarHorizonAccount? {
        try await getOptional("accounts/\(address)", notFoundIsNil: true)
    }

    func payments(
        address: String,
        cursor: String?
    ) async throws -> StellarHorizonPaymentPage {
        var query = [
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(
                name: "limit",
                value: String(StellarConstants.historyPageSize)
            ),
            URLQueryItem(name: "join", value: "transactions")
        ]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await get("accounts/\(address)/payments", query: query)
    }

    func transaction(_ hash: String) async throws -> StellarHorizonTransaction {
        try await get("transactions/\(hash)")
    }

    func optionalTransaction(
        _ hash: String
    ) async throws -> StellarHorizonTransaction? {
        try await getOptional(
            "transactions/\(hash)",
            notFoundIsNil: true
        )
    }

    func feeStats() async throws -> StellarHorizonFeeStats {
        try await get("fee_stats")
    }

    func latestLedger() async throws -> StellarHorizonLedgerPage {
        try await get(
            "ledgers",
            query: [
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "limit", value: "1")
            ]
        )
    }

    func submit(xdr: String) async throws -> StellarHorizonSubmitResponse {
        guard let body = StellarHorizonFormEncoder.transactionBody(xdr: xdr)
        else {
            throw StellarProviderError.invalidResponse("transaction_xdr")
        }
        let endpoint = submissionBaseURL.appendingPathComponent("transactions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body
        let submissionRequest = request
        let serviceID = "stellar_horizon_submission"
        let healthEndpoint = AdaptiveProviderEndpoint(
            serviceID: serviceID,
            endpointURL: submissionBaseURL,
            baselinePriority: 0
        )
        let session = self.session
        let attempt = AdaptiveProviderAttempt<StellarHorizonSubmitResponse>(
            endpoint: healthEndpoint
        ) {
            let (data, response) = try await session.data(
                for: submissionRequest
            )
            return try Self.decode(data: data, response: response)
        }
        return try await AdaptiveProviderRouter.shared.executeSubmission(
            serviceID: serviceID,
            attempts: [attempt],
            timeoutSeconds: 12,
            isReliabilityFailure: Self.isReliabilityFailure
        )
    }

    private func getOptional<T: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        notFoundIsNil: Bool = false
    ) async throws -> T? {
        let serviceID = AdaptiveProviderIdentity.scopedServiceID(
            "stellar_horizon_read",
            operation: AdaptiveProviderIdentity.responseTypeOperation(T.self)
        )
        let session = self.session
        let attempts = try readBaseURLs.enumerated().map { priority, baseURL in
            var components = URLComponents(
                url: baseURL.appendingPathComponent(path),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = query.isEmpty ? nil : query
            guard let url = components?.url else {
                throw StellarProviderError.invalidResponse("endpoint")
            }
            let request = URLRequest(url: url)
            let healthEndpoint = AdaptiveProviderEndpoint(
                serviceID: serviceID,
                endpointURL: baseURL,
                baselinePriority: priority
            )
            return AdaptiveProviderAttempt<T?>(endpoint: healthEndpoint) {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw StellarProviderError.invalidResponse("transport")
                }
                if notFoundIsNil, http.statusCode == 404 { return nil }
                return try Self.decode(data: data, response: response)
            }
        }
        return try await AdaptiveProviderRouter.shared.executeRead(
            serviceID: serviceID,
            attempts: attempts,
            timeoutSeconds: 8,
            shouldFallback: Self.isReliabilityFailure
        )
    }

    private func get<T: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = []
    ) async throws -> T {
        guard let value: T = try await getOptional(path, query: query) else {
            throw StellarProviderError.invalidResponse("missing")
        }
        return value
    }

    private static func decode<T: Decodable>(
        data: Data,
        response: URLResponse
    ) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw StellarProviderError.invalidResponse("transport")
        }
        guard (200..<300).contains(http.statusCode) else {
            let problem = try? JSONDecoder().decode(
                StellarHorizonProblem.self,
                from: data
            )
            let codes = [
                problem?.extras?.resultCodes?.transaction,
                problem?.extras?.resultCodes?.operations?.joined(separator: "_")
            ].compactMap { $0 }.joined(separator: "_")
            throw StellarProviderError.http(
                status: http.statusCode,
                code: codes.isEmpty
                    ? (problem?.title ?? problem?.detail ?? "provider") : codes
            )
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw StellarProviderError.invalidResponse("decode") }
    }

    private static func isReliabilityFailure(_ error: Error) -> Bool {
        if ProviderReliabilityClassification.isRetryableTransport(error) {
            return true
        }
        guard let providerError = error as? StellarProviderError else {
            return false
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
}

enum StellarHorizonFormEncoder {
    private static let hexadecimal = Array("0123456789ABCDEF".utf8)

    static func transactionBody(xdr: String) -> Data? {
        guard let envelope = Data(base64Encoded: xdr), !envelope.isEmpty else {
            return nil
        }
        return Data("tx=\(encodedValue(xdr))".utf8)
    }

    private static func encodedValue(_ value: String) -> String {
        var result = [UInt8]()
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39,
                 0x2A, 0x2D, 0x2E, 0x5F:
                result.append(byte)
            case 0x20:
                result.append(0x2B)
            default:
                result.append(0x25)
                result.append(hexadecimal[Int(byte >> 4)])
                result.append(hexadecimal[Int(byte & 0x0F)])
            }
        }
        return String(decoding: result, as: UTF8.self)
    }
}
