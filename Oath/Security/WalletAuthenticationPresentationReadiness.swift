import UIKit

/// Waits for Apple's authentication UI to relinquish presentation ownership.
/// Each request owns its observers; no navigation or authentication is shared.
@MainActor
final class WalletAuthenticationPresentationReadiness {
    private let applicationState: () -> UIApplication.State
    private let notifications: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var continuation: CheckedContinuation<Void, any Error>?
    var isWaiting: Bool { continuation != nil }

    init(
        applicationState: @escaping () -> UIApplication.State = {
            UIApplication.shared.applicationState
        },
        notifications: NotificationCenter = .default
    ) {
        self.applicationState = applicationState
        self.notifications = notifications
    }

    func wait() async throws {
        try Task.checkCancellation()
        switch applicationState() {
        case .active: return
        case .background: throw CancellationError()
        case .inactive: break
        @unknown default: throw CancellationError()
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                observers = [
                    observe(UIApplication.didBecomeActiveNotification, state: .active),
                    observe(UIApplication.didEnterBackgroundNotification, state: .background)
                ]
                // Do not miss a transition between the initial check and registration.
                applicationStateChanged(applicationState())
                if Task.isCancelled { applicationStateChanged(.background) }
            }
        } onCancel: {
            Task { @MainActor in self.applicationStateChanged(.background) }
        }
        try Task.checkCancellation()
    }

    private func observe(
        _ name: Notification.Name, state: UIApplication.State
    ) -> NSObjectProtocol {
        notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // NotificationCenter delivers these observers on the main queue.
            MainActor.assumeIsolated { self?.applicationStateChanged(state) }
        }
    }

    private func applicationStateChanged(_ state: UIApplication.State) {
        guard state != .inactive, let continuation else { return }
        self.continuation = nil
        for observer in observers { notifications.removeObserver(observer) }
        observers.removeAll()
        if state == .active {
            continuation.resume()
        } else {
            continuation.resume(throwing: CancellationError())
        }
    }
}
