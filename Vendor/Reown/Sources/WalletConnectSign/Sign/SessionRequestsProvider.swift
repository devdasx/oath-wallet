import Combine
import Foundation

class SessionRequestsProvider {
    private let historyService: HistoryServiceProtocol
    private var sessionRequestPublisherSubject = PassthroughSubject<(request: Request, context: VerifyContext?), Never>()
    private var lastEmitTime: Date?
    private let debounceInterval: TimeInterval = 0.4

    public var sessionRequestPublisher: AnyPublisher<(request: Request, context: VerifyContext?), Never> {
        sessionRequestPublisherSubject.eraseToAnyPublisher()
    }

    init(historyService: HistoryServiceProtocol) {
        self.historyService = historyService
    }

    func emitRequestAfterResponse() {
        Task { @MainActor [weak self] in
            // Cancellation or owner teardown must not emit a stale request.
            do { try await Task.sleep(nanoseconds: 1_000_000_000) }
            catch { return } // Expected task cancellation, no diagnostic failure.
            self?.emitRequestIfPending()
        }
    }

    func emitRequestIfPending() {
        let now = Date()
        if let lastEmitTime = lastEmitTime {
            // Check if the time interval since 'lastEmitTime' is less than 'debounceInterval'
            if now.timeIntervalSince(lastEmitTime) < debounceInterval {
                //    print("🚨 Debounce interval not yet elapsed since last emit.")
                return
            } else {
                //   print("✅ Enough time has elapsed since last emit.")
            }
        } else {
            // print("⚠️ 'lastEmitTime' is nil. Proceeding with operation.")
        }

        self.lastEmitTime = now

        if let oldestRequest = self.historyService.getPendingRequestsSortedByTimestamp().first {
            self.sessionRequestPublisherSubject.send(oldestRequest)
        }
    }
}
