import Foundation
import OathDiagnostics

/// Shared, mainnet-only fee lookup. Independent providers overlap, but signing
/// remains local and sequential. A quote is atomic units per 1,000 virtual bytes
/// (serialized bytes on BCH/DOGE), not an amount in whole coins.
public actor UTXOFeeProvider {
    public static let shared = UTXOFeeProvider()
    struct Source: Sendable {
        let name: String
        let delay: Duration
        let load: @Sendable () async throws -> Int64
    }
    private struct Cached: Sendable { let rate: Int64; let expires: ContinuousClock.Instant }
    private struct Flight { let id: UUID; let task: Task<Int64, Error> }
    private let sources: @Sendable (UTXONetwork) -> [Source]
    private let preferred: @Sendable (UTXONetwork) -> Source?
    private let preferredDeadline: Duration
    private let lastResort: @Sendable (UTXONetwork) -> [Source]
    private let lifetime: Duration
    private let deadline: Duration
    private var cache: [UTXONetwork: Cached] = [:]
    private var flights: [UTXONetwork: Flight] = [:]

    public init(ankrAPIKey: String? = nil, alchemyAPIKey: String? = nil) {
        let ankr = AnkrUTXOFeeAPI(apiKey: ankrAPIKey)
        let alchemy = AlchemyUTXOAPI(apiKey: alchemyAPIKey)
        preferred = { alchemy?.feeSource($0) ?? ankr?.source(for: $0) }
        preferredDeadline = alchemy == nil ? .milliseconds(750) : .milliseconds(1250)
        sources = { network in
            let ankrFallback = alchemy == nil ? nil : ankr?.source(for: network)
            return (ankrFallback.map { [$0] } ?? []) + Self.liveSources(network)
        }
        lifetime = .seconds(30); deadline = .seconds(5)
        lastResort = UTXOServerFallback.fees
    }
    init(lifetime: Duration = .seconds(30), deadline: Duration = .seconds(5),
         preferredDeadline: Duration = .milliseconds(750),
         preferred: @escaping @Sendable (UTXONetwork) -> Source? = { _ in nil },
         lastResort: @escaping @Sendable (UTXONetwork) -> [Source] = { _ in [] },
         sources: @escaping @Sendable (UTXONetwork) -> [Source]) {
        self.lifetime = lifetime; self.deadline = deadline; self.sources = sources
        self.lastResort = lastResort
        self.preferred = preferred; self.preferredDeadline = preferredDeadline
    }
    public func rate(for network: UTXONetwork) async throws -> Int64 {
        try Task.checkCancellation()
        if let cached = cache[network], ContinuousClock.now < cached.expires { return cached.rate }
        let flight: Flight
        if let existing = flights[network] { flight = existing }
        else {
            let sources = sources(network), lastResort = lastResort, deadline = deadline
            let preferred = preferred(network), preferredDeadline = preferredDeadline
            let task = Task {
                try await OathDiagnostics.$chain.withValue(network.rawValue) {
                    try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                        do {
                            let started = ContinuousClock.now
                            if let preferred {
                                do {
                                    return try await Self.race([preferred], network: network,
                                                              deadline: min(preferredDeadline, deadline))
                                } catch {
                                    try Task.checkCancellation()
                                    OathDiagnostics.record(error, component: "send", operation: "fee_primary_fallback",
                                        context: ["source": preferred.name, "stage": "quote"])
                                }
                            }
                            // The configured API gets the first attempt, without extending the
                            // total API deadline or holds up public fallbacks.
                            let remaining = deadline - started.duration(to: .now)
                            guard remaining > .zero else { throw BitcoinSendError.feeUnavailable }
                            return try await Self.race(sources, network: network, deadline: remaining)
                        }
                        catch {
                            try Task.checkCancellation()
                            OathDiagnostics.record(error, component: "send", operation: "fee_apis_exhausted")
                            return try await Self.race(lastResort(network), network: network, deadline: .seconds(3))
                        }
                    }
                }
            }
            flight = Flight(id: UUID(), task: task); flights[network] = flight
        }
        // One canceled screen must not cancel a quote needed by another screen.
        // Five seconds for APIs, then at most three for last-resort servers.
        // Failure is never cached as a fee.
        do {
            let value = try await flight.task.value
            if flights[network]?.id == flight.id {
                cache[network] = Cached(rate: value, expires: .now.advanced(by: lifetime))
                flights[network] = nil
            }
            try Task.checkCancellation(); return value
        } catch {
            // diagnostics: fee-flight-propagation
            // Source failures were recorded before failover; cancellation is not
            // an app error. Do not duplicate a shared failure for every waiter.
            if flights[network]?.id == flight.id { flights[network] = nil }
            throw error
        }
    }
    private enum Event: Sendable { case quote(Int64), failed, deadline }
    private static func race(_ sources: [Source], network: UTXONetwork, deadline: Duration) async throws -> Int64 {
        guard !sources.isEmpty else { throw BitcoinSendError.feeUnavailable }
        return try await withThrowingTaskGroup(of: Event.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await Task.sleep(for: deadline); return .deadline }
            for source in sources {
                group.addTask {
                    do {
                        try await Task.sleep(for: source.delay)
                        let rate = try await source.load()
                        try Task.checkCancellation()
                        guard network.sendFeeRates.contains(rate) else { throw BitcoinSendError.feeUnavailable }
                        return .quote(rate)
                    } catch is UTXOAPIBudget.Deferred {
                        // Expected local admission/backoff, not a new API failure.
                        return .failed
                    } catch {
                        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                        OathDiagnostics.record(error, component: "send", operation: "fee_source",
                            context: ["chain": network.rawValue, "stage": "quote", "source": source.name])
                        return .failed
                    }
                }
            }
            var failures = 0
            while let event = try await group.next() {
                try Task.checkCancellation()
                switch event {
                case .quote(let rate): return rate
                case .deadline: throw BitcoinSendError.feeUnavailable
                case .failed:
                    failures += 1
                    if failures == sources.count { throw BitcoinSendError.feeUnavailable }
                }
            }
            throw BitcoinSendError.feeUnavailable
        }
    }
    static func liveSources(_ network: UTXONetwork) -> [Source] {
        UTXOAPIProvider.providers(for: network).enumerated().map { index, provider in
            Source(name: provider.base.host!, delay: .milliseconds(index * 200)) {
                let data = try await UTXOAPIProvider.fetch(provider.feeRequest, limit: 65_536)
                return try provider.decodeFee(data)
            }
        }
    }
    static func decodeBlockcypher(_ data: Data, network: UTXONetwork, now: Date = .now) throws -> Int64 {
        struct Quote: Decodable { let name: String; let time: String; let medium_fee_per_kb: Int64 }
        guard network != .bitcoincash, data.count <= 65_536 else { throw BitcoinSendError.feeUnavailable }
        let quote = try JSONDecoder().decode(Quote.self, from: data)
        let expected = network == .dogecoin ? "DOGE.main" : network == .litecoin ? "LTC.main" : "BTC.main"
        // ISO8601DateFormatter accepts the provider's nanosecond precision.
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: quote.time) ?? ISO8601DateFormatter().date(from: quote.time)
        guard quote.name == expected, let date, (-60...900).contains(now.timeIntervalSince(date)),
              quote.medium_fee_per_kb > 0, quote.medium_fee_per_kb <= network.sendFeeRates.upperBound else {
            throw BitcoinSendError.feeUnavailable
        }
        return max(network.sendFeeRates.lowerBound, quote.medium_fee_per_kb)
    }
}
