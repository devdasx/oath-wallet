import OathDiagnostics
import Foundation
import OathDatabase
import OathExchangeRates

actor OathExchangeRateEnvironment {
    static let shared = OathExchangeRateEnvironment()
    private var setup: Task<ExchangeRateService?, Never>?

    @discardableResult func refresh(retryNow: Bool = false) async -> USDExchangeRates? {
        let current: Task<ExchangeRateService?, Never>
        if let setup {
            current = setup
        } else {
            current = Task {
                await OathDiagnostics.attempt("exchange_rate_setup") {
                    ExchangeRateService(database: try await OathDataEnvironment.shared.database())
                }
            }
            setup = current
        }
        guard let service = await current.value else {
            if setup == current { setup = nil }
            return nil
        }
        // The shared service reports each original read, feed or write failure.
        // Waiters and backoff reads only consume that already-reported result.
        return try? await service.refreshIfNeeded(retryNow: retryNow)
    }
}
