import Foundation
import OathDiagnostics

/// Broadcasts only already-signed, journaled bytes. Hedged HTTPS submissions
/// are the same transaction, not parallel spends/signing. An ambiguous result
/// remains pending so the durable journal can retry those identical bytes later.
public struct UTXOBroadcastProvider: Sendable {
    struct Source: Sendable {
        let name: String
        let delay: Duration
        let submit: @Sendable (String) async throws -> String
        let lookup: @Sendable (String) async throws -> Data?
    }
    private let sources: @Sendable (UTXONetwork) -> [Source]
    private let preferred: @Sendable (UTXONetwork) -> Source?
    private let preferredDeadline: Duration
    private let reconciliationDeadline: Duration
    private let lastResort: @Sendable (UTXONetwork) -> [Source]
    private let deadline: Duration
    private let lookupDelay: Duration

    public init(alchemyAPIKey: String? = nil, alchemyNetworks: Set<UTXONetwork> = []) {
        let configured = UTXOConfiguredSources(alchemyAPIKey: alchemyAPIKey, alchemyNetworks: alchemyNetworks)
        preferred = { configured.broadcastPreferred($0) }; preferredDeadline = .milliseconds(250)
        reconciliationDeadline = .seconds(3)
        sources = Self.liveSources; deadline = .seconds(5); lookupDelay = .milliseconds(700)
        lastResort = UTXOServerFallback.broadcasts
    }
    init(deadline: Duration = .seconds(5), lookupDelay: Duration = .milliseconds(700),
         preferredDeadline: Duration = .milliseconds(250),
         reconciliationDeadline: Duration = .seconds(3),
         preferred: @escaping @Sendable (UTXONetwork) -> Source? = { _ in nil },
         lastResort: @escaping @Sendable (UTXONetwork) -> [Source] = { _ in [] },
         sources: @escaping @Sendable (UTXONetwork) -> [Source]) {
        self.sources = sources; self.deadline = deadline; self.lookupDelay = lookupDelay
        self.lastResort = lastResort
        self.preferred = preferred; self.preferredDeadline = preferredDeadline
        self.reconciliationDeadline = reconciliationDeadline
    }
    public func submit(_ raw: Data, txid: String, network: UTXONetwork, reconcileFirst: Bool = false) async -> Bool {
        await OathDiagnostics.$chain.withValue(network.rawValue) {
            await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                await submitScoped(raw, txid: txid, network: network, reconcileFirst: reconcileFirst)
            }
        }
    }
    private enum Event: Sendable { case accepted, failed, deadline }
    private func submitScoped(_ raw: Data, txid: String, network: UTXONetwork, reconcileFirst: Bool) async -> Bool {
        do {
            try Task.checkCancellation()
            guard raw.count <= 1_000_000, try BitcoinTransactions.txid(raw, network: network) == txid else {
                throw UTXOAPIProvider.APIError.mismatchedTransaction
            }
        } catch {
            OathDiagnostics.record(error, component: "send", operation: "broadcast_validation")
            return false
        }
        let hex = raw.hex
        let started = ContinuousClock.now
        if reconcileFirst {
            // Check for the transaction before retrying a persisted broadcast.
            // Local history can lag behind a transaction that has already been mined.
            // Read exact bytes first; presence is acceptance, not confirmation.
            let readers = preferred(network).map { [$0] } ?? []
            // HTTP access can fail while verified TLS peers already have the
            // transaction. Include their read-only reconciliation before any
            // POST; otherwise an API outage unnecessarily resubmits mined bytes.
            if await race(readers + sources(network) + lastResort(network), raw: raw, hex: hex, txid: txid, network: network,
                          deadline: min(reconciliationDeadline, deadline), lookupOnly: true) { return true }
            guard !Task.isCancelled else { return false }
        }
        var writers = sources(network)
        if let source = preferred(network) {
            // Give the primary a short head start, but do not cancel a healthy
            // in-flight primary before hedging the identical bytes to fallbacks.
            writers = [source] + writers.map {
                Source(name:$0.name,delay:$0.delay+preferredDeadline,submit:$0.submit,lookup:$0.lookup)
            }
        }
        let remaining = deadline - started.duration(to: .now)
        if remaining > .zero,
           await race(writers, raw: raw, hex: hex, txid: txid, network: network, deadline: remaining) { return true }
        guard !Task.isCancelled else { return false }
        // Only after every HTTP attempt and reconciliation read has finished.
        return await race(lastResort(network), raw: raw, hex: hex, txid: txid, network: network, deadline: .seconds(3))
    }
    private func race(_ sources: [Source], raw: Data, hex: String, txid: String, network: UTXONetwork,
                      deadline: Duration, lookupOnly: Bool = false) async -> Bool {
        guard !sources.isEmpty, deadline > .zero else { return false }
        return await withTaskGroup(of: Event.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                do { try await Task.sleep(for: deadline) }
                catch is CancellationError { return .failed }
                catch { OathDiagnostics.record(error, component: "send", operation: "broadcast_deadline") }
                return .deadline
            }
            for source in sources {
                if !lookupOnly {
                    group.addTask {
                        do {
                            try await Task.sleep(for: source.delay)
                            let returned = try await source.submit(hex)
                            try Task.checkCancellation()
                            guard returned == txid else { throw UTXOAPIProvider.APIError.mismatchedTransaction }
                            return .accepted
                        } catch is UTXOAPIBudget.Deferred {
                            return .failed // The original throttle was already reported.
                        } catch {
                            OathDiagnostics.record(error, component: "send", operation: "broadcast_api",
                                context: ["source": source.name, "stage": "broadcast"])
                            return .failed
                        }
                    }
                }
                // Independent reads can resolve a lost POST response immediately,
                // including an already-known rejection. Error text alone is never
                // acceptance. Compare bytes too (txid alone excludes witness data).
                group.addTask {
                    do {
                        // A recovery read has its own bounded network window.
                        // The primary's broadcast head start and POST stagger
                        // must not cancel/exclude healthy reconciliation peers.
                        try await Task.sleep(for: lookupOnly ? .zero : lookupDelay + source.delay)
                        guard let found = try await source.lookup(txid) else { return .failed }
                        try Task.checkCancellation()
                        guard found == raw, try BitcoinTransactions.txid(found, network: network) == txid else {
                            throw UTXOAPIProvider.APIError.mismatchedTransaction
                        }
                        return .accepted
                    } catch is UTXOAPIBudget.Deferred {
                        return .failed // Normal admission/backoff, no repeated telemetry.
                    } catch {
                        OathDiagnostics.record(error, component: "send", operation: "broadcast_lookup",
                            context: ["source": source.name, "stage": "reconcile"])
                        return .failed
                    }
                }
            }
            var failures = 0
            for await event in group {
                if Task.isCancelled { return false }
                switch event {
                case .accepted: return true
                case .deadline:
                    OathDiagnostics.record(URLError(.timedOut), component: "send", operation: lookupOnly ? "reconcile_deadline" : "broadcast_deadline",
                        context: ["stage": lookupOnly ? "reconcile" : "broadcast", "count": String(sources.count)])
                    return false
                case .failed:
                    failures += 1
                    if failures == sources.count * (lookupOnly ? 1 : 2) { return false }
                }
            }
            return false
        }
    }
    static func liveSources(_ network: UTXONetwork) -> [Source] {
        UTXOAPIProvider.broadcastProviders(for: network).enumerated().map { index, provider in
            Source(name: provider.base.host!, delay: .milliseconds(index * 200), submit: { hex in
                let data = try await UTXOAPIProvider.fetch(provider.broadcastRequest(hex: hex), limit: 65_536)
                return try provider.decodeBroadcast(data)
            }, lookup: { txid in
                let data = try await UTXOAPIProvider.fetch(provider.lookupRequest(txid: txid), limit: 4_194_304, allowMissing: true)
                return try provider.decodeRaw(data, txid: txid)
            })
        }
    }
}
