import OathDiagnostics
import SwiftUI

// Factories return the real Button, not a wrapper view. This preserves native
// alert/menu discovery, confirmation roles, toolbar glass and accessibility.
@MainActor func OathButton<Label: View>(role: ButtonRole? = nil, feedback: OathHapticEvent? = .tap,
    action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> Button<Label> {
    Button(role: role, action: {
        OathHaptics.shared.perform(feedback.map { role == .destructive ? .warning : $0 }, action: action)
    }, label: label)
}

@MainActor func OathButton(_ title: String, role: ButtonRole? = nil, feedback: OathHapticEvent? = .tap,
    action: @escaping () -> Void) -> Button<Text> {
    Button(title, role: role) {
        OathHaptics.shared.perform(feedback.map { role == .destructive ? .warning : $0 }, action: action)
    }
}

/// Native sharing with feedback only for an actual completion or failure.
/// Canceling the activity controller never announces a successful share.
struct OathShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            if let error { OathDiagnostics.record(error, component: "sharing", operation: "export") }
            let failed = error != nil
            Task { @MainActor in
                if failed { OathHaptics.shared.play(.error) }
                else if completed { OathHaptics.shared.play(.success) }
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

@MainActor func OathButton(_ title: String, systemImage: String, feedback: OathHapticEvent? = .tap,
    action: @escaping () -> Void) -> Button<Label<Text, Image>> {
    Button(title, systemImage: systemImage) { OathHaptics.shared.perform(feedback, action: action) }
}

@available(iOS 26.0, *)
@MainActor func OathButton(role: ButtonRole, action: @escaping () -> Void) -> Button<DefaultButtonLabel> {
    Button(role: role) { OathHaptics.shared.perform(role == .destructive ? .warning : .tap, action: action) }
}

extension View {
    /// Outcome revisions must change only after a user action, not background
    /// sync or initial loading. Initial values intentionally produce no effect.
    func oathHapticFeedback<T: Equatable>(_ event: OathHapticEvent, trigger: T,
                                        when condition: Bool = true) -> some View {
        onChange(of: trigger) { _, _ in if condition { OathHaptics.shared.play(event) } }
    }
    func oathErrorFeedback<T: Equatable>(_ error: T?) -> some View {
        oathHapticFeedback(.error, trigger: error, when: error != nil)
    }
}
