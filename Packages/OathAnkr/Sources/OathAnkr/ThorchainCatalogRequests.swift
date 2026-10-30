import Foundation
import OathDiagnostics

/// Only the public, wallet-independent market directory is shared. Account
/// balances, pinned ledger reads and transactions never enter this cache.
actor ThorchainCatalogRequests {
    static let shared = ThorchainCatalogRequests()
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var consumers: [UUID: CheckedContinuation<ThorchainCatalog, Error>]
    }
    private var flight: Flight?
    private var cached: (ThorchainCatalog, ContinuousClock.Instant)?
    private let lifetime: Duration

    private let graphQLGate = AnkrPermits(count: 1)
    private var graphQLCooldown: ContinuousClock.Instant?

    init(lifetime: Duration = .seconds(60)) { self.lifetime = lifetime }

    func graphQL(stage: String = "market", load: @Sendable () async throws -> SolanaJSON) async throws -> SolanaJSON {
        try await graphQLGate.acquire()
        var didRequest = false
        do {
            try Task.checkCancellation()
            // No request is made during this pause. Preserve that distinction
            // through outer best-effort boundaries instead of reporting a new
            // remote rate limit for every oracle/vault consumer.
            if let until = graphQLCooldown, until > .now { throw DiagnosticDeferral.publicMarketCooldown }
            didRequest = true
            let value = try await load()
            if ThorchainClient.isMarketRateLimit(value) {
                graphQLCooldown = .now.advanced(by: .seconds(60))
                throw ThorchainError.rateLimited
            }
            await graphQLGate.release()
            return value
        } catch {
            if error as? ThorchainError == .http(429) { graphQLCooldown = .now.advanced(by: .seconds(60)) }
            // A locally deferred request is expected budget control. The first
            // remote error is recorded, without repeatedly reporting the gate.
            if didRequest {
                OathDiagnostics.record(error, component: "ThorchainClient", operation: "market_fallback",
                    context: ["chain": "thorchain", "stage": stage])
            }
            await graphQLGate.release()
            throw error
        }
    }

    func value(load: @escaping @Sendable () async throws -> ThorchainCatalog) async throws -> ThorchainCatalog {
        try Task.checkCancellation()
        if let cached, cached.1 > .now { return cached.0 }
        let consumer = UUID()
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ThorchainCatalog, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var existing = flight {
                    existing.consumers[consumer] = continuation; flight = existing
                    return
                }
                let id = UUID(), operationID = OathDiagnostics.operationID ?? UUID()
                let task = Task {
                    await OathDiagnostics.$chain.withValue("thorchain") {
                        await OathDiagnostics.$operationID.withValue(operationID) {
                            let result: Result<ThorchainCatalog, Error>
                            do {
                                let value = try await load()
                                try Task.checkCancellation()
                                result = .success(value)
                            } catch {
                                if Task.isCancelled {
                                    result = .failure(CancellationError())
                                } else {
                                    OathDiagnostics.record(error, component: "ThorchainClient", operation: "catalog_load",
                                        context: ["chain": "thorchain", "stage": "catalog"])
                                    result = .failure(error)
                                }
                            }
                            self.finish(id, result: result)
                        }
                    }
                }
                flight = Flight(id: id, task: task, consumers: [consumer: continuation])
            }
        } onCancel: {
            Task { await self.cancel(consumer) }
        }
        try Task.checkCancellation()
        return value
    }

    private func finish(_ id: UUID, result: Result<ThorchainCatalog, Error>) {
        // A cancelled transport may finish late. It must not publish into a
        // replacement flight or overwrite that flight's fresher cached result.
        guard let current = flight, current.id == id else { return }
        flight = nil
        if case let .success(value) = result { cached = (value, .now.advanced(by: lifetime)) }
        for continuation in current.consumers.values { continuation.resume(with: result) }
    }

    private func cancel(_ consumer: UUID) {
        guard var current = flight, let continuation = current.consumers.removeValue(forKey: consumer) else { return }
        continuation.resume(throwing: CancellationError())
        if current.consumers.isEmpty {
            flight = nil
            current.task.cancel()
        } else {
            // Preserve one public read for remaining wallets, while cancelled
            // refresh/reset work can finish without waiting for the network.
            flight = current
        }
    }
}
