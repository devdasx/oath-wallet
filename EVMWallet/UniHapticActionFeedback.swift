import SwiftUI

/// Resolves one native control activation. A callback's semantic feedback takes
/// precedence over the default, including callbacks inside shared buttons.
/// No time-based debounce: two fast taps remain two distinct interactions.
@MainActor
final class UniHapticActionFeedback {
    private var revision: UInt64 = 0

    func recordFeedback() {
        revision &+= 1
    }

    func perform(
        fallback: UniHaptic?,
        emit: (UniHaptic) -> Void,
        action: () -> Void
    ) {
        let before = revision
        action()
        if revision == before, let fallback {
            emit(fallback)
        }
        // Even an intentionally silent child action owns its parent's feedback.
        recordFeedback()
    }
}

extension UniHaptic {
    /// Wrap the native action, not a gesture, so disabled buttons stay silent
    /// and VoiceOver, keyboard and pointer activation have the same behavior.
    @MainActor
    static func action(
        _ event: UniHaptic?,
        engine: UniHapticEngine = .shared,
        perform: @escaping () -> Void
    ) -> () -> Void {
        { engine.performAction(event, action: perform) }
    }

    @MainActor
    static func action(_ perform: @escaping () -> Void) -> () -> Void {
        action(.tap, perform: perform)
    }
}

extension Binding where Value: Equatable {
    /// Only native control writes pass through this binding. Restoring
    /// stored state directly does not create a haptic. Keep SwiftUI's transaction
    /// so interactive back gestures and native transitions remain unchanged.
    @MainActor
    func hapticSelection(engine: UniHapticEngine = .shared) -> Binding<Value> {
        Binding(
            get: { wrappedValue },
            set: { value, transaction in
                guard value != wrappedValue else { return }
                engine.performAction(.selection) {
                    self.transaction(transaction).wrappedValue = value
                }
            }
        )
    }
}
