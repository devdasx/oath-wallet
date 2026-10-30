import Foundation

/// ProcessInfo can post on a background queue. The Objective-C entry point must
/// be nonisolated: an actor-isolated selector traps before its body can dispatch.
@MainActor
final class OathArtworkEnergyObserver: NSObject {
    private let center: NotificationCenter
    private var onChange: (@MainActor @Sendable () -> Void)?

    init(center: NotificationCenter = .default,
         onChange: @escaping @MainActor @Sendable () -> Void) {
        self.center = center
        self.onChange = onChange
        super.init()
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange,
                     ProcessInfo.thermalStateDidChangeNotification] {
            center.addObserver(self, selector: #selector(receiveEnergyChange(_:)), name: name, object: nil)
        }
    }

    @objc nonisolated private func receiveEnergyChange(_ notification: Notification) {
        // Do not touch renderer/UI state or wait for the main queue here. Read
        // the current energy policy on MainActor, rather than forwarding a stale
        // notification payload across executors.
        Task { @MainActor [weak self] in
            self?.onChange?()
        }
    }

    func cancel() {
        // A notification already in flight may have queued a Task. Clear the
        // action too, so it cannot restart a stopped renderer after cancellation.
        onChange = nil
        center.removeObserver(self)
    }

    deinit { center.removeObserver(self) }
}
