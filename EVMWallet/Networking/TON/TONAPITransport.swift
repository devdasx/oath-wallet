import Foundation

struct TONAPITransport: Sendable {
    static let shared = try? TONAPITransport.configured()

    private static let publicReadBaseURL = URL(
        string: "https://tonapi.io/v2"
    )!

    private static let emulationURL = URL(
        string: "https://tonapi.io/v2/wallet/emulate"
    )!
    private static let broadcastURL = URL(
        string: "https://toncenter.com/api/v2/sendBocReturnHash"
    )!

    private let baseURL: URL
    private let directReadBaseURL: URL
    private let executor:
        @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let router: AdaptiveProviderRouter

    init(
        baseURL: URL,
        directReadBaseURL: URL = Self.publicReadBaseURL,
        router: AdaptiveProviderRouter = .shared,
        executor: @escaping @Sendable (URLRequest) async throws
            -> (Data, URLResponse)
    ) throws {
        guard Self.isValidBaseURL(baseURL),
              Self.isValidBaseURL(directReadBaseURL)
        else {
            throw TONProviderError.invalidConfiguration
        }
        self.baseURL = baseURL
        self.directReadBaseURL = directReadBaseURL
        self.router = router
        self.executor = executor
    }

    static func configured() throws -> TONAPITransport {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "NotificationServiceBaseURL"
        ) as? String,
              !value.isEmpty,
              !value.contains("$("),
              let url = URL(string: value)
        else {
            throw TONProviderError.missingConfiguration
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration)
        return try TONAPITransport(
            baseURL: url,
            executor: { try await session.data(for: $0) }
        )
    }

    func request<Result: Decodable & Sendable>(
        path: String,
        body: [String: TONAPIRequestValue],
        as: Result.Type = Result.self
    ) async throws -> Result {
        let endpoint = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("provider")
            .appendingPathComponent("ton")
            .appendingPathComponent(path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let providerRequest = request
        let serviceID = "ton_read_\(path)"
        let proxyHealth = AdaptiveProviderEndpoint(
            serviceID: serviceID,
            endpointURL: endpoint,
            baselinePriority: 0
        )
        let proxyAttempt = AdaptiveProviderAttempt<Result>(
            endpoint: proxyHealth
        ) {
            let (data, response) = try await executor(providerRequest)
            guard let http = response as? HTTPURLResponse else {
                throw TONProviderError.invalidResponse("not_http")
            }
            guard 200..<300 ~= http.statusCode else {
                throw TONProviderError.server(
                    status: http.statusCode,
                    code: Self.errorCode(data)
                )
            }
            do {
                return try JSONDecoder().decode(Result.self, from: data)
            } catch {
                throw TONProviderError.invalidResponse("decoding")
            }
        }
        let directIdentity = directReadBaseURL
            .appendingPathComponent(path)
        let directHealth = AdaptiveProviderEndpoint(
            serviceID: serviceID,
            endpointURL: directIdentity,
            baselinePriority: 1
        )
        let directAttempt = AdaptiveProviderAttempt<Result>(
            endpoint: directHealth
        ) {
            let data = try await directResponseData(
                path: path,
                body: body
            )
            do {
                return try JSONDecoder().decode(Result.self, from: data)
            } catch {
                throw TONProviderError.invalidResponse(
                    "direct_decoding"
                )
            }
        }
        return try await router.executeRead(
            serviceID: serviceID,
            attempts: [proxyAttempt, directAttempt],
            timeoutSeconds: 8,
            shouldFallback: Self.isReliabilityFailure
        )
    }

    private func directResponseData(
        path: String,
        body: [String: TONAPIRequestValue]
    ) async throws -> Data {
        if path == "snapshot" {
            return try await directSnapshotData(body: body)
        }
        let request = try directReadRequest(path: path, body: body)
        return try await directData(for: request, component: path)
    }

    private func directSnapshotData(
        body: [String: TONAPIRequestValue]
    ) async throws -> Data {
        guard let address = body["address"]?.stringValue else {
            throw TONProviderError.providerRejected(
                "direct_snapshot_address"
            )
        }
        let accountBody = ["address": TONAPIRequestValue.string(address)]
        let jettonsBody: [String: TONAPIRequestValue] = [
            "address": .string(address),
            "limit": .integer(1_000),
            "offset": .integer(0)
        ]
        let eventsBody: [String: TONAPIRequestValue] = [
            "address": .string(address),
            "limit": .integer(100)
        ]

        async let accountData = directResponseData(
            path: "account",
            body: accountBody
        )
        async let jettons = directOptionalComponent(
            path: "jettons",
            body: jettonsBody,
            fallbackJSON: #"{"balances":[]}"#
        )
        async let events = directOptionalComponent(
            path: "events",
            body: eventsBody,
            fallbackJSON: #"{"events":[],"next_from":null}"#
        )
        async let rates = directOptionalComponent(
            path: "rates",
            body: [:],
            fallbackJSON: #"{"rates":{}}"#
        )

        let account = try Self.jsonObject(try await accountData)
        let jettonResult = try await jettons
        let eventResult = try await events
        let rateResult = try await rates
        let failures = [jettonResult, eventResult, rateResult]
            .compactMap(\.failureCode)
        let value: [String: Any] = [
            "account": account,
            "jettons": try Self.jsonObject(jettonResult.data),
            "events": try Self.jsonObject(eventResult.data),
            "rates": try Self.jsonObject(rateResult.data),
            "sources": [
                "jettonsComplete": jettonResult.complete,
                "eventsComplete": eventResult.complete,
                "ratesComplete": rateResult.complete,
                "failures": failures
            ]
        ]
        return try JSONSerialization.data(withJSONObject: value)
    }

    private func directOptionalComponent(
        path: String,
        body: [String: TONAPIRequestValue],
        fallbackJSON: String
    ) async throws -> TONDirectComponent {
        do {
            return TONDirectComponent(
                data: try await directResponseData(
                    path: path,
                    body: body
                ),
                complete: true,
                failureCode: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return TONDirectComponent(
                data: Data(fallbackJSON.utf8),
                complete: false,
                failureCode: "ton_\(path)_direct_unavailable"
            )
        }
    }

    private func directReadRequest(
        path: String,
        body: [String: TONAPIRequestValue]
    ) throws -> URLRequest {
        let endpoint: URL
        switch path {
        case "account":
            endpoint = try directAccountURL(
                body: body,
                suffix: nil
            )
        case "jettons":
            endpoint = try directAccountURL(
                body: body,
                suffix: "jettons",
                queryItems: [
                    URLQueryItem(name: "currencies", value: "usd"),
                    URLQueryItem(
                        name: "limit",
                        value: String(body["limit"]?.integerValue ?? 1_000)
                    ),
                    URLQueryItem(
                        name: "offset",
                        value: String(body["offset"]?.integerValue ?? 0)
                    )
                ]
            )
        case "events":
            var queryItems = [
                URLQueryItem(
                    name: "limit",
                    value: String(body["limit"]?.integerValue ?? 100)
                ),
                URLQueryItem(name: "subject_only", value: "false")
            ]
            if let before = body["beforeLt"]?.stringValue {
                queryItems.append(
                    URLQueryItem(name: "before_lt", value: before)
                )
            }
            endpoint = try directAccountURL(
                body: body,
                suffix: "events",
                queryItems: queryItems
            )
        case "seqno":
            guard let address = body["address"]?.stringValue else {
                throw TONProviderError.providerRejected(
                    "direct_seqno_address"
                )
            }
            endpoint = directReadBaseURL
                .appendingPathComponent("wallet")
                .appendingPathComponent(address)
                .appendingPathComponent("seqno")
        case "rates":
            endpoint = try Self.url(
                directReadBaseURL.appendingPathComponent("rates"),
                queryItems: [
                    URLQueryItem(name: "tokens", value: "ton"),
                    URLQueryItem(name: "currencies", value: "usd")
                ]
            )
        default:
            throw TONProviderError.providerRejected(
                "direct_path_unsupported"
            )
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Aperture-iOS-TON/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    private func directAccountURL(
        body: [String: TONAPIRequestValue],
        suffix: String?,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        guard let address = body["address"]?.stringValue else {
            throw TONProviderError.providerRejected(
                "direct_account_address"
            )
        }
        var endpoint = directReadBaseURL
            .appendingPathComponent("accounts")
            .appendingPathComponent(address)
        if let suffix {
            endpoint.appendPathComponent(suffix)
        }
        return try Self.url(endpoint, queryItems: queryItems)
    }

    private func directData(
        for request: URLRequest,
        component: String
    ) async throws -> Data {
        let (data, response) = try await executor(request)
        guard let http = response as? HTTPURLResponse else {
            throw TONProviderError.invalidResponse(
                "direct_\(component)_not_http"
            )
        }
        guard 200..<300 ~= http.statusCode else {
            let providerCode = Self.errorCode(data)
            throw TONProviderError.server(
                status: http.statusCode,
                code: providerCode == "provider_rejected"
                    ? "ton_direct_\(component)_\(http.statusCode)"
                    : providerCode
            )
        }
        guard !data.isEmpty else {
            throw TONProviderError.invalidResponse(
                "direct_\(component)_empty"
            )
        }
        return data
    }

    private static func jsonObject(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TONProviderError.invalidResponse("direct_json")
        }
    }

    private static func url(
        _ endpoint: URL,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        guard !queryItems.isEmpty else { return endpoint }
        var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw TONProviderError.invalidConfiguration
        }
        return url
    }

    private static func isValidBaseURL(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.user == nil
            && url.password == nil
            && url.query == nil
            && url.fragment == nil
    }

    func verifiedJettonWalletAddress(
        masterAddress: String,
        ownerAddress: String
    ) async throws -> String {
        guard let master = TONAddress.rawAddress(from: masterAddress),
              let owner = TONAddress.rawAddress(from: ownerAddress)
        else {
            throw TONProviderError.providerRejected(
                "jetton_wallet_method_address"
            )
        }
        let endpoint = try Self.url(
            directReadBaseURL
                .appendingPathComponent("blockchain")
                .appendingPathComponent("accounts")
                .appendingPathComponent(master)
                .appendingPathComponent("methods")
                .appendingPathComponent("get_wallet_address"),
            queryItems: [URLQueryItem(name: "args", value: owner)]
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Aperture-iOS-TON/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        let data = try await directData(
            for: request,
            component: "jetton_wallet_method"
        )
        guard let result = try? JSONDecoder().decode(
            TONAPIJettonWalletMethodResult.self,
            from: data
        ), result.success,
              result.exitCode == 0,
              let address = result.decoded?.jettonWalletAddress,
              let raw = TONAddress.rawAddress(from: address)
        else {
            throw TONProviderError.invalidResponse(
                "jetton_wallet_method_result"
            )
        }
        return raw
    }

    func broadcast(
        boc: String,
        expectedHash: String
    ) async throws {
        guard (16...262_144).contains(boc.count),
              boc.allSatisfy({
                  $0.isASCII
                      && ($0.isLetter
                          || $0.isNumber
                          || "+/=_-".contains($0))
              })
        else {
            throw TONProviderError.providerRejected("invalid_boc")
        }
        guard Self.canonicalHash(expectedHash) != nil else {
            throw TONProviderError.providerRejected("invalid_expected_hash")
        }
        try await preflight(boc: boc)
        var request = try Self.signedMessageRequest(
            url: Self.broadcastURL,
            boc: boc
        )
        request.setValue(
            "Aperture-iOS-TON/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        let broadcastRequest = request
        let serviceID = "ton_broadcast"
        let endpointHealth = AdaptiveProviderEndpoint(
            serviceID: serviceID,
            endpointURL: Self.broadcastURL,
            baselinePriority: 0
        )
        let attempt = AdaptiveProviderAttempt<Void>(
            endpoint: endpointHealth
        ) {
            let (data, response) = try await executor(broadcastRequest)
            guard let http = response as? HTTPURLResponse else {
                throw TONProviderError.invalidResponse(
                    "broadcast_not_http"
                )
            }
            if 200..<300 ~= http.statusCode {
                guard let envelope = try? JSONDecoder().decode(
                    TONCenterBroadcastResult.self,
                    from: data
                ), envelope.ok,
                      envelope.result.type == "raw.extMessageInfo",
                      let providerHash = Self.canonicalHash(
                        envelope.result.hash
                      ),
                      providerHash == Self.canonicalHash(expectedHash)
                else {
                    throw TONProviderError.invalidResponse(
                        "broadcast_success_invalid"
                    )
                }
                return
            }
            throw Self.broadcastFailure(
                status: http.statusCode,
                failure: Self.providerFailure(data)
            )
        }
        do {
            try await router.executeSubmission(
                serviceID: serviceID,
                attempts: [attempt],
                timeoutSeconds: 12,
                isReliabilityFailure: Self.isReliabilityFailure
            )
        } catch is CancellationError {
            throw TONProviderError.server(
                status: 504,
                code: "ton_broadcast_outcome_unknown_cancelled"
            )
        } catch let error as ProviderReliabilityError {
            if case .timedOut = error {
                throw TONProviderError.server(
                    status: 504,
                    code: "ton_broadcast_outcome_unknown_timeout"
                )
            }
            throw error
        }
    }

    private func preflight(boc: String) async throws {
        let request = try Self.signedMessageRequest(
            url: Self.emulationURL,
            boc: boc
        )
        let serviceID = "ton_broadcast_preflight"
        let endpointHealth = AdaptiveProviderEndpoint(
            serviceID: serviceID,
            endpointURL: Self.emulationURL,
            baselinePriority: 0
        )
        let attempt = AdaptiveProviderAttempt<Void>(
            endpoint: endpointHealth
        ) {
            let (data, response) = try await executor(request)
            guard let http = response as? HTTPURLResponse else {
                throw TONProviderError.invalidResponse("preflight_not_http")
            }
            if 200..<300 ~= http.statusCode {
                guard let result = try? JSONDecoder().decode(
                    TONEmulationResult.self,
                    from: data
                ) else {
                    throw TONProviderError.invalidResponse(
                        "preflight_decoding"
                    )
                }
                if let rejection = result.rejectionCode {
                    throw TONProviderError.server(
                        status: 422,
                        code: rejection
                    )
                }
                return
            }
            let failure = Self.providerFailure(data)
            guard [400, 406, 422].contains(http.statusCode),
                  !failure.message.isEmpty
            else {
                throw TONProviderError.server(
                    status: http.statusCode,
                    code: "ton_preflight_unavailable"
                )
            }
            throw TONProviderError.server(
                status: 422,
                code: Self.preflightCode(failure.message)
            )
        }
        do {
            try await router.executeRead(
                serviceID: serviceID,
                attempts: [attempt],
                timeoutSeconds: 7,
                shouldFallback: Self.isReliabilityFailure
            )
        } catch let error as TONProviderError {
            if case let .server(status, code) = error,
               status == 422,
               code.hasPrefix("ton_preflight_rejected_") {
                throw error
            }
            // Optional emulation availability cannot replace the
            // authoritative one-shot broadcast response.
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Optional emulation availability cannot replace the
            // authoritative one-shot broadcast response.
        }
    }

    private static func isReliabilityFailure(_ error: Error) -> Bool {
        if ProviderReliabilityClassification.isRetryableTransport(error) {
            return true
        }
        guard let providerError = error as? TONProviderError else {
            return false
        }
        switch providerError {
        case .invalidResponse:
            return true
        case let .server(status, _):
            return ProviderReliabilityClassification
                .isRetryableHTTPStatus(status)
        default:
            return false
        }
    }

    private static func signedMessageRequest(
        url: URL,
        boc: String
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.httpBody = try JSONEncoder().encode(
            ["boc": boc]
        )
        return request
    }

    private static func canonicalHash(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 64,
           trimmed.allSatisfy({ $0.isHexDigit }) {
            return trimmed.lowercased()
        }
        var base64 = trimmed
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while !base64.count.isMultiple(of: 4) {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64), data.count == 32 else {
            return nil
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func providerFailure(
        _ data: Data
    ) -> TONProviderFailure {
        (try? JSONDecoder().decode(
            TONProviderFailure.self,
            from: data
        )) ?? TONProviderFailure(
            error: "",
            code: nil,
            errorCode: nil
        )
    }

    private static func preflightCode(_ message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains("before smart-contract execution") {
            return "ton_preflight_rejected_before_execution"
        }
        if normalized.contains("insufficient")
            || normalized.contains("not enough")
        {
            return "ton_preflight_rejected_insufficient_funds"
        }
        if normalized.contains("seqno") {
            return "ton_preflight_rejected_seqno"
        }
        if let exit = exitCode(message) {
            return "ton_preflight_rejected_exit_\(exit)"
        }
        return "ton_preflight_rejected_message"
    }

    private static func broadcastFailure(
        status: Int,
        failure: TONProviderFailure
    ) -> TONProviderError {
        let message = failure.message
        let normalized = message.lowercased()
        if status == 429
            || normalized.contains("rate limit")
            || normalized.contains("ratelimit")
        {
            return .server(
                status: 429,
                code: "ton_broadcast_rate_limited"
            )
        }
        if normalized.contains("invalid_bag_of_cells")
            || normalized.contains("bag-of-cells")
            || normalized.contains("bag of cells")
            || normalized.contains("failed to unpack")
            || normalized.contains("cannot unpack")
        {
            return .server(
                status: 422,
                code: "ton_broadcast_rejected_invalid_boc"
            )
        }
        if normalized.contains("seqno") {
            return .server(
                status: 422,
                code: "ton_broadcast_rejected_seqno"
            )
        }
        if let exit = exitCode(message) {
            return .server(
                status: 422,
                code: "ton_broadcast_rejected_exit_\(exit)"
            )
        }
        if normalized.contains("cannot apply") {
            return .server(
                status: 422,
                code: "ton_broadcast_rejected_contract"
            )
        }
        if status >= 500 || normalized.contains("timeout") {
            return .server(
                status: max(status, 500),
                code: "ton_broadcast_outcome_unknown_timeout"
            )
        }
        let providerCode = failure.providerCode.map(String.init)
            ?? "message"
        return .server(
            status: status,
            code: "ton_broadcast_rejected_\(providerCode)"
        )
    }

    private static func exitCode(_ message: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"exit[ _-]?code\s*(?:=|:)\s*(-?[0-9]+)"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(message.startIndex..., in: message)
        guard let match = expression.firstMatch(
            in: message,
            range: range
        ), let valueRange = Range(match.range(at: 1), in: message)
        else {
            return nil
        }
        let value = String(message[valueRange])
        return value.hasPrefix("-")
            ? "negative_\(value.dropFirst())"
            : value
    }

    private static func errorCode(_ data: Data) -> String {
        struct Envelope: Decodable {
            let error: ProviderError?
        }
        enum ProviderError: Decodable {
            case string(String)
            case object(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(String.self) {
                    self = .string(value)
                    return
                }
                let object = try container.decode(ErrorObject.self)
                self = .object(
                    object.code
                        ?? object.error
                        ?? object.message
                        ?? "provider_rejected"
                )
            }

            var code: String {
                switch self {
                case let .string(value), let .object(value): value
                }
            }
        }
        struct ErrorObject: Decodable {
            let code: String?
            let error: String?
            let message: String?
        }

        return (
            try? JSONDecoder().decode(Envelope.self, from: data)
        )?.error?.code ?? "provider_rejected"
    }
}

enum TONAPIRequestValue: Encodable, Sendable {
    case string(String)
    case integer(Int)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        }
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard case let .integer(value) = self else { return nil }
        return value
    }
}

private struct TONDirectComponent: Sendable {
    let data: Data
    let complete: Bool
    let failureCode: String?
}

private struct TONCenterBroadcastResult: Decodable, Sendable {
    let ok: Bool
    let result: TONCenterBroadcastHash
}

private struct TONCenterBroadcastHash: Decodable, Sendable {
    let type: String
    let hash: String
    let normalizedHash: String

    enum CodingKeys: String, CodingKey {
        case type = "@type"
        case hash
        case normalizedHash = "hash_norm"
    }
}

private struct TONEmulationResult: Decodable, Sendable {
    let trace: Trace
    let event: Event

    var rejectionCode: String? {
        trace.rejectionCode
            ?? event.actions.first(where: {
                $0.status.lowercased() != "ok"
            }).map { _ in "ton_preflight_rejected_action_failed" }
    }

    struct Trace: Decodable, Sendable {
        let transaction: Transaction
        let children: [Trace]?

        var rejectionCode: String? {
            if transaction.success == false {
                return transaction.phaseRejectionCode
                    ?? (transaction.aborted
                        ? "ton_preflight_rejected_aborted"
                        : "ton_preflight_rejected_transaction_failed")
            }
            if let phase = transaction.actionPhase,
               phase.success == false || phase.resultCode != 0 {
                return "ton_preflight_rejected_action_\(Self.code(phase.resultCode))"
            }
            if let phase = transaction.computePhase,
               phase.skipped == false,
               phase.success != true {
                return "ton_preflight_rejected_exit_\(Self.code(phase.exitCode ?? -1))"
            }
            return children?.lazy.compactMap(\.rejectionCode).first
        }

        private static func code(_ value: Int) -> String {
            let rendered = String(value)
            return rendered.hasPrefix("-")
                ? "negative_\(rendered.dropFirst())"
                : rendered
        }
    }

    struct Transaction: Decodable, Sendable {
        let success: Bool
        let aborted: Bool
        let actionPhase: ActionPhase?
        let computePhase: ComputePhase?

        enum CodingKeys: String, CodingKey {
            case success
            case aborted
            case actionPhase = "action_phase"
            case computePhase = "compute_phase"
        }

        var phaseRejectionCode: String? {
            if let phase = actionPhase,
               phase.success == false || phase.resultCode != 0 {
                return "ton_preflight_rejected_action_\(Self.code(phase.resultCode))"
            }
            if let phase = computePhase,
               phase.skipped == false,
               phase.success != true {
                return "ton_preflight_rejected_exit_\(Self.code(phase.exitCode ?? -1))"
            }
            return nil
        }

        private static func code(_ value: Int) -> String {
            let rendered = String(value)
            return rendered.hasPrefix("-")
                ? "negative_\(rendered.dropFirst())"
                : rendered
        }
    }

    struct ActionPhase: Decodable, Sendable {
        let success: Bool
        let resultCode: Int

        enum CodingKeys: String, CodingKey {
            case success
            case resultCode = "result_code"
        }
    }

    struct ComputePhase: Decodable, Sendable {
        let skipped: Bool
        let success: Bool?
        let exitCode: Int?

        enum CodingKeys: String, CodingKey {
            case skipped
            case success
            case exitCode = "exit_code"
        }
    }

    struct Event: Decodable, Sendable {
        let actions: [Action]
    }

    struct Action: Decodable, Sendable {
        let status: String
    }
}

private struct TONProviderFailure: Decodable, Sendable {
    let error: String
    let code: Int?
    let errorCode: Int?

    enum CodingKeys: String, CodingKey {
        case error
        case code
        case errorCode = "error_code"
    }

    var message: String { error.trimmingCharacters(in: .whitespacesAndNewlines) }
    var providerCode: Int? { errorCode ?? code }
}
