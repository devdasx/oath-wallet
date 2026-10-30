import Foundation
import Combine

/// A single, bounded connection wait. Its lock protects every mutable field;
/// only this small callback bridge crosses cancellation/timer executor hops.
/// The connection handlers and their mutable dependencies are not Sendable.
final class SocketConnectionWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var subscription: AnyCancellable?
    private var timer: DispatchWorkItem?
    private var armed = false
    private var disconnections = 0

    func wait(
        for publisher: AnyPublisher<SocketConnectionStatus, Never>,
        timeout: TimeInterval,
        maxDisconnections: Int? = nil,
        start: () -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()

                // Subscribe first: CurrentValueSubject may synchronously report
                // an already connected socket, or connect() may finish immediately.
                let subscription = publisher.sink { [weak self] status in
                    self?.receive(status, maxDisconnections: maxDisconnections)
                }
                let timer = DispatchWorkItem { [weak self] in
                    self?.finish(.failure(NetworkError.connectionFailed))
                }
                lock.lock()
                let pending = result == nil
                if pending {
                    self.subscription = subscription
                    self.timer = timer
                    armed = true
                }
                lock.unlock()
                if pending {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                    start()
                } else {
                    subscription.cancel()
                    timer.cancel()
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func receive(_ status: SocketConnectionStatus, maxDisconnections: Int?) {
        if status == .connected {
            finish(.success(()))
            return
        }
        lock.lock()
        // Ignore the initial disconnected state delivered during subscription.
        if armed { disconnections += 1 }
        let exhausted = armed && maxDisconnections.map { disconnections >= $0 } == true
        lock.unlock()
        if exhausted { finish(.failure(NetworkError.connectionFailed)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        let subscription = self.subscription
        let timer = self.timer
        self.continuation = nil
        self.subscription = nil
        self.timer = nil
        lock.unlock()
        // Do not call Combine or resume Swift tasks while holding our lock.
        subscription?.cancel()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}
