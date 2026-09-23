import Foundation

/// Owns each endpoint's learned envelope limits. Successful siblings survive
/// a size rejection, and a single failing method is never split indefinitely.
actor SolanaRPCBatchReader {
    private struct Limits {
        var count = 50
        var bytes = 24 * 1_024
    }

    private struct Encoded: Sendable {
        let request: SolanaRPCRequest
        let data: Data
    }

    private var limitsByEndpoint: [URL: Limits] = [:]
    private let executor: SolanaRPCTransport.RequestExecutor

    init(executor: @escaping SolanaRPCTransport.RequestExecutor) {
        self.executor = executor
    }

    typealias ResponseHandler = @Sendable ([SolanaRPCResponse]) async -> Void

    func read(
        endpoint: URL, requests: [SolanaRPCRequest],
        onResponses: ResponseHandler? = nil
    ) async throws -> [SolanaRPCResponse] {
        guard Set(requests.map(\.id)).count == requests.count else {
            throw AnkrAPIError.invalidResponse
        }
        let encoder = JSONEncoder()
        let encoded = try requests.map { Encoded(request: $0, data: try encoder.encode($0)) }
        return try await read(endpoint: endpoint, encoded: encoded, onResponses: onResponses)
    }

    private func read(
        endpoint: URL, encoded: [Encoded], onResponses: ResponseHandler?
    ) async throws -> [SolanaRPCResponse] {
        try Task.checkCancellation()
        guard !encoded.isEmpty else { return [] }
        let chunks = partitions(endpoint: endpoint, encoded: encoded)
        if chunks.count > 1 {
            var result: [SolanaRPCResponse] = []
            // Bound connection fan-out even for a long transaction history.
            for start in stride(from: 0, to: chunks.count, by: 4) {
                let wave = chunks[start..<min(start + 4, chunks.count)]
                let responses = try await withThrowingTaskGroup(of: [SolanaRPCResponse].self) { group in
                    for chunk in wave {
                        group.addTask { try await self.read(endpoint: endpoint, encoded: chunk, onResponses: onResponses) }
                    }
                    var completed: [SolanaRPCResponse] = []
                    for try await response in group { completed += response }
                    return completed
                }
                result += responses
            }
            return result
        }

        let body = Self.body(encoded)
        let responses: [SolanaRPCResponse]
        do {
            responses = try await send(endpoint: endpoint, body: body, requests: encoded.map(\.request))
        } catch {
            guard encoded.count > 1, Self.isSizeError(error) else { throw error }
            learn(endpoint: endpoint, count: encoded.count, bytes: body.count)
            return try await read(endpoint: endpoint, encoded: encoded, onResponses: onResponses)
        }
        // Publish validated successes before recovering siblings. This also
        // preserves completed chunks if another chunk has an HTTP failure.
        await onResponses?(responses.filter { $0.error == nil })
        let oversizedIDs = Set(responses.compactMap { response -> Int? in
            guard let error = response.error,
                  Self.isSizeError(AnkrAPIError.rpcFailure(code: error.code, message: error.message)) else { return nil }
            return response.id
        })
        guard encoded.count > 1, !oversizedIDs.isEmpty else { return responses }
        learn(endpoint: endpoint, count: encoded.count, bytes: body.count)
        let retry = encoded.filter { oversizedIDs.contains($0.request.id) }
        let recovered = try await read(endpoint: endpoint, encoded: retry, onResponses: onResponses)
        return responses.filter { !oversizedIDs.contains($0.id ?? -1) } + recovered
    }

    private func partitions(endpoint: URL, encoded: [Encoded]) -> [[Encoded]] {
        var limits = limitsByEndpoint[endpoint] ?? Limits()
        let host = endpoint.host?.lowercased()
        if host == "api.mainnet-beta.solana.com"
            || (host == "solana-rpc.publicnode.com" && encoded.allSatisfy({ $0.request.method == "getTransaction" })) {
            limits.count = 1
        }
        var result: [[Encoded]] = []
        var chunk: [Encoded] = []
        var bytes = 2
        for item in encoded {
            let addition = item.data.count + (chunk.isEmpty ? 0 : 1)
            if !chunk.isEmpty && (chunk.count >= limits.count || bytes + addition > limits.bytes) {
                result.append(chunk)
                chunk = []
                bytes = 2
            }
            bytes += item.data.count + (chunk.isEmpty ? 0 : 1)
            chunk.append(item)
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }

    private func learn(endpoint: URL, count: Int, bytes: Int) {
        var limits = limitsByEndpoint[endpoint] ?? Limits()
        limits.count = min(limits.count, max(1, count / 2))
        limits.bytes = min(limits.bytes, max(1, (bytes - 2) / 2 + 2))
        limitsByEndpoint[endpoint] = limits
    }

    private static func body(_ encoded: [Encoded]) -> Data {
        var body = Data([91])
        for (index, item) in encoded.enumerated() {
            if index > 0 { body.append(44) }
            body.append(item.data)
        }
        body.append(93)
        return body
    }

    private func send(endpoint: URL, body: Data, requests: [SolanaRPCRequest]) async throws -> [SolanaRPCResponse] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await executor(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AnkrAPIError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            throw AnkrAPIError.httpFailure(statusCode: http.statusCode, message: Self.providerMessage(data))
        }
        let decoder = JSONDecoder()
        if let single = try? decoder.decode(SolanaRPCResponse.self, from: data), let error = single.error {
            throw AnkrAPIError.rpcFailure(code: error.code, message: error.message)
        }
        let responses = try decoder.decode([SolanaRPCResponse].self, from: data)
        // A null-ID error can describe rejection of the whole envelope.
        if responses.count == 1, responses[0].id == nil, let error = responses[0].error {
            throw AnkrAPIError.rpcFailure(code: error.code, message: error.message)
        }
        let expected = Set(requests.map(\.id))
        let actual = responses.compactMap(\.id)
        guard responses.count == requests.count, actual.count == responses.count,
              Set(actual).count == actual.count, Set(actual) == expected,
              responses.allSatisfy({ $0.result != nil || $0.error != nil }) else {
            throw AnkrAPIError.invalidResponse
        }
        // Some gateways include result:null alongside an error. The error
        // still wins, preserving its actionable code and message for callers.
        return responses
    }

    nonisolated static func isSizeError(_ error: Error) -> Bool {
        guard let error = error as? AnkrAPIError else { return false }
        switch error {
        case .httpFailure(413, _): return true
        case let .rpcFailure(code, message):
            if code == -32062 { return true }
            let text = message.lowercased()
            return text.contains("batch") && (text.contains("limit") || text.contains("too large") || text.contains("too many"))
        default: return false
        }
    }

    private static func providerMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String
                ?? (object["error"] as? [String: Any])?["message"] as? String else { return nil }
        return String(message.prefix(500))
    }
}
