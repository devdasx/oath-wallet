import Foundation
import OathDiagnostics

/// Shared across chain clients and asset-detail screens. Public market quotas
/// belong to the IP, not to a wallet, asset, or URLSession. Never used for RPC,
/// signing, broadcasting, authenticated requests, or account data.
public actor PublicMarketRequests {
    public struct Response: Sendable {
        public let data: Data
        public let status: Int
        public let retryAfter: String?
        public init(data: Data, status: Int, retryAfter: String? = nil) {
            self.data = data; self.status = status; self.retryAfter = retryAfter
        }
    }
    public static let shared = PublicMarketRequests()
    private struct Cached { let response: Response; let expires: ContinuousClock.Instant }
    private var cache: [URL: Cached] = [:]
    private struct Flight {
        let id: UUID
        let task: Task<Response, Error>
        var consumers: Set<UUID>
    }
    private var flights: [URL: Flight] = [:]
    private var cooldown: [String: ContinuousClock.Instant] = [:]
    private var next: [String: ContinuousClock.Instant] = [:]
    private var gates: [String: AnkrPermits] = [:]
    private let spacing: Duration
    public init(spacing: Duration = .milliseconds(2100)) { self.spacing = spacing }

    public static func accepts(_ request: URLRequest) -> Bool {
        guard request.httpMethod == nil || request.httpMethod == "GET",
              request.httpBody == nil, let url = request.url, url.scheme == "https",
              ["api.coingecko.com", "api.geckoterminal.com", "api.dexscreener.com", "coins.llama.fi"].contains(url.host),
              request.allHTTPHeaderFields?.keys.allSatisfy({ ["accept", "user-agent"].contains($0.lowercased()) }) ?? true,
              url.user == nil, url.password == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !(components.queryItems ?? []).contains(where: { $0.name.lowercased().contains("key") }) else { return false }
        return true
    }

    public func send(_ request: URLRequest, operation: @escaping @Sendable () async throws -> Response) async throws -> Response {
        guard Self.accepts(request), let url = request.url, let host = url.host else { return try await operation() }
        try Task.checkCancellation()
        cache = cache.filter { $0.value.expires > .now }
        if let cached = cache[url] { return cached.response }
        let consumer = UUID()
        let flight: Flight
        if var pending = flights[url] {
            pending.consumers.insert(consumer); flights[url] = pending; flight = pending
        } else {
            if let until = cooldown[host], until > .now { throw AnkrError.http(429) }
            // Bound queued work as well as retained payloads.
            guard flights.count < 32 else { throw AnkrError.http(429) }
            let gate = gates[host] ?? AnkrPermits(count: 1); gates[host] = gate
            let task = Task { try await self.execute(url, host: host, gate: gate, operation: operation) }
            flight = Flight(id: UUID(), task: task, consumers: [consumer])
            flights[url] = flight
        }
        return try await withTaskCancellationHandler {
            let result = await flight.task.result
            release(url, flightID: flight.id, consumer: consumer)
            try Task.checkCancellation()
            return try result.get()
        } onCancel: {
            Task { await self.release(url, flightID: flight.id, consumer: consumer) }
        }
    }

    private func release(_ url: URL, flightID: UUID, consumer: UUID) {
        guard var flight = flights[url], flight.id == flightID else { return }
        flight.consumers.remove(consumer)
        if flight.consumers.isEmpty {
            flights[url] = nil
            // A losing quote provider must not occupy the queue after everybody
            // has left. Another consumer still protects a shared request.
            flight.task.cancel()
        } else { flights[url] = flight }
    }

    private func execute(_ url: URL, host: String, gate: AnkrPermits,
                         operation: @escaping @Sendable () async throws -> Response) async throws -> Response {
        try await gate.acquire()
        do {
            if let until = cooldown[host], until > .now { throw AnkrError.http(429) }
            if let instant = next[host], instant > .now { try await Task.sleep(until: instant, clock: .continuous) }
            next[host] = .now.advanced(by: ["api.dexscreener.com", "coins.llama.fi"].contains(host) ? min(spacing, .milliseconds(500)) : spacing)
            let response = try await operation()
            if response.status == 429 {
                cooldown[host] = .now.advanced(by: .seconds(Self.retryDelay(response.retryAfter)))
            } else if response.status == 200, response.data.count <= 16 * 1024 * 1024 {
                let lifetime: Double = url.path == "/api/v3/coins/list" ? 3600 : 30
                if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
                // Keep aggregate memory bounded even for large coin catalogs.
                if cache.values.reduce(0, { $0 + $1.response.data.count }) + response.data.count > 24 * 1024 * 1024 { cache.removeAll(keepingCapacity: true) }
                cache[url] = Cached(response: response, expires: .now.advanced(by: .seconds(lifetime)))
            }
            await gate.release()
            return response
        } catch {
            OathDiagnostics.record(error, operation: "public_market_request", context: ["host": host])
            await gate.release(); throw error
        }
    }

    static func retryDelay(_ header: String?, now: Date = .now) -> Double {
        if let header, let seconds = Double(header), seconds.isFinite { return min(3600, max(60, seconds)) }
        if let header {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: header) { return min(3600, max(60, date.timeIntervalSince(now))) }
        }
        return 60
    }
}
