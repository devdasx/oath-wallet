import Foundation

/// Only app activation and the dashboard request rates. Send reads the same
/// database snapshot immediately and never starts or waits for provider work.
actor SendNetworkFeeQuoteRepository {
    typealias Loader = @Sendable (String) async throws -> SendNetworkFeeQuote
    static let shared = SendNetworkFeeQuoteRepository()

    private struct Refresh {
        let id: UUID
        let task: Task<Void, Never>
    }
    private let loader: Loader
    private var refreshes: [ObjectIdentifier: Refresh] = [:]

    init(loader: @escaping Loader = { try await SendNetworkFeeAPIClient.quote(for: $0) }) {
        self.loader = loader
    }

    func quote(for networkID: String, database: WalletDatabase, now: Date = Date()) async throws -> SendNetworkFeeQuote {
        let record = try? await database.networkFeeRecord(for: networkID)
        return try WalletNetworkFeeCachePolicy.resolvedQuote(record: record, networkID: networkID, now: now)
    }

    func refresh(database: WalletDatabase, force: Bool = false) async {
        let key = ObjectIdentifier(database)
        if let running = refreshes[key] {
            await running.task.value
            return
        }
        guard !database.isPerformingAppReset() else { return }
        let generation = database.applicationSettingsPersistenceGeneration()
        let id = UUID()
        let loader = loader
        let task = Task {
            let networks = ReceiveNetworkCatalog.catalogNetworkIdentifiers
            // Bound both connection pressure and provider concurrency.
            await withTaskGroup(of: Void.self) { group in
                var iterator = networks.makeIterator()
                for _ in 0..<min(4, networks.count) {
                    if let networkID = iterator.next() {
                        group.addTask {
                            await Self.refreshOne(networkID, database: database, generation: generation, force: force, loader: loader)
                        }
                    }
                }
                while await group.next() != nil {
                    guard !Task.isCancelled else { group.cancelAll(); break }
                    if let networkID = iterator.next() {
                        group.addTask {
                            await Self.refreshOne(networkID, database: database, generation: generation, force: force, loader: loader)
                        }
                    }
                }
            }
        }
        refreshes[key] = Refresh(id: id, task: task)
        await task.value
        if refreshes[key]?.id == id { refreshes[key] = nil }
    }

    private static func refreshOne(_ networkID: String, database: WalletDatabase, generation: UInt64,
                                   force: Bool, loader: Loader) async {
        guard !Task.isCancelled, database.applicationSettingsWriteGate(expectedGeneration: generation) == .allowed else { return }
        if !force, let record = try? await database.networkFeeRecord(for: networkID),
           Date().timeIntervalSince1970 - record.lastAttemptAt >= 0,
           Date().timeIntervalSince1970 - record.lastAttemptAt < WalletNetworkFeeCachePolicy.refreshInterval { return }
        let quote: SendNetworkFeeQuote?
        do {
            let candidate = try await loader(networkID)
            quote = SendNetworkFeeAPIClient.isValid(candidate, expectedNetworkID: networkID) ? candidate : nil
        } catch is CancellationError {
            return
        } catch {
            quote = nil
        }
        guard !Task.isCancelled else { return }
        // Write failure never changes the last durable snapshot or blocks Send;
        // its read path can still return the per-network built-in default.
        try? await database.saveNetworkFeeAttempt(networkID: networkID, quote: quote, expectedGeneration: generation)
    }
}
