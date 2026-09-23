import CallKit
import Foundation

@MainActor
final class WalletCallSafetyMonitor: NSObject, CXCallObserverDelegate {
    let state = WalletCallSafetyState()
    private var observer: CXCallObserver?

    func start() {
        if observer == nil {
            let observer = CXCallObserver()
            // CallKit guarantees delegate delivery on this queue.
            observer.setDelegate(self, queue: .main)
            self.observer = observer
        }
        refresh()
    }

    func refresh() {
        guard let observer else { return }
        state.refresh(observer.calls.map {
            WalletCallSnapshot(id: $0.uuid, hasEnded: $0.hasEnded)
        })
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let snapshot = WalletCallSnapshot(id: call.uuid, hasEnded: call.hasEnded)
        // Synchronous delivery preserves callback order across foreground refreshes.
        MainActor.assumeIsolated { state.callChanged(snapshot) }
    }
}
