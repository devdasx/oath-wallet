
import Foundation

struct RetryPolicy {
    let maxAttempts: Int
    let initialDelay: TimeInterval
    let multiplier: Double
    var delayOverride: TimeInterval? = nil
}

class EventsDispatcher {
    private let networkingService: NetworkingServiceProtocol
    private let retryPolicy: RetryPolicy

    init(networkingService: NetworkingServiceProtocol, retryPolicy: RetryPolicy) {
        self.networkingService = networkingService
        self.retryPolicy = retryPolicy
    }

    func executeWithRetry<T: Encodable>(events: [T], isAuthorized: () -> Bool = { true }) async throws -> Bool {
        var attempts = 0
        var delay = retryPolicy.initialDelay

        while attempts < retryPolicy.maxAttempts {
            try Task.checkCancellation()
            guard isAuthorized() else { throw CancellationError() }
            if attempts > 0 || retryPolicy.initialDelay > 0 {
                let actualDelay = retryPolicy.delayOverride ?? delay
                try await Task.sleep(nanoseconds: UInt64(actualDelay * Double(NSEC_PER_SEC)))
                delay *= retryPolicy.multiplier
            }

            try Task.checkCancellation()
            guard isAuthorized() else { throw CancellationError() }
            do {
                return try await networkingService.sendEvents(events)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                guard isAuthorized() else { throw CancellationError() }
                attempts += 1
                if attempts >= retryPolicy.maxAttempts {
                    throw error
                }
            }
        }
        throw NSError(domain: "EventsDispatcherError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Max retry attempts reached"])
    }
}
