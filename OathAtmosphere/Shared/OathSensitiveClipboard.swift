import UIKit

@MainActor enum OathClipboard {
    static func copy(_ value: String) {
        guard !value.isEmpty else { return }
        // Explicit copies participate in Apple's Universal Clipboard (Handoff).
        // Oath never expires or clears copied content, including during reset.
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: value]], options: [.localOnly: false])
        OathHaptics.shared.play(.copy)
    }
    /// Called only by an explicit Paste action. Never poll the clipboard.
    static func paste() -> String? {
        guard let value = UIPasteboard.general.string, !value.isEmpty else {
            OathHaptics.shared.play(.warning)
            return nil
        }
        OathHaptics.shared.play(.paste)
        return value
    }
}

/// Secret copies follow the same user-controlled lifetime as every other copy.
@MainActor enum OathSensitiveClipboard {
    static func copy(_ value: String) {
        OathClipboard.copy(value)
    }
}
