import OathDiagnostics
import SwiftUI
import LinkPresentation

extension Toggle {
    /// Pin native switches to semantic green instead of inheriting navigation's
    /// label tint (white in Dark mode). UIKit retains the thumb and off states.
    func oathSwitchStyle() -> some View {
        toggleStyle(SwitchToggleStyle(tint: Color(uiColor: .systemGreen)))
    }
}

// Factories return the real Button, not a wrapper view. This preserves native
// alert/menu discovery, confirmation roles, toolbar glass and accessibility.
@MainActor func OathButton<Label: View>(role: ButtonRole? = nil, feedback: OathHapticEvent? = .tap,
    file: StaticString = #fileID, function: StaticString = #function, line: UInt = #line,
    action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> Button<Label> {
    Button(role: role, action: {
        OathHaptics.shared.perform(feedback.map { role == .destructive ? .warning : $0 }, file: file, function: function, line: line, action: action)
    }, label: label)
}

@MainActor func OathButton(_ title: String, role: ButtonRole? = nil, feedback: OathHapticEvent? = .tap,
    file: StaticString = #fileID, function: StaticString = #function, line: UInt = #line,
    action: @escaping () -> Void) -> Button<Text> {
    Button(title, role: role) {
        OathHaptics.shared.perform(feedback.map { role == .destructive ? .warning : $0 }, file: file, function: function, line: line, action: action)
    }
}

/// Native sharing with feedback only for an actual completion or failure.
/// Canceling the activity controller never announces a successful share.
struct OathShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let activityItems: [Any] = items.map { item in
            guard let image = item as? UIImage else { return item }
            return OathSharedImageSource(image: image)
        }
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { activity, completed, _, error in
            if let error { OathDiagnostics.record(error, component: "sharing", operation: "export") }
            let failed = error != nil
            let copied = activity == .copyToPasteboard
            Task { @MainActor in
                if failed { OathHaptics.shared.play(.error) }
                else if completed { OathHaptics.shared.play(copied ? .copy : .success) }
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Image sharing needs explicit header artwork: handing UIKit only a UIImage
/// can leave the share-sheet header using the source app's icon. Keep the
/// preview and exported item tied to the same image, without a fabricated URL.
// UIKit invokes item-source callbacks on the main thread; the Objective-C
// protocol does not carry that isolation in its Swift declaration.
@MainActor final class OathSharedImageSource: NSObject, @preconcurrency UIActivityItemSource {
    private let image: UIImage
    private let metadata: LPLinkMetadata

    init(image: UIImage) {
        self.image = image
        let provider = NSItemProvider(object: image)
        let metadata = LPLinkMetadata()
        metadata.imageProvider = provider
        // Compact share-sheet headers use iconProvider rather than imageProvider.
        metadata.iconProvider = provider
        self.metadata = metadata
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        image
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        image
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                thumbnailImageForActivityType activityType: UIActivity.ActivityType?,
                                suggestedSize size: CGSize) -> UIImage? {
        image
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        metadata
    }
}

@MainActor func OathButton(_ title: String, systemImage: String, feedback: OathHapticEvent? = .tap,
    file: StaticString = #fileID, function: StaticString = #function, line: UInt = #line,
    action: @escaping () -> Void) -> Button<Label<Text, Image>> {
    Button(title, systemImage: systemImage) { OathHaptics.shared.perform(feedback, file: file, function: function, line: line, action: action) }
}

@available(iOS 26.0, *)
@MainActor func OathButton(role: ButtonRole, file: StaticString = #fileID, function: StaticString = #function, line: UInt = #line, action: @escaping () -> Void) -> Button<DefaultButtonLabel> {
    Button(role: role) { OathHaptics.shared.perform(role == .destructive ? .warning : .tap, file: file, function: function, line: line, action: action) }
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
