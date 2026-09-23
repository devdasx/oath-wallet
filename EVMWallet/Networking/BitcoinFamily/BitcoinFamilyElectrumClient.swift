import CryptoKit
import Foundation
import Network

struct BitcoinFamilyElectrumReadRating: Sendable {
    let satisfiesRequirement: Bool
    let requiredMatchCount: Int
    let availableValue: BitcoinFamilyAtomicInteger

    func isPreferred(
        over other: BitcoinFamilyElectrumReadRating
    ) -> Bool {
        if requiredMatchCount != other.requiredMatchCount {
            return requiredMatchCount > other.requiredMatchCount
        }
        return availableValue > other.availableValue
    }
}

actor BitcoinFamilyElectrumClient {
    /// Active wallets can have Electrum history responses substantially larger
    /// than the small default used by metadata calls. Keep this bounded below
    /// the connection's 16 MiB framing limit while allowing busy public
    /// addresses to publish their balance without losing history.
    nonisolated static let maximumHistoryResponseBytes = 8_388_608

    private struct Endpoint: Hashable, Sendable {
        let host: String
        let port: UInt16

        var key: String { "\(host)|\(port)" }
    }

    private struct EncodedRequest: Sendable {
        let id: Int
        let method: String
        let payload: Data
    }

    /// Large history and raw-transaction responses must never share a socket
    /// with the tiny exact-balance reads that drive the home screen. Electrum
    /// frames responses on one byte stream, so a multi-megabyte history frame
    /// can otherwise head-of-line block a balance response even when the
    /// server computed that balance immediately.
    private enum ConnectionLane: Hashable, Sendable {
        case interactive
        case bulk
    }

    private struct ConnectionKey: Hashable, Sendable {
        let chain: BitcoinFamilyChain
        let endpoint: Endpoint
        let lane: ConnectionLane
    }

    private struct EndpointResult: Sendable {
        let endpoint: Endpoint
        let value: JSONValue
    }

    static let shared = BitcoinFamilyElectrumClient()
    private var verifiedEndpoints: Set<String> = []
    private var verificationTasks: [String: Task<Void, Error>] = [:]
    private var preferredEndpoints: [BitcoinFamilyChain: Endpoint] = [:]
    private var connections: [
        ConnectionKey: PersistentElectrumConnection
    ] = [:]

    func call(
        chain: BitcoinFamilyChain,
        method: String,
        params: [AnyEncodable] = [],
        maximumResponseBytes: Int = 1_048_576
    ) async throws -> JSONValue {
        do {
            let result = try await executeCall(
                chain: chain, method: method, params: params,
                maximumResponseBytes: maximumResponseBytes
            )
            return result
        } catch {
            throw error
        }
    }

    /// Exact txid lookup across verified mainnet servers. A missing transaction
    /// on one lagging endpoint cannot mask terminal evidence from another.
    func transactionStatus(chain: BitcoinFamilyChain, hash: String) async throws -> SendTransactionNetworkStatus {
        let request = try Self.encodeRequest(method: "blockchain.transaction.get",
            params: [AnyEncodable(hash), AnyEncodable(true)])
        let attempts = chain.endpoints.enumerated().map { index, raw in
            let endpoint = Endpoint(host: raw.0, port: raw.1)
            return AdaptiveProviderAttempt<SendTransactionNetworkStatus>(endpoint: .init(
                serviceID: "electrum-exact-status-" + chain.networkID,
                endpointURL: URL(string: "electrum+tls://\(raw.0):\(raw.1)")!, baselinePriority: index)) {
                try await self.verify(chain: chain, endpoint: endpoint)
                do {
                    let value = try await self.call(chain: chain, endpoint: endpoint, request: request,
                                                    maximumResponseBytes: 1_048_576)
                    return try BitcoinFamilyTransactionStatusProvider.verboseStatus(value,
                        expectedHash: hash, networkID: chain.networkID)
                } catch let error as BitcoinFamilyElectrumError {
                    if case let .rpc(_, message) = error,
                       message.lowercased().contains("no such mempool or blockchain transaction") { return .notFound }
                    throw error
                }
            }
        }
        return try await SendStatusReadResolver.resolve(attempts: attempts)
    }

    private func executeCall(
        chain: BitcoinFamilyChain,
        method: String,
        params: [AnyEncodable],
        maximumResponseBytes: Int
    ) async throws -> JSONValue {
        guard maximumResponseBytes > 0 else {
            throw BitcoinFamilyElectrumError.invalidResponse
        }
        try Task.checkCancellation()
        let request = try Self.encodeRequest(
            method: method,
            params: params
        )
        let endpoints = chain.endpoints.map {
            Endpoint(host: $0.0, port: $0.1)
        }
        let serviceID = AdaptiveProviderIdentity.scopedServiceID(
            "electrum_\(chain.rawValue)",
            operation: method
        )
        let candidates: [(
            endpoint: Endpoint,
            attempt: AdaptiveProviderAttempt<EndpointResult>
        )] = endpoints.enumerated().map { index, endpoint in
            let url = URL(
                string: "electrum+tls://\(endpoint.host):\(endpoint.port)"
            )!
            let provider = AdaptiveProviderEndpoint(
                serviceID: serviceID,
                endpointURL: url,
                baselinePriority: index
            )
            return (
                endpoint,
                AdaptiveProviderAttempt(endpoint: provider) {
                    try await self.verify(chain: chain, endpoint: endpoint)
                    let value = try await self.call(
                        chain: chain,
                        endpoint: endpoint,
                        request: request,
                        maximumResponseBytes: maximumResponseBytes
                    )
                    return EndpointResult(endpoint: endpoint, value: value)
                }
            )
        }
        let attempts = candidates.map(\.attempt)
        let result: EndpointResult
        if method == "blockchain.transaction.broadcast" {
            let verificationAttempts = candidates.map { candidate in
                AdaptiveProviderAttempt<Endpoint>(
                    endpoint: candidate.attempt.endpoint
                ) {
                    try await self.verify(
                        chain: chain,
                        endpoint: candidate.endpoint
                    )
                    return candidate.endpoint
                }
            }
            let verifiedEndpoint: Endpoint
            do {
                verifiedEndpoint = try await AdaptiveProviderRouter.shared
                    .executeRead(
                        serviceID: serviceID,
                        attempts: verificationAttempts,
                        timeoutSeconds: 8,
                        shouldFallback: Self.isReliabilityFailure
                    )
            } catch is CancellationError {
                throw BitcoinFamilyElectrumError.submissionNotAttempted(
                    "cancelled"
                )
            } catch {
                throw BitcoinFamilyElectrumError.submissionNotAttempted(
                    Self.preflightFailureCode(error)
                )
            }
            guard let submissionAttempt = candidates.first(where: {
                $0.endpoint == verifiedEndpoint
            })?.attempt else {
                throw BitcoinFamilyElectrumError.submissionNotAttempted(
                    "verified_endpoint_missing"
                )
            }
            result = try await AdaptiveProviderRouter.shared
                .executeSubmission(
                    serviceID: serviceID,
                    attempts: [submissionAttempt],
                    timeoutSeconds: 10,
                    isReliabilityFailure: Self.isReliabilityFailure
                )
        } else {
            if method == "blockchain.scripthash.get_balance" {
                result = try await AdaptiveProviderRouter.shared
                    .executeHedgedRead(
                        serviceID: serviceID,
                        attempts: attempts,
                        timeoutSeconds: Self.readTimeoutSeconds(for: method),
                        maximumConcurrentAttempts: 3,
                        shouldFallback: { Self.shouldFallbackRead($0, method: method) }
                    )
            } else {
                result = try await AdaptiveProviderRouter.shared.executeRead(
                    serviceID: serviceID,
                    attempts: attempts,
                    timeoutSeconds: Self.readTimeoutSeconds(for: method),
                    shouldFallback: { Self.shouldFallbackRead($0, method: method) }
                )
            }
        }
        preferredEndpoints[chain] = result.endpoint
        return result.value
    }

    /// Reads a value from verified endpoints until the response satisfies a
    /// caller-owned semantic requirement. A structurally valid but incomplete
    /// response is retained as a last resort while the remaining endpoints are
    /// checked. This is required for spend preparation: public Electrum nodes
    /// can briefly disagree about an address's UTXO set even though each RPC
    /// response is valid JSON.
    func callRankedRead(
        chain: BitcoinFamilyChain,
        method: String,
        params: [AnyEncodable] = [],
        maximumResponseBytes: Int = 1_048_576,
        rating: @escaping @Sendable (JSONValue) throws
            -> BitcoinFamilyElectrumReadRating
    ) async throws -> JSONValue {
        guard maximumResponseBytes > 0,
              method != "blockchain.transaction.broadcast" else {
            throw BitcoinFamilyElectrumError.invalidResponse
        }
        try Task.checkCancellation()
        let request = try Self.encodeRequest(
            method: method,
            params: params
        )
        let serviceID = AdaptiveProviderIdentity.scopedServiceID(
            "electrum_\(chain.rawValue)",
            operation: method
        )
        let candidates: [(
            endpoint: Endpoint,
            attempt: AdaptiveProviderAttempt<EndpointResult>
        )] = chain.endpoints.enumerated().map { index, rawEndpoint in
            let endpoint = Endpoint(
                host: rawEndpoint.0,
                port: rawEndpoint.1
            )
            let url = URL(
                string: "electrum+tls://\(endpoint.host):\(endpoint.port)"
            )!
            let provider = AdaptiveProviderEndpoint(
                serviceID: serviceID,
                endpointURL: url,
                baselinePriority: index
            )
            return (
                endpoint,
                AdaptiveProviderAttempt(endpoint: provider) {
                    try await self.verify(chain: chain, endpoint: endpoint)
                    let value = try await self.call(
                        chain: chain,
                        endpoint: endpoint,
                        request: request,
                        maximumResponseBytes: maximumResponseBytes
                    )
                    return EndpointResult(endpoint: endpoint, value: value)
                }
            )
        }
        guard !candidates.isEmpty else {
            throw ProviderReliabilityError.noEndpoints(
                serviceID: serviceID
            )
        }
        let byProvider = Dictionary(
            candidates.map { ($0.attempt.endpoint, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let ranked = await AdaptiveProviderRouter.shared.ordered(
            candidates.map(\.attempt.endpoint)
        )
        let overallBudget = AdaptiveProviderRouter.defaultOverallReadBudget(
            timeoutSeconds: Self.readTimeoutSeconds(for: method),
            attemptCount: candidates.count
        )
        let overallDeadline = Date().addingTimeInterval(overallBudget)
        var incomplete: [(
            result: EndpointResult,
            provider: AdaptiveProviderEndpoint,
            rating: BitcoinFamilyElectrumReadRating,
            latencyMilliseconds: Int
        )] = []
        var bestIncompleteIndex: Int?
        var finalError: Error?

        for provider in ranked {
            try Task.checkCancellation()
            guard let candidate = byProvider[provider] else { continue }
            let remaining = overallDeadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let startedAt = Date()
            do {
                let result = try await ProviderRequestDeadline.run(
                    seconds: min(
                        Self.readTimeoutSeconds(for: method),
                        remaining
                    ),
                    endpoint: provider,
                    operation: candidate.attempt.operation
                )
                let resultRating: BitcoinFamilyElectrumReadRating
                do {
                    resultRating = try rating(result.value)
                } catch {
                    throw BitcoinFamilyElectrumError.invalidResponse
                }
                let latency = Self.latencyMilliseconds(since: startedAt)
                if resultRating.satisfiesRequirement {
                    await AdaptiveProviderRouter.shared.recordSuccess(
                        endpoint: provider,
                        latencyMilliseconds: latency
                    )
                    for prior in incomplete {
                        await AdaptiveProviderRouter.shared.recordFailure(
                            endpoint: prior.provider,
                            latencyMilliseconds:
                                prior.latencyMilliseconds
                        )
                    }
                    preferredEndpoints[chain] = result.endpoint
                    return result.value
                }

                incomplete.append((
                    result: result,
                    provider: provider,
                    rating: resultRating,
                    latencyMilliseconds: latency
                ))
                let newIndex = incomplete.index(before: incomplete.endIndex)
                if let currentIndex = bestIncompleteIndex {
                    if resultRating.isPreferred(
                        over: incomplete[currentIndex].rating
                    ) {
                        bestIncompleteIndex = newIndex
                    }
                } else {
                    bestIncompleteIndex = newIndex
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let latency = Self.latencyMilliseconds(since: startedAt)
                if Self.shouldFallbackRead(error, method: method) {
                    await AdaptiveProviderRouter.shared.recordFailure(
                        endpoint: provider,
                        latencyMilliseconds: latency
                    )
                    finalError = error
                    continue
                }
                await AdaptiveProviderRouter.shared.recordSuccess(
                    endpoint: provider,
                    latencyMilliseconds: latency
                )
                throw error
            }
        }

        if let bestIncompleteIndex {
            let best = incomplete[bestIncompleteIndex]
            for candidate in incomplete {
                await AdaptiveProviderRouter.shared.recordSuccess(
                    endpoint: candidate.provider,
                    latencyMilliseconds: candidate.latencyMilliseconds
                )
            }
            preferredEndpoints[chain] = best.result.endpoint
            return best.result.value
        }
        throw finalError
            ?? ProviderReliabilityError.noEndpoints(serviceID: serviceID)
    }

    /// Returns status changes for one script hash on the fastest verified
    /// mainnet endpoint. The stream remains attached to the same persistent
    /// Electrum connection used for the subscription request.
    func statusUpdates(
        chain: BitcoinFamilyChain,
        scriptHash: String
    ) async throws -> AsyncStream<JSONValue> {
        let params = [AnyEncodable(scriptHash)]

        // Select and verify the fastest responsive endpoint before binding a
        // long-lived subscription to it.
        _ = try await call(
            chain: chain,
            method: "blockchain.scripthash.subscribe",
            params: params,
            maximumResponseBytes: 16_384
        )
        guard let endpoint = preferredEndpoints[chain] else {
            throw BitcoinFamilyElectrumError.unavailable
        }
        let connection = connection(
            for: chain,
            endpoint: endpoint,
            lane: .interactive
        )
        let stream = await connection.notificationStream(
            method: "blockchain.scripthash.subscribe",
            matchingFirstParameter: scriptHash
        )

        // Register the local listener before repeating the idempotent
        // subscription request, closing the event gap between setup and the
        // caller's first exact-balance read.
        let request = try Self.encodeRequest(
            method: "blockchain.scripthash.subscribe",
            params: params
        )
        _ = try await call(
            chain: chain,
            endpoint: endpoint,
            request: request,
            maximumResponseBytes: 16_384
        )
        return stream
    }

    private func verify(
        chain: BitcoinFamilyChain,
        endpoint: Endpoint
    ) async throws {
        let key = verificationKey(chain: chain, endpoint: endpoint)
        guard !verifiedEndpoints.contains(key) else { return }
        if let existing = verificationTasks[key] {
            try await existing.value
            return
        }
        let negotiationRequest = try Self.encodeRequest(
            method: "server.version",
            params: [
                AnyEncodable("Aperture"),
                AnyEncodable("1.4")
            ]
        )
        let headerRequest = try Self.encodeRequest(
            method: "blockchain.block.header",
            params: [AnyEncodable(0)]
        )
        let task = Task {
            let negotiation = try await self.call(
                chain: chain,
                endpoint: endpoint,
                request: negotiationRequest,
                maximumResponseBytes: 16_384
            )
            guard negotiation.array?.count == 2 else {
                throw BitcoinFamilyElectrumError.invalidResponse
            }
            let value = try await self.call(
                chain: chain,
                endpoint: endpoint,
                request: headerRequest,
                maximumResponseBytes: 262_144
            )
            guard let hex = value.string,
                  let header = Data(bitcoinHex: hex),
                  header.count >= 80 else {
                throw BitcoinFamilyElectrumError.invalidResponse
            }
            let first = Data(SHA256.hash(data: header.prefix(80)))
            let hash = Data(SHA256.hash(data: first)).reversed()
                .map { String(format: "%02x", $0) }.joined()
            guard hash == chain.genesisHash else {
                throw BitcoinFamilyElectrumError.invalidResponse
            }
        }
        verificationTasks[key] = task
        do {
            try await task.value
            verifiedEndpoints.insert(key)
            verificationTasks[key] = nil
        } catch {
            verificationTasks[key] = nil
            throw error
        }
    }

    private func call(
        chain: BitcoinFamilyChain,
        endpoint: Endpoint,
        request: EncodedRequest,
        maximumResponseBytes: Int = 1_048_576
    ) async throws -> JSONValue {
        let lane = Self.connectionLane(for: request.method)
        let key = ConnectionKey(
            chain: chain,
            endpoint: endpoint,
            lane: lane
        )
        let connection = connection(
            for: chain,
            endpoint: endpoint,
            lane: lane
        )
        do {
            return try await connection.request(
                id: request.id,
                payload: request.payload,
                maximumResponseBytes: maximumResponseBytes
            )
        } catch let error where !Self.shouldInvalidateSharedConnection(
            after: error
        ) {
            // Cancelling one caller removes only that request from the
            // multiplexed socket. Invalidating the shared connection here
            // would also fail unrelated balance, UTXO, or submission calls
            // that are currently using the same endpoint.
            throw error
        } catch {
            if let current = connections[key], current === connection {
                connections[key] = nil
            }
            // Electrum negotiation is scoped to a TCP/TLS session, not to
            // the hostname. Servers are allowed to close an idle connection;
            // the replacement connection must perform `server.version`
            // again before any blockchain request is sent.
            let verificationKey = verificationKey(
                chain: chain,
                endpoint: endpoint
            )
            verifiedEndpoints.remove(verificationKey)
            verificationTasks[verificationKey] = nil
            connection.invalidate()
            throw error
        }
    }

    private func connection(
        for chain: BitcoinFamilyChain,
        endpoint: Endpoint,
        lane: ConnectionLane
    ) -> PersistentElectrumConnection {
        let key = ConnectionKey(
            chain: chain,
            endpoint: endpoint,
            lane: lane
        )
        if let existing = connections[key] {
            return existing
        }
        let connection = PersistentElectrumConnection(
            host: endpoint.host,
            port: endpoint.port
        )
        connections[key] = connection
        return connection
    }

    private func verificationKey(
        chain: BitcoinFamilyChain,
        endpoint: Endpoint
    ) -> String {
        "\(chain.rawValue)|\(endpoint.key)"
    }

    private nonisolated static func encodeRequest(
        method: String,
        params: [AnyEncodable]
    ) throws -> EncodedRequest {
        let request = ElectrumRequest(
            id: Int.random(in: 1...Int.max),
            method: method,
            params: params
        )
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0a)
        return EncodedRequest(
            id: request.id,
            method: method,
            payload: payload
        )
    }

    /// Bulk calls are isolated from exact balance/subscription/control calls
    /// so their response size cannot delay first balance publication.
    nonisolated static func usesBulkConnection(for method: String) -> Bool {
        connectionLane(for: method) == .bulk
    }

    private nonisolated static func connectionLane(
        for method: String
    ) -> ConnectionLane {
        switch method {
        case "blockchain.scripthash.get_history",
             "blockchain.scripthash.listunspent",
             "blockchain.transaction.get":
            return .bulk
        default:
            return .interactive
        }
    }

    /// A node's application-level read failure is not proof that an address
    /// cannot spend. Try the remaining verified nodes within the read budget.
    /// Broadcast errors must never enter this read-only fallback policy.
    nonisolated static func shouldFallbackRead(_ error: Error, method: String) -> Bool {
        guard method != "blockchain.transaction.broadcast" else { return false }
        if isReliabilityFailure(error) { return true }
        guard case .rpc(1, _) = error as? BitcoinFamilyElectrumError else { return false }
        return ["blockchain.scripthash.listunspent", "blockchain.scripthash.get_balance",
                "blockchain.scripthash.get_history", "blockchain.headers.subscribe"].contains(method)
    }

    private nonisolated static func isReliabilityFailure(
        _ error: Error
    ) -> Bool {
        if ProviderReliabilityClassification.isRetryableTransport(error) {
            return true
        }
        if error is NWError { return true }
        guard let electrumError = error as? BitcoinFamilyElectrumError else {
            return false
        }
        switch electrumError {
        case .unavailable, .invalidResponse, .responseTooLarge:
            return true
        case .submissionNotAttempted:
            return true
        case let .rpc(_, message):
            // A few Electrum implementations discard negotiated client state
            // when their side rotates or expires the socket. Treat their
            // explicit renegotiation response as a session reliability fault
            // so the router can immediately use another verified endpoint.
            return message.localizedCaseInsensitiveContains("server.version")
        }
    }

    private nonisolated static func preflightFailureCode(
        _ error: Error
    ) -> String {
        if let electrum = error as? BitcoinFamilyElectrumError {
            return switch electrum {
            case .unavailable:
                "unavailable"
            case .invalidResponse:
                "invalid_response"
            case .responseTooLarge:
                "response_too_large"
            case let .rpc(code, _):
                "rpc_\(code)"
            case let .submissionNotAttempted(code):
                code
            }
        }
        if let reliability = error as? ProviderReliabilityError {
            return reliability.diagnosticDescription
        }
        let normalized = String(reflecting: type(of: error)).lowercased().map {
            character in
            character.isASCII
                && (character.isLetter || character.isNumber)
                ? character : "_"
        }
        let compact = String(normalized)
            .split(separator: "_")
            .prefix(8)
            .joined(separator: "_")
        return compact.isEmpty ? "unknown" : String(compact.prefix(96))
    }

    /// Exact balance and subscription reads are intentionally bounded more
    /// tightly than full history and raw-transaction reads. They are small,
    /// index-backed Electrum calls on the critical path to first balance
    /// publication, while history responses can legitimately be much larger.
    nonisolated static func readTimeoutSeconds(for method: String) -> Double {
        switch method {
        case "blockchain.scripthash.get_balance",
             "blockchain.scripthash.subscribe":
            return 5
        default:
            return 9
        }
    }

    nonisolated static func shouldInvalidateSharedConnection(
        after error: Error
    ) -> Bool {
        !(error is CancellationError)
    }

    private nonisolated static func latencyMilliseconds(
        since startedAt: Date
    ) -> Int {
        max(
            1,
            Int((Date().timeIntervalSince(startedAt) * 1_000).rounded())
        )
    }

}
