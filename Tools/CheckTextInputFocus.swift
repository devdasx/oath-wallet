import Foundation

// Mac-host regression check; no simulator or device is needed.
// swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
//   OathAtmosphere/Shared/OathTextInputFocus.swift Tools/CheckTextInputFocus.swift \
//   -o /tmp/oath-text-input-focus && /tmp/oath-text-input-focus
@main struct CheckTextInputFocus {
    @MainActor private final class BindingProbe {
        var value = true
        var updatingView = false
        var deliveries = 0

        func receive(_ value: Bool) {
            precondition(!updatingView, "Focus must never write a binding during a view update")
            self.value = value
            deliveries += 1
        }
    }

    @MainActor static func main() async {
        let focus = OathTextInputFocus()
        let binding = BindingProbe()
        focus.update(focused: true, enabled: true)

        // Mirrors UIKit synchronously ending editing when updateUIView disables
        // a focused field. The binding must wait until reconciliation finishes.
        binding.updatingView = true
        focus.update(focused: true, enabled: false)
        focus.receive(false, apply: binding.receive)
        precondition(binding.value && binding.deliveries == 0)
        binding.updatingView = false
        await drainMainQueue()
        precondition(!binding.value && binding.deliveries == 1)

        // A new focus request wins over an already queued blur, including the
        // false-to-true sequence used when moving between form fields.
        binding.value = true
        focus.update(focused: true, enabled: true)
        focus.receive(false, apply: binding.receive)
        focus.update(focused: false, enabled: true)
        focus.update(focused: true, enabled: true)
        await drainMainQueue()
        precondition(binding.value && binding.deliveries == 1)

        // Re-enabling before feedback arrives must not clear the restored focus.
        focus.update(focused: true, enabled: false)
        focus.receive(false, apply: binding.receive)
        focus.update(focused: true, enabled: true)
        await drainMainQueue()
        precondition(binding.value && binding.deliveries == 1)

        // An unrelated text, palette or localization update must not discard a
        // real editing event when the requested focus/enabled state is unchanged.
        focus.receive(false, apply: binding.receive)
        focus.update(focused: true, enabled: true)
        await drainMainQueue()
        precondition(!binding.value && binding.deliveries == 2)

        // Rapid begin/end/begin events deliver only the current focus state.
        focus.receive(true, apply: binding.receive)
        focus.receive(false, apply: binding.receive)
        focus.receive(true, apply: binding.receive)
        await drainMainQueue()
        precondition(binding.value && binding.deliveries == 3)

        // Return and the accessory's Done action cancel earlier native feedback.
        focus.receive(true, apply: binding.receive)
        focus.cancelPending()
        binding.value = false
        await drainMainQueue()
        precondition(!binding.value && binding.deliveries == 3)

        // Dismantling a field invalidates both queued and future callbacks.
        focus.receive(true, apply: binding.receive)
        focus.invalidate()
        focus.receive(true, apply: binding.receive)
        await drainMainQueue()
        precondition(!binding.value && binding.deliveries == 3)

        var removed: OathTextInputFocus? = OathTextInputFocus()
        weak let weakRemoved = removed
        removed?.receive(true, apply: binding.receive)
        removed = nil
        precondition(weakRemoved == nil, "Pending feedback must not retain a removed field")
        await drainMainQueue()
        precondition(!binding.value && binding.deliveries == 3)

        print("PASS: deferred focus writes, newer focus requests, re-enable, unchanged configuration, coalescing, Done, teardown and deallocation")
    }

    private static func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
