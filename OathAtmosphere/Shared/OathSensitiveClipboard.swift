import UIKit

@MainActor enum OathClipboard {
    static func copy(_ value: String) {
        guard !value.isEmpty else { return }
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: value]], options: [.localOnly: true])
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

/// Mark only the app's own secret copies. Reset must not inspect or clear an
/// unrelated item that the user subsequently copied in another application.
@MainActor enum OathSensitiveClipboard {
    private static let marker = "com.aperture.wallet.sensitive-copy"

    static func copy(_ value: String) {
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: value, marker: Data([1])]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
        OathHaptics.shared.play(.copy)
    }

    static func clearIfOwned() {
        if UIPasteboard.general.contains(pasteboardTypes: [marker]) {
            UIPasteboard.general.items = []
        }
    }
}
