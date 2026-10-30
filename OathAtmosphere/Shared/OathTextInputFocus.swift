import Foundation

/// UIKit can end editing synchronously while SwiftUI applies a disabled state.
/// Deliver focus feedback after that update, without replaying an older event
/// over a newer focus request or a removed field.
@MainActor
final class OathTextInputFocus {
    private struct Configuration: Equatable {
        let focused: Bool
        let enabled: Bool
    }

    private var configuration: Configuration?
    private var revision: UInt64 = 0
    private var active = true

    func update(focused: Bool, enabled: Bool) {
        let next = Configuration(focused: focused, enabled: enabled)
        guard next != configuration else { return }
        configuration = next
        cancelPending()
    }

    func receive(_ focused: Bool, apply: @escaping @MainActor (Bool) -> Void) {
        guard active else { return }
        cancelPending()
        let event = revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.revision == event else { return }
            apply(focused)
        }
    }

    func cancelPending() { revision &+= 1 }

    func invalidate() {
        active = false
        cancelPending()
    }
}
