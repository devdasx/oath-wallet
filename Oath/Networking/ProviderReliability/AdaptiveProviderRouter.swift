import CryptoKit
import Foundation
import GRDB

struct AdaptiveProviderEndpoint: Hashable, Sendable {
    let serviceID: String
    let endpointID: String
    let baselinePriority: Int

    init(
        serviceID: String,
        endpointURL: URL,
        identityURL: URL? = nil,
        baselinePriority: Int
    ) {
        self.serviceID = serviceID
        endpointID = AdaptiveProviderIdentity.opaqueID(
            serviceID + "|" + (identityURL ?? endpointURL).absoluteString
        )
        self.baselinePriority = baselinePriority
    }
}

struct AdaptiveProviderAttempt<Value: Sendable>: Sendable {
    let endpoint: AdaptiveProviderEndpoint
    let operation: @Sendable () async throws -> Value
}

private enum AdaptiveProviderHedgedOutcome<Value: Sendable>:
    @unchecked Sendable {
    case success(
        endpoint: AdaptiveProviderEndpoint,
        value: Value,
        latencyMilliseconds: Int
    )
    case failure(
        endpoint: AdaptiveProviderEndpoint,
        error: Error,
        latencyMilliseconds: Int
    )
    case cancelled
}

enum ProviderReliabilityError: Error, Equatable, Sendable {
    case timedOut(serviceID: String, endpointID: String)
    case noEndpoints(serviceID: String)

    var diagnosticDescription: String {
        switch self {
        case .timedOut:
            "provider_timeout"
        case .noEndpoints:
            "provider_endpoints_unavailable"
        }
    }
}

enum ProviderRequestDeadline {
    static func run<Value: Sendable>(
        seconds: Double,
        endpoint: AdaptiveProviderEndpoint,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        precondition(seconds > 0)
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(
                    for: .milliseconds(Int64((seconds * 1_000).rounded()))
                )
                try Task.checkCancellation()
                throw ProviderReliabilityError.timedOut(
                    serviceID: endpoint.serviceID,
                    endpointID: endpoint.endpointID
                )
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw CancellationError()
            }
            return value
        }
    }
}

