import Foundation
import OathDiagnostics

/// Only the public, wallet-independent market directory is shared. Account
/// balances, pinned ledger reads and transactions never enter this cache.
actor ThorchainCatalogRequests {
    static let shared = ThorchainCatalogRequests()
    private var flight: Task<ThorchainCatalog, Error>?
    private var cached: (ThorchainCatalog, ContinuousClock.Instant)?
    private let lifetime: Duration

    init(lifetime: Duration = .seconds(15)) { self.lifetime = lifetime }

    func value(load: @escaping @Sendable () async throws -> ThorchainCatalog) async throws -> ThorchainCatalog {
        try Task.checkCancellation()
        if let cached, cached.1 > .now { return cached.0 }
        if let flight {
            let result = await flight.result
            try Task.checkCancellation()
            return try result.get()
        }
        // Keep one bounded public read alive for other wallets if a consumer
        // navigates away. Every consumer checks cancellation before publication.
        let operationID = OathDiagnostics.operationID ?? UUID()
        let task = Task {
            try await OathDiagnostics.$chain.withValue("thorchain") {
                try await OathDiagnostics.$operationID.withValue(operationID) { try await load() }
            }
        }
        flight = task
        let result = await task.result
        flight = nil
        if case let .success(value) = result { cached = (value, .now.advanced(by: lifetime)) }
        try Task.checkCancellation()
        return try result.get()
    }
}
