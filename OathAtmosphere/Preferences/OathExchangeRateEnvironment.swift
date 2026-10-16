import OathDiagnostics
import Foundation
import OathDatabase
import OathExchangeRates

actor OathExchangeRateEnvironment {
    static let shared = OathExchangeRateEnvironment()
    private var setup: Task<ExchangeRateService, Error>?

    @discardableResult func refresh(retryNow: Bool = false) async throws -> USDExchangeRates {
        if setup == nil {
            setup = Task {
                ExchangeRateService(database: try await OathDataEnvironment.shared.database())
            }
        }
        let service: ExchangeRateService
        do { service = try await setup!.value }
        catch { OathDiagnostics.record(error); setup = nil; throw error }
        return try await service.refreshIfNeeded(retryNow: retryNow)
    }
}
