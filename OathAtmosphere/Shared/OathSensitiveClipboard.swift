import UIKit

@MainActor enum OathClipboard {
    static func copy(_ value: String) {
        guard !value.isEmpty else { return }
        // Public addresses and transaction identifiers can use Universal Clipboard.
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

/// Explicit secret copies stay on this device and expire through the system pasteboard.
@MainActor enum OathSensitiveClipboard {
    static func copy(_ value: String) {
        guard !value.isEmpty else { return }
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: value]],
            options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(60)]
        )
        OathHaptics.shared.play(.copy)
    }
}
