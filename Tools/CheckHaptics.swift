import Foundation

@main struct CheckHaptics {
    @MainActor static func main() {
        var checks = 0
        func check(_ value: Bool, _ reason: String) { precondition(value, reason); checks += 1 }
        let suite = "OathHapticChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var active = true
        var events: [OathHapticEvent] = []
        let service = OathHaptics(defaults: defaults, active: { active }, output: { events.append($0) })
        check(service.isEnabled, "Fresh install is enabled")
        service.perform(.tap) { service.play(.copy) }
        check(events == [.copy], "Copy replaces the button tap")
        service.setEnabled(false)
        let mutedCount = events.count
        for event in OathHapticEvent.allCases {
            service.play(event)
            service.perform(event) {}
            check(events.count == mutedCount, "All semantic events honor mute")
        }
        check(!OathHaptics(defaults: defaults).isEnabled, "Mute survives service recreation")
        service.perform(.tap) { service.setEnabled(false) }
        check(events.count == mutedCount, "Turning feedback off does not emit the wrapping tap")
        service.setEnabled(true)
        check(events.last == .selection, "Enabling confirms the preference")
        check(OathHaptics(defaults: defaults).isEnabled, "Enabled setting persists")
        active = false
        let inactiveCount = events.count
        for event in OathHapticEvent.allCases {
            service.play(event)
            check(events.count == inactiveCount, "Background and Face ID interruptions are silent")
        }
        active = true
        check(events.count == inactiveCount, "Returning active does not replay stale results")
        var executed = false
        service.perform(nil) { executed = true }
        check(executed, "Feedback never controls execution of the action")
        for event in OathHapticEvent.allCases {
            var policy = OathHapticPolicy()
            check(policy.accept(event, enabled: true, active: true, now: 1), "Every event has a playable pattern")
            check(!policy.accept(event, enabled: true, active: true, now: 1.01), "Duplicate event is suppressed")
            check(policy.accept(event, enabled: true, active: true, now: 2), "Later repeat remains playable")
            check(!policy.accept(event, enabled: false, active: true, now: 3), "Disabled gate")
            check(!policy.accept(event, enabled: true, active: false, now: 4), "Inactive gate")
        }
        var policy = OathHapticPolicy()
        check(policy.accept(.tap, enabled: true, active: true, now: 1), "Tap accepted")
        check(policy.accept(.error, enabled: true, active: true, now: 1.01), "Error is never swallowed by a tap")
        check(!policy.accept(.navigate, enabled: true, active: true, now: 1.02), "Navigation cannot overwrite the error pulse")
        check(policy.accept(.input, enabled: true, active: true, now: 1.5), "Next passcode attempt works")
        check(policy.accept(.input, enabled: true, active: true, now: 1.57), "Rapid intentional key taps work")
        policy.reset()
        check(policy.accept(.success, enabled: true, active: true, now: 1.58), "Reset has no stale suppression")
        print("Passed \(checks) haptic policy, persistence, activation and duplicate-feedback host checks. No simulator or device used.")
    }
}