actor AdaptiveProviderRouter {
    static let shared = AdaptiveProviderRouter()

    private static let neutralLatencyMilliseconds = 1_500
    private static let explorationInterval: TimeInterval = 6 * 60 * 60

    private struct Key: Hashable, Sendable {
        let serviceID: String
        let endpointID: String
    }

    private struct Health: Sendable {
        var successCount = 0
        var failureCount = 0
        var consecutiveFailures = 0
        var ewmaLatencyMilliseconds: Int?
        var cooldownUntil: Double?
        var lastSuccessAt: Double?
        var lastFailureAt: Double?
    }

    private var healthByKey: [Key: Health] = [:]
    private var loadedServices: Set<String> = []
    private let persistsHealth: Bool

    init(persistsHealth: Bool = true) {
        self.persistsHealth = persistsHealth
    }

    func ordered(
        _ endpoints: [AdaptiveProviderEndpoint],
        now: Date = Date(),
        allowExploration: Bool = true
    ) async -> [AdaptiveProviderEndpoint] {
        guard let serviceID = endpoints.first?.serviceID else { return [] }
        await loadIfPossible(serviceID: serviceID)
        let timestamp = now.timeIntervalSince1970
        let explorationEndpointID = allowExploration
            ? explorationCandidate(endpoints: endpoints, now: timestamp)
            : nil
        return endpoints.sorted { lhs, rhs in
            rank(
                endpoint: lhs,
                now: timestamp,
                explorationEndpointID: explorationEndpointID
            ) < rank(
                endpoint: rhs,
                now: timestamp,
                explorationEndpointID: explorationEndpointID
            )
        }
    }

    func executeRead<Value: Sendable>(
        serviceID: String,
        attempts: [AdaptiveProviderAttempt<Value>],
        timeoutSeconds: Double,
        overallTimeoutSeconds: Double? = nil,
        shouldFallback: @escaping @Sendable (Error) -> Bool
    ) async throws -> Value {
        guard !attempts.isEmpty else {
            throw ProviderReliabilityError.noEndpoints(serviceID: serviceID)
        }
        let byEndpoint = Dictionary(
            attempts.map { ($0.endpoint, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let ranked = await ordered(attempts.map(\.endpoint))
        let overallBudget = overallTimeoutSeconds
            ?? Self.defaultOverallReadBudget(
                timeoutSeconds: timeoutSeconds,
                attemptCount: attempts.count
            )
        let overallDeadline = Date().addingTimeInterval(
            max(0.001, overallBudget)
        )
        var finalError: Error?
        for endpoint in ranked {
            guard let attempt = byEndpoint[endpoint] else { continue }
            let remaining = overallDeadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let attemptTimeout = min(timeoutSeconds, remaining)
            let startedAt = Date()
            do {
                let value = try await ProviderRequestDeadline.run(
                    seconds: attemptTimeout,
                    endpoint: endpoint,
                    operation: attempt.operation
                )
                await recordSuccess(
                    endpoint: endpoint,
                    latencyMilliseconds: Self.latency(
                        from: startedAt,
                        to: Date()
                    )
                )
                return value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let latency = Self.latency(from: startedAt, to: Date())
                if shouldFallback(error) {
                    await recordFailure(
                        endpoint: endpoint,
                        latencyMilliseconds: latency
                    )
                    finalError = error
                    continue
                }
                await recordSuccess(
                    endpoint: endpoint,
                    latencyMilliseconds: latency
                )
                throw error
            }
        }
        throw finalError
            ?? ProviderReliabilityError.noEndpoints(serviceID: serviceID)
    }

    /// Races a small, health-ranked provider set for latency-sensitive,
    /// idempotent reads. The first authoritative response wins; failed routes
    /// are replaced from the remaining ranked pool without making every
    /// configured endpoint part of the steady-state request fan-out.
    func executeHedgedRead<Value: Sendable>(
        serviceID: String,
        attempts: [AdaptiveProviderAttempt<Value>],
        timeoutSeconds: Double,
        maximumConcurrentAttempts: Int = 2,
        shouldFallback: @escaping @Sendable (Error) -> Bool
    ) async throws -> Value {
        guard !attempts.isEmpty else {
            throw ProviderReliabilityError.noEndpoints(serviceID: serviceID)
        }
        let byEndpoint = Dictionary(
            attempts.map { ($0.endpoint, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let ranked = await ordered(attempts.map(\.endpoint))
        let concurrency = min(
            max(maximumConcurrentAttempts, 1),
            ranked.count
        )

        return try await withThrowingTaskGroup(
            of: AdaptiveProviderHedgedOutcome<Value>.self,
            returning: Value.self
        ) { group in
            var nextIndex = 0
            var finalError: Error?

            func submit(_ endpoint: AdaptiveProviderEndpoint) {
                guard let attempt = byEndpoint[endpoint] else { return }
                group.addTask {
                    let startedAt = Date()
                    do {
                        let value = try await ProviderRequestDeadline.run(
                            seconds: timeoutSeconds,
                            endpoint: endpoint,
                            operation: attempt.operation
                        )
                        return .success(
                            endpoint: endpoint,
                            value: value,
                            latencyMilliseconds: Self.latency(
                                from: startedAt,
                                to: Date()
                            )
                        )
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        return .failure(
                            endpoint: endpoint,
                            error: error,
                            latencyMilliseconds: Self.latency(
                                from: startedAt,
                                to: Date()
                            )
                        )
                    }
                }
            }

            while nextIndex < concurrency {
                submit(ranked[nextIndex])
                nextIndex += 1
            }
            while let outcome = try await group.next() {
                switch outcome {
                case let .success(endpoint, value, latency):
                    await recordSuccess(
                        endpoint: endpoint,
                        latencyMilliseconds: latency
                    )
                    group.cancelAll()
                    return value
                case let .failure(endpoint, error, latency):
                    guard shouldFallback(error) else {
                        await recordSuccess(
                            endpoint: endpoint,
                            latencyMilliseconds: latency
                        )
                        group.cancelAll()
                        throw error
                    }
                    await recordFailure(
                        endpoint: endpoint,
                        latencyMilliseconds: latency
                    )
                    finalError = error
                    if nextIndex < ranked.count {
                        submit(ranked[nextIndex])
                        nextIndex += 1
                    }
                case .cancelled:
                    group.cancelAll()
                    throw CancellationError()
                }
            }
            throw finalError
                ?? ProviderReliabilityError.noEndpoints(serviceID: serviceID)
        }
    }

    /// A fallback list is one logical read, not `N` unrelated reads. Keep the
    /// whole chain bounded to two attempt windows (and at most 16 seconds) so
    /// adding another provider cannot silently increase user-visible latency.
    /// An explicitly supplied budget still takes precedence.
    static func defaultOverallReadBudget(
        timeoutSeconds: Double,
        attemptCount: Int
    ) -> Double {
        let attemptWindowCount = Double(min(max(attemptCount, 1), 2))
        return max(
            timeoutSeconds,
            min(timeoutSeconds * attemptWindowCount, 16)
        )
    }

    /// Submissions are intentionally never retried or failed over. A timeout
    /// is ambiguous because the first provider may already have accepted the
    /// signed payload.
    func executeSubmission<Value: Sendable>(
        serviceID: String,
        attempts: [AdaptiveProviderAttempt<Value>],
        timeoutSeconds: Double,
        isReliabilityFailure: @escaping @Sendable (Error) -> Bool
    ) async throws -> Value {
        guard !attempts.isEmpty else {
            throw ProviderReliabilityError.noEndpoints(serviceID: serviceID)
        }
        let byEndpoint = Dictionary(
            attempts.map { ($0.endpoint, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let endpoint = await ordered(
            attempts.map(\.endpoint),
            allowExploration: false
        ).first,
              let attempt = byEndpoint[endpoint]
        else {
            throw ProviderReliabilityError.noEndpoints(serviceID: serviceID)
        }
        let startedAt = Date()
        do {
            let value = try await ProviderRequestDeadline.run(
                seconds: timeoutSeconds,
                endpoint: endpoint,
                operation: attempt.operation
            )
            await recordSuccess(
                endpoint: endpoint,
                latencyMilliseconds: Self.latency(
                    from: startedAt,
                    to: Date()
                )
            )
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let latency = Self.latency(from: startedAt, to: Date())
            if isReliabilityFailure(error) {
                await recordFailure(
                    endpoint: endpoint,
                    latencyMilliseconds: latency
                )
            } else {
                await recordSuccess(
                    endpoint: endpoint,
                    latencyMilliseconds: latency
                )
            }
            throw error
        }
    }

    func recordSuccess(
        endpoint: AdaptiveProviderEndpoint,
        latencyMilliseconds: Int
    ) async {
        let key = Key(
            serviceID: endpoint.serviceID,
            endpointID: endpoint.endpointID
        )
        var health = healthByKey[key] ?? Health()
        health.successCount += 1
        health.consecutiveFailures = 0
        health.cooldownUntil = nil
        health.lastSuccessAt = Date().timeIntervalSince1970
        health.ewmaLatencyMilliseconds = Self.updatedEWMA(
            current: health.ewmaLatencyMilliseconds,
            sample: latencyMilliseconds
        )
        healthByKey[key] = health
        await persist(health, key: key)
    }

    func recordFailure(
        endpoint: AdaptiveProviderEndpoint,
        latencyMilliseconds: Int
    ) async {
        let key = Key(
            serviceID: endpoint.serviceID,
            endpointID: endpoint.endpointID
        )
        var health = healthByKey[key] ?? Health()
        health.failureCount += 1
        health.consecutiveFailures += 1
        let now = Date().timeIntervalSince1970
        health.lastFailureAt = now
        health.ewmaLatencyMilliseconds = Self.updatedEWMA(
            current: health.ewmaLatencyMilliseconds,
            sample: latencyMilliseconds
        )
        let cooldown = Self.cooldownSeconds(
            consecutiveFailures: health.consecutiveFailures
        )
        health.cooldownUntil = cooldown > 0 ? now + cooldown : nil
        healthByKey[key] = health
        await persist(health, key: key)
    }

    private func rank(
        endpoint: AdaptiveProviderEndpoint,
        now: Double,
        explorationEndpointID: String?
    ) -> (Int, Int, Int, Int) {
        let key = Key(
            serviceID: endpoint.serviceID,
            endpointID: endpoint.endpointID
        )
        guard let health = healthByKey[key] else {
            return (
                0,
                endpoint.endpointID == explorationEndpointID ? 0 : 1,
                Self.neutralLatencyMilliseconds,
                endpoint.baselinePriority
            )
        }
        let coolingDown = (health.cooldownUntil ?? 0) > now ? 1 : 0
        let lastObservation = max(
            health.lastSuccessAt ?? 0,
            health.lastFailureAt ?? 0
        )
        let observationAge = lastObservation > 0
            ? max(0, now - lastObservation)
            : 0
        let decayDivisor = Self.decayDivisor(age: observationAge)
        let successCount = health.successCount / decayDivisor
        let failureCount = health.failureCount / decayDivisor
        let consecutiveFailures = health.consecutiveFailures / decayDivisor
        let total = successCount + failureCount
        let failurePartsPerThousand = total > 0
            ? (failureCount * 1_000) / total
            : 0
        let latency = Self.decayedLatency(
            health.ewmaLatencyMilliseconds,
            divisor: decayDivisor
        )
        let reliabilityPenalty = failurePartsPerThousand * 2
        let consecutiveFailurePenalty = consecutiveFailures * 1_000
        let qualityScore = latency
            + reliabilityPenalty
            + consecutiveFailurePenalty
        return (
            coolingDown,
            coolingDown == 0
                && endpoint.endpointID == explorationEndpointID ? 0 : 1,
            qualityScore,
            endpoint.baselinePriority
        )
    }

    /// Selects at most one route for a bounded health probe. A newly added
    /// endpoint is measured once, while an old measurement is refreshed only
    /// after the exploration interval. Active cooldowns are never bypassed.
    private func explorationCandidate(
        endpoints: [AdaptiveProviderEndpoint],
        now: Double
    ) -> String? {
        let available = endpoints.filter { endpoint in
            let key = Key(
                serviceID: endpoint.serviceID,
                endpointID: endpoint.endpointID
            )
            return (healthByKey[key]?.cooldownUntil ?? 0) <= now
        }

        if let unmeasured = available
            .filter({ endpoint in
                let key = Key(
                    serviceID: endpoint.serviceID,
                    endpointID: endpoint.endpointID
                )
                guard let health = healthByKey[key] else { return true }
                return health.lastSuccessAt == nil && health.lastFailureAt == nil
            })
            .min(by: Self.baselineOrder)
        {
            return unmeasured.endpointID
        }

        let stale = available.compactMap { endpoint -> (AdaptiveProviderEndpoint, Double)? in
            let key = Key(
                serviceID: endpoint.serviceID,
                endpointID: endpoint.endpointID
            )
            guard let health = healthByKey[key] else { return nil }
            let lastObservation = max(
                health.lastSuccessAt ?? 0,
                health.lastFailureAt ?? 0
            )
            guard lastObservation > 0,
                  now - lastObservation >= Self.explorationInterval
            else { return nil }
            return (endpoint, lastObservation)
        }
        return stale.min { lhs, rhs in
            if lhs.1 == rhs.1 {
                return Self.baselineOrder(lhs.0, rhs.0)
            }
            return lhs.1 < rhs.1
        }?.0.endpointID
    }

    private func loadIfPossible(serviceID: String) async {
        guard persistsHealth,
              !loadedServices.contains(serviceID),
              let database = try? WalletDatabaseRuntime.require()
        else { return }
        do {
            let stored = try await database.pool.read { database -> [Key: Health] in
                let rows = try Row.fetchAll(
                    database,
                    sql: """
                    SELECT serviceID, endpointID, successCount, failureCount,
                           consecutiveFailures, ewmaLatencyMilliseconds,
                           cooldownUntil, lastSuccessAt, lastFailureAt
                    FROM providerEndpointHealth
                    WHERE serviceID = ?
                    """,
                    arguments: [serviceID]
                )
                return Dictionary(uniqueKeysWithValues: rows.map { row in
                    let key = Key(
                        serviceID: row["serviceID"],
                        endpointID: row["endpointID"]
                    )
                    let health = Health(
                        successCount: row["successCount"],
                        failureCount: row["failureCount"],
                        consecutiveFailures: row["consecutiveFailures"],
                        ewmaLatencyMilliseconds: row["ewmaLatencyMilliseconds"],
                        cooldownUntil: row["cooldownUntil"],
                        lastSuccessAt: row["lastSuccessAt"],
                        lastFailureAt: row["lastFailureAt"]
                    )
                    return (key, health)
                })
            }
            // Another caller may finish loading or record a newer observation
            // while the async read is suspended. Never overwrite that state.
            guard loadedServices.insert(serviceID).inserted else { return }
            healthByKey.merge(stored) { current, _ in current }
        } catch {
            // Health data is an optimization. Network access must continue
            // when the database is unavailable or being reset.
        }
    }

    private func persist(_ health: Health, key: Key) async {
        guard persistsHealth,
              let database = try? WalletDatabaseRuntime.require()
        else { return }
        do {
            try await database.pool.write { database in
                try database.execute(
                    sql: """
                    INSERT INTO providerEndpointHealth (
                        serviceID, endpointID, successCount, failureCount,
                        consecutiveFailures, ewmaLatencyMilliseconds,
                        cooldownUntil, lastSuccessAt, lastFailureAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(serviceID, endpointID) DO UPDATE SET
                        successCount = excluded.successCount,
                        failureCount = excluded.failureCount,
                        consecutiveFailures = excluded.consecutiveFailures,
                        ewmaLatencyMilliseconds = excluded.ewmaLatencyMilliseconds,
                        cooldownUntil = excluded.cooldownUntil,
                        lastSuccessAt = excluded.lastSuccessAt,
                        lastFailureAt = excluded.lastFailureAt,
                        updatedAt = excluded.updatedAt
                    """,
                    arguments: [
                        key.serviceID,
                        key.endpointID,
                        health.successCount,
                        health.failureCount,
                        health.consecutiveFailures,
                        health.ewmaLatencyMilliseconds,
                        health.cooldownUntil,
                        health.lastSuccessAt,
                        health.lastFailureAt,
                        Date().timeIntervalSince1970
                    ]
                )
            }
        } catch {
            // Routing remains available in memory when persistence fails.
        }
    }

    private static func updatedEWMA(current: Int?, sample: Int) -> Int {
        guard let current else { return max(1, sample) }
        return max(1, ((current * 3) + sample) / 4)
    }

    private static func baselineOrder(
        _ lhs: AdaptiveProviderEndpoint,
        _ rhs: AdaptiveProviderEndpoint
    ) -> Bool {
        if lhs.baselinePriority == rhs.baselinePriority {
            return lhs.endpointID < rhs.endpointID
        }
        return lhs.baselinePriority < rhs.baselinePriority
    }

    private static func decayDivisor(age: TimeInterval) -> Int {
        guard age >= explorationInterval else { return 1 }
        let steps = min(10, Int(age / explorationInterval))
        return 1 << steps
    }

    private static func decayedLatency(
        _ latency: Int?,
        divisor: Int
    ) -> Int {
        guard let latency else { return neutralLatencyMilliseconds }
        return neutralLatencyMilliseconds
            + ((latency - neutralLatencyMilliseconds) / max(1, divisor))
    }

    private static func cooldownSeconds(
        consecutiveFailures: Int
    ) -> Double {
        switch consecutiveFailures {
        case ..<1: 0
        case 1: 5
        case 2: 15
        case 3: 60
        case 4: 300
        default: 900
        }
    }

    private static func latency(from start: Date, to end: Date) -> Int {
        max(1, Int((end.timeIntervalSince(start) * 1_000).rounded()))
    }
}

enum AdaptiveProviderIdentity {
    static func opaqueID(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func scopedServiceID(
        _ base: String,
        operation: String
    ) -> String {
        let normalized = operation.lowercased().map { character in
            character.isASCII && (character.isLetter || character.isNumber)
                ? character : "_"
        }
        let compact = String(normalized)
            .split(separator: "_")
            .prefix(8)
            .joined(separator: "_")
        guard !compact.isEmpty else { return base }
        return "\(base)_\(String(compact.prefix(80)))"
    }

    static func responseTypeOperation<Response>(_ type: Response.Type) -> String {
        opaqueID(String(reflecting: type))
    }

    /// Health belongs to the provider, not a wallet-specific path or query.
    /// Keeping only the origin prevents one database row per address/cursor.
    static func originURL(for url: URL) -> URL {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else { return url }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }
}

enum ProviderReliabilityClassification {
    static func isRetryableTransport(_ error: Error) -> Bool {
        if let reliabilityError = error as? ProviderReliabilityError,
           case .timedOut = reliabilityError {
            return true
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    static func isRetryableHTTPStatus(_ status: Int) -> Bool {
        status == 401
            || status == 403
            || status == 408
            || status == 425
            || status == 429
            || status >= 500
    }

    /// JSON-RPC errors that describe provider health rather than a definitive
    /// failure of the caller's read. Keep this deliberately narrow: execution
    /// reverts, invalid parameters, and account-state errors must remain final.
    static func isRetryableJSONRPCCode(_ code: Int) -> Bool {
        code == 429 // Some RPCs report HTTP throttling in the RPC envelope.
            || code == -32603 // Internal error
            || code == -32004 // Method/resource temporarily unavailable
            || code == -32005 // Provider rate or resource limit
    }

    /// Some public gateways return non-standard JSON-RPC codes for capacity
    /// failures. Treat the response as retryable only when its sanitized text
    /// unambiguously describes provider availability rather than caller input
    /// or contract execution.
    static func isRetryableJSONRPCError(
        code: Int,
        message: String
    ) -> Bool {
        if isRetryableJSONRPCCode(code) { return true }

        let normalized = message.lowercased()
        return (code == -32_046
            && normalized.contains("cannot fulfill request"))
            || (code == -32_601
                && normalized.contains("method is not whitelisted"))
            || normalized.contains("request timeout")
            || normalized.contains("rate limit")
            || normalized.contains("rate exceeded")
            || normalized.contains("too many requests")
            || normalized.contains("temporarily unavailable")
            || normalized.contains("no nodes available")
            || normalized.contains("resource exhausted")
            || normalized.contains("free plan")
    }
}
