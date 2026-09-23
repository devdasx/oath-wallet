import Foundation
import WalletCore

struct TONTransactionStatusProvider: Sendable {
    typealias Executor = @Sendable (URLRequest) async throws
        -> (Data, URLResponse)

    private let endpoint: URL
    private let executor: Executor

    init(
        endpoint: URL = URL(
            string: "https://toncenter.com/api/v3/traces"
        )!,
        executor: Executor? = nil
    ) {
        self.endpoint = endpoint
        if let executor {
            self.executor = executor
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 10
            let session = URLSession(configuration: configuration)
            self.executor = { request in
                try await session.data(for: request)
            }
        }
    }

    func status(
        externalMessageHash: String
    ) async throws -> SendTransactionNetworkStatus {
        let hash = externalMessageHash.lowercased()
        guard SendTransactionStatusValidation.isHexHash(
            hash,
            byteCount: 32,
            allowsPrefix: false
        ), let hashData = Data(hexString: hash) else {
            throw SendTransactionStatusProviderError
                .invalidTransactionHash(networkID: TONConstants.networkID)
        }
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw TONProviderError.invalidConfiguration
        }
        components.queryItems = [
            URLQueryItem(name: "msg_hash", value: hash),
            URLQueryItem(name: "include_actions", value: "true"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components.url else {
            throw TONProviderError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Aperture-iOS-TON/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await executor(request)
        guard let http = response as? HTTPURLResponse else {
            throw TONProviderError.invalidResponse("status_not_http")
        }
        guard 200..<300 ~= http.statusCode else {
            throw TONProviderError.server(
                status: http.statusCode,
                code: Self.errorCode(data)
            )
        }
        let envelope: TONTraceStatusEnvelope
        do {
            envelope = try JSONDecoder().decode(
                TONTraceStatusEnvelope.self,
                from: data
            )
        } catch {
            throw TONProviderError.invalidResponse("status_decoding")
        }
        return try Self.status(
            from: envelope,
            expectedExternalHashBase64: hashData.base64EncodedString()
        )
    }

    static func status(
        from envelope: TONTraceStatusEnvelope,
        expectedExternalHashBase64: String
    ) throws -> SendTransactionNetworkStatus {
        guard let trace = envelope.traces.first(where: {
            $0.externalHash == expectedExternalHashBase64
        }) else {
            return .notFound
        }
        if trace.isIncomplete
            || trace.traceInfo.traceState != "complete"
            || trace.traceInfo.pendingMessages > 0 {
            return .pending
        }
        let transactions = Array(trace.transactions.values)
        guard !transactions.isEmpty else {
            throw SendTransactionStatusProviderError.invalidResponse(
                networkID: TONConstants.networkID,
                code: "empty_trace"
            )
        }
        if transactions.contains(where: { $0.emulated }) {
            return .pending
        }
        if try transactions.contains(where: {
            try !$0.finality.isConfirmed
        }) {
            return .pending
        }
        let actions = trace.actions ?? []
        if try actions.contains(where: {
            try !$0.finality.isConfirmed
        }) {
            return .pending
        }
        if transactions.contains(where: { transaction in
            transaction.description.aborted
                || transaction.description.computePhase?.success == false
                || transaction.description.actionPhase?.success == false
        }) || actions.contains(where: { !$0.success }) {
            return .failed
        }
        return .confirmed
    }

    private static func errorCode(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return "status_invalid_body"
        }
        let value = object["error"] as? String
            ?? object["message"] as? String
            ?? "status_provider_error"
        return String(
            value.lowercased().map {
                $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_"
            }
            .split(separator: "_")
            .prefix(8)
            .joined(separator: "_")
            .prefix(120)
        )
    }
}

struct TONTraceStatusEnvelope: Decodable, Sendable {
    let traces: [Trace]

    struct Trace: Decodable, Sendable {
        let externalHash: String?
        let isIncomplete: Bool
        let traceInfo: TraceInfo
        let transactions: [String: Transaction]
        let actions: [Action]?

        enum CodingKeys: String, CodingKey {
            case transactions, actions
            case externalHash = "external_hash"
            case isIncomplete = "is_incomplete"
            case traceInfo = "trace_info"
        }
    }

    struct TraceInfo: Decodable, Sendable {
        let traceState: String
        let pendingMessages: Int

        enum CodingKeys: String, CodingKey {
            case traceState = "trace_state"
            case pendingMessages = "pending_messages"
        }
    }

    struct Transaction: Decodable, Sendable {
        let emulated: Bool
        let finality: Finality
        let description: Description
    }

    struct Description: Decodable, Sendable {
        let aborted: Bool
        let computePhase: Phase?
        let actionPhase: Phase?

        enum CodingKeys: String, CodingKey {
            case aborted
            case computePhase = "compute_ph"
            case actionPhase = "action"
        }
    }

    struct Phase: Decodable, Sendable {
        let success: Bool?
    }

    struct Action: Decodable, Sendable {
        let success: Bool
        let finality: Finality
    }

    enum Finality: Decodable, Sendable {
        case named(String)
        case level(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .named(value.lowercased())
            } else {
                self = .level(try container.decode(Int.self))
            }
        }

        var isConfirmed: Bool {
            get throws {
                switch self {
                case let .named(value):
                    if value == "confirmed" || value == "finalized" {
                        return true
                    }
                    if value == "pending" { return false }
                case let .level(value):
                    // Current hosted TON Center responses use named finality.
                    // Never guess the meaning of an undocumented numeric level.
                    if value < 0 { break }
                }
                throw SendTransactionStatusProviderError.invalidResponse(
                    networkID: TONConstants.networkID,
                    code: "finality"
                )
            }
        }
    }
}
