import UIKit

@MainActor enum OathHaptics {
    enum Event { case copy, paste, warning }
    static let shared = Driver()
    final class Driver {
        var events: [Event] = []
        func play(_ event: Event) { events.append(event) }
    }
}

/// Synthetic, deliberately invalid wallet data only; no system clipboard use.
@main struct CheckClipboard {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        let board = UIPasteboard.general
        let marker = "com.aperture.wallet.sensitive-copy"
        let publicValue = "synthetic-address-or-transaction-id"
        OathClipboard.copy(publicValue)
        check(board.options[.localOnly] as? Bool == false, "Public copies block Handoff")
        check(board.options[.expirationDate] == nil, "Public copy acquired secret expiry")
        check(board.items.first?[UIPasteboard.typeAutomatic] as? String == publicValue, "Public text changed")
        check(!board.contains(pasteboardTypes: [marker]), "Public copy marked sensitive")
        check(board.reads == 0, "Copy inspected existing clipboard text")
        check(OathHaptics.shared.events == [.copy], "Copy outcome feedback duplicated or missing")

        let writes = board.writes
        OathClipboard.copy("")
        check(board.writes == writes && OathHaptics.shared.events.count == 1, "Empty public copy overwrote clipboard")

        // Exercise the exact same production path used for recovery words,
        // private keys and passphrases, including significant whitespace.
        for value in ["synthetic-not-a-recovery-phrase", "synthetic-not-a-private-key", "  Synthetic Passphrase\t "] {
            let reads = board.reads
            let feedbackCount = OathHaptics.shared.events.count
            let beforeCopy = Date.now
            OathSensitiveClipboard.copy(value)
            let afterCopy = Date.now
            check(board.items.first?[UIPasteboard.typeAutomatic] as? String == value, "Sensitive text was modified")
            check(board.options[.localOnly] as? Bool == true, "Sensitive copy must stay on this device")
            guard let expiry = board.options[.expirationDate] as? Date else {
                preconditionFailure("Sensitive copy requires system expiry")
            }
            check(expiry >= beforeCopy.addingTimeInterval(60) && expiry <= afterCopy.addingTimeInterval(60),
                  "Sensitive copy must expire 60 seconds after copying")
            check(!board.contains(pasteboardTypes: [marker]), "Sensitive copy must not carry a reset-clearing marker")
            check(board.reads == reads, "Copy read existing clipboard text")
            check(OathHaptics.shared.events.count == feedbackCount + 1 && OathHaptics.shared.events.last == .copy, "Sensitive copy feedback duplicated or missing")
        }

        let sensitiveWrites = board.writes
        let sensitiveFeedback = OathHaptics.shared.events.count
        OathSensitiveClipboard.copy("")
        check(board.writes == sensitiveWrites && OathHaptics.shared.events.count == sensitiveFeedback, "Empty sensitive copy overwrote clipboard")

        OathSensitiveClipboard.copy("synthetic-old-secret")
        OathClipboard.copy(publicValue)
        check(board.items.first?[UIPasteboard.typeAutomatic] as? String == publicValue, "Explicit copy did not replace previous content")
        check(board.options[.expirationDate] == nil, "Public copy inherited previous expiry")
        check(board.options[.localOnly] as? Bool == false, "Public copy inherited secret device restriction")

        board.items = [[UIPasteboard.typeAutomatic: "synthetic-copy-from-another-app"]]

        check(OathClipboard.paste() == "synthetic-copy-from-another-app", "Explicit paste changed incoming text")
        check(OathHaptics.shared.events.last == .paste, "Paste outcome missing")
        board.items = []
        check(OathClipboard.paste() == nil, "Empty paste produced content")
        check(OathHaptics.shared.events.last == .warning, "Empty paste feedback changed")
        print("Passed \(checks) clipboard policy checks using an in-memory pasteboard; no devices or clipboard contents accessed.")
    }
}
