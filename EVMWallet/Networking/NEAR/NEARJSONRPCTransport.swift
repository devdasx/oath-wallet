import Foundation

struct NEARJSONRPCTransport: Sendable {
    private struct RequestBody: Encodable {
        let jsonrpc = "2.0"
        let id = "aperture"
        let method: String
        let params: NEARJSONValue
    }

    private struct ResponseBody: Decodable {
        struct RPCError: Decodable {
            let code: Int
            let message: String?
            let data: NEARJSONValue?
        }
        let result: NEARJSONValue?
        let error: RPCError?
    }

    private let endpoints: [URL]
    private let router: AdaptiveProviderRouter
    private let executor:
        @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        endpoint: URL? = nil,
        endpoints: [URL]? = nil,
        router: AdaptiveProviderRouter = .shared,
        executor: @escaping @Sendable (URLRequest) async throws
            -> (Data, URLResponse) = NEARJSONRPCTransport.defaultExecutor
    ) throws {
        var resolved: [URL]
        if let endpoint {
            resolved = [endpoint]
        } else if let endpoints {
            resolved = endpoints
        } else {
            resolved = NEARConstants.publicJSONRPCEndpoints
            if let configured = try? AnkrConfiguration.runtime()
                .nearJSONRPCEndpoint {
                resolved.insert(configured, at: 0)
            }
        }
        var seenEndpoints = Set<String>()
        resolved = resolved.filter {
            seenEndpoints.insert($0.absoluteString).inserted
        }
        guard !resolved.isEmpty,
              resolved.allSatisfy({ endpoint in
                  endpoint.scheme == "https" && endpoint.host != nil
                      && endpoint.user == nil && endpoint.password == nil
                      && endpoint.query == nil && endpoint.fragment == nil
              })
        else { throw NEARProviderError.invalidConfiguration }
        self.endpoints = resolved
        self.router = router
        self.executor = executor
    }

    func request(
        method: String,
        parameters: NEARJSONValue
    ) async throws -> NEARJSONValue {
        let body = try JSONEncoder().encode(
            RequestBody(method: method, params: parameters)
        )
        let serviceID = AdaptiveProviderIdentity.scopedServiceID(
            Self.isSubmission(method)
                ? "near_json_rpc_submission" : "near_json_rpc_read",
            operation: Self.operationID(
                method: method,
                parameters: parameters
            )
        )
        let attempts = endpoints.enumerated().map { index, endpoint in
            let provider = AdaptiveProviderEndpoint(
                serviceID: serviceID,
                endpointURL: endpoint,
                baselinePriority: index
            )
            return AdaptiveProviderAttempt(endpoint: provider) {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue(
                    "application/json",
                    forHTTPHeaderField: "Accept"
                )
                request.setValue(
                    "application/json",
                    forHTTPHeaderField: "Content-Type"
                )
                request.setValue(
                    "Aperture-iOS-NEAR/1.0",
                    forHTTPHeaderField: "User-Agent"
                )
                request.httpBody = body
                return try await Self.perform(
                    request: request,
                    executor: executor
                )
            }
        }
        if Self.isSubmission(method) {
            return try await router.executeSubmission(
                serviceID: serviceID,
                attempts: attempts,
                timeoutSeconds: 12,
                isReliabilityFailure: Self.isReliabilityFailure
            )
        }
        // Fee quotes have a three-second presentation budget. NEAR's
        // archival endpoint can take more than three seconds for gas_price,
        // so bound each attempt and let the ranked reader reach a healthy
        // mainnet endpoint instead of allowing one slow endpoint to consume
        // the entire fee-quote deadline.
        let isGasPriceRead = method == "gas_price"
        return try await router.executeRead(
            serviceID: serviceID,
            attempts: attempts,
            timeoutSeconds: isGasPriceRead ? 1.25 : 8,
            overallTimeoutSeconds: isGasPriceRead ? 2.5 : nil,
            shouldFallback: Self.isReliabilityFailure
        )
    }

    private static func perform(
        request: URLRequest,
        executor: @escaping @Sendable (URLRequest) async throws
            -> (Data, URLResponse)
    ) async throws -> NEARJSONValue {
        let (data, response) = try await executor(request)
        guard let http = response as? HTTPURLResponse else {
            throw NEARProviderError.invalidResponse("not_http")
        }
        let envelope: ResponseBody?
        let decodingErrorCode: String?
        do {
            envelope = try JSONDecoder().decode(ResponseBody.self, from: data)
            decodingErrorCode = nil
        } catch {
            envelope = nil
            decodingErrorCode = Self.decodingErrorCode(error)
        }
        guard 200..<300 ~= http.statusCode else {
            if let error = envelope?.error {
                throw NEARProviderError.rpc(
                    code: error.code,
                    message: Self.rpcMessage(error)
                )
            }
            throw NEARProviderError.http(
                status: http.statusCode,
                code: Self.publicErrorCode(data)
            )
        }
        guard let envelope else {
            throw NEARProviderError.invalidResponse(
                decodingErrorCode ?? "decoding_unknown"
            )
        }
        if let error = envelope.error {
            throw NEARProviderError.rpc(
                code: error.code,
                message: Self.rpcMessage(error)
            )
        }
        guard let result = envelope.result else {
            throw NEARProviderError.invalidResponse("missing_result")
        }
        return result
    }

    private static func rpcMessage(
        _ error: ResponseBody.RPCError
    ) -> String {
        if error.data?.containsString("UNKNOWN_ACCOUNT") == true
            || error.data?.containsString(
                "does not exist while viewing"
            ) == true
            || error.data?.containsString("unknown account") == true {
            return "unknown_account"
        }
        let knownCodes = [
            "INVALID_TRANSACTION",
            "EXPIRED_TRANSACTION",
            "INVALID_SIGNATURE",
            "TIMEOUT_ERROR",
            "UNKNOWN_TRANSACTION"
        ]
        if let code = knownCodes.first(where: {
            error.data?.containsString($0) == true
        }) {
            return code.lowercased()
        }
        return error.message ?? "provider_error"
    }

    private static func isSubmission(_ method: String) -> Bool {
        switch method {
        case "broadcast_tx_commit", "broadcast_tx_async", "send_tx": true
        default: false
        }
    }

    private static func isReliabilityFailure(_ error: Error) -> Bool {
        if ProviderReliabilityClassification.isRetryableTransport(error) {
            return true
        }
        guard let providerError = error as? NEARProviderError else {
            return error is DecodingError
        }
        switch providerError {
        case .invalidResponse:
            return true
        case let .http(status, _):
            return ProviderReliabilityClassification
                .isRetryableHTTPStatus(status)
        case let .rpc(code, message):
            if message == "unknown_account" { return false }
            return ProviderReliabilityClassification
                .isRetryableJSONRPCError(
                    code: code,
                    message: message
                )
                || (-32099 ... -32000).contains(code)
        default:
            return false
        }
    }

    private static func operationID(
        method: String,
        parameters: NEARJSONValue
    ) -> String {
        guard method == "query", let object = parameters.objectValue else {
            return method
        }
        let requestType = object["request_type"]?.stringValue ?? "query"
        guard requestType == "call_function" else {
            return "\(method):\(requestType)"
        }
        let function = object["method_name"]?.stringValue ?? "function"
        return "\(method):\(requestType):\(function)"
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
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let error = root["error"] as? [String: Any]
        else { return "invalid_body" }
        let providerCode = error["code"] as? String
            ?? error["message"] as? String
            ?? "provider_error"
        return NEARErrorCode.sanitize(
            providerCode
        )
    }

    private static func decodingErrorCode(_ error: Error) -> String {
        let category: String
        let codingPath: [CodingKey]
        switch error {
        case let DecodingError.dataCorrupted(context):
            category = "data_corrupted"
            codingPath = context.codingPath
        case let DecodingError.keyNotFound(key, context):
            category = "missing_\(key.stringValue)"
            codingPath = context.codingPath
        case let DecodingError.typeMismatch(_, context):
            category = "type_mismatch"
            codingPath = context.codingPath
        case let DecodingError.valueNotFound(_, context):
            category = "value_missing"
            codingPath = context.codingPath
        default:
            category = "unknown"
            codingPath = []
        }
        let path = codingPath.map(\.stringValue).joined(separator: "_")
        return NEARErrorCode.sanitize(
            ["decoding", category, path]
                .filter { !$0.isEmpty }
                .joined(separator: "_")
        )
    }
}
