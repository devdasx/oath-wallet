import Foundation

/// A node's missing receipt is not proof that another node cannot confirm it.
/// Used only for idempotent status reads, never transaction submission.
enum SendStatusReadResolver {
    static func resolve(
        attempts: [AdaptiveProviderAttempt<SendTransactionNetworkStatus>],
        router: AdaptiveProviderRouter = .shared,
        timeoutSeconds: Double = 8
    ) async throws -> SendTransactionNetworkStatus {
        guard let first = attempts.first else {
            throw ProviderReliabilityError.noEndpoints(serviceID: "send_status")
        }
        let ranked = await router.ordered(attempts.map(\.endpoint), allowExploration: false)
        let byEndpoint = Dictionary(attempts.map { ($0.endpoint, $0) }, uniquingKeysWith: { first, _ in first })
        let selected = ranked.compactMap { byEndpoint[$0] }
        return try await withThrowingTaskGroup(
            of: Result<SendTransactionNetworkStatus, any Error>.self
        ) { group in
            var nextIndex = 0
            func enqueue(_ attempt: AdaptiveProviderAttempt<SendTransactionNetworkStatus>) {
                group.addTask {
                    do {
                        let value = try await ProviderRequestDeadline.run(
                            seconds: timeoutSeconds, endpoint: attempt.endpoint,
                            operation: attempt.operation
                        )
                        return .success(value)
                    } catch is CancellationError { throw CancellationError() }
                    catch let error as URLError where error.code == .cancelled { throw CancellationError() }
                    catch { return .failure(error) }
                }
            }
            // At most two reads at a time. Advance through fallbacks only
            // when a completed response cannot establish a terminal result.
            for _ in 0..<min(2, selected.count) {
                enqueue(selected[nextIndex])
                nextIndex += 1
            }
            defer { group.cancelAll() }
            var sawPending = false
            var sawMissing = false
            var sawReplacement = false
            var failure: (any Error)?
            for try await result in group {
                try Task.checkCancellation()
                switch result {
                case .success(.confirmed): return .confirmed
                case .success(.failed): return .failed
                case .success(.canceled): return .canceled
                case .success(.pending): sawPending = true
                case .success(.notFound): sawMissing = true
                case .success(.replaced): sawReplacement = true
                case let .failure(error): failure = error
                }
                if nextIndex < selected.count {
                    enqueue(selected[nextIndex])
                    nextIndex += 1
                }
            }
            if sawPending { return .pending }
            if sawReplacement { return .replaced }
            // Absence is useful only when every attempted provider answered.
            // An outage must not be converted into a missing transaction.
            if sawMissing, failure == nil { return .notFound }
            throw failure ?? ProviderReliabilityError.noEndpoints(serviceID: first.endpoint.serviceID)
        }
    }
}
