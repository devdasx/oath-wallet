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
        var chartEvents: [(Double, Bool)] = []
        let service = OathHaptics(defaults: defaults, active: { active }, output: { events.append($0) },
                                  chartOutput: { chartEvents.append(($0, $1)) })
        check(service.isEnabled, "Fresh install is enabled")
        check(OathHapticEvent.copy.pattern == .heavy, "Every clipboard copy uses the strong native impact")
        check(OathHapticEvent.tap.pattern == .soft, "Ordinary taps keep their softer feedback")
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
        service.playChartSample(height: 1, movement: 1)
        check(chartEvents.isEmpty, "Chart feedback honors mute")
        service.perform(.tap) { service.setEnabled(false) }
        check(events.count == mutedCount, "Turning feedback off does not emit the wrapping tap")
        service.setEnabled(true)
        check(events.last == .selection, "Enabling confirms the preference")
        check(OathHaptics(defaults: defaults).isEnabled, "Enabled setting persists")
        active = false
        service.playChartSample(height: 1, movement: 1)
        check(chartEvents.isEmpty, "Background chart feedback is silent")
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
        policy.reset()
        check(policy.accept(.selection, enabled: true, active: true, now: 2), "Pull step accepted")
        check(policy.accept(.refresh, enabled: true, active: true, now: 2.01), "Activation is not swallowed by the last pull step")
        check(!policy.accept(.refresh, enabled: true, active: true, now: 2.02), "Duplicate activation remains suppressed")
        check(!policy.accept(.selection, enabled: true, active: true, now: 2.03), "Trailing pull tick cannot overwrite activation")
        let chartService = OathHaptics(defaults: defaults, active: { true },
            chartOutput: { chartEvents.append(($0, $1)) })
        chartService.playChartSample(height: .nan, movement: 0)
        check(chartEvents.isEmpty, "Invalid chart inputs cannot reach the driver")
        chartService.playChartSample(height: 1, movement: 1)
        check(chartEvents.count == 1 && chartEvents[0].0 == 1 && chartEvents[0].1, "Sharp high point produces a strong firm pulse")
        chartService.playChartSample(height: 0, movement: 0)
        check(chartEvents.count == 1, "Rapid chart updates are coalesced")
        check(OathChartFeedback.nearestIndex(to: 0, times: []) == nil, "Empty chart has no sample")
        check(OathChartFeedback.nearestIndex(to: .nan, times: [1, 2]) == nil, "Invalid time is ignored")
        check(OathChartFeedback.nearestIndex(to: -1, times: [10, 20, 40]) == 0, "Left edge clamps to first real sample")
        check(OathChartFeedback.nearestIndex(to: 80, times: [10, 20, 40]) == 2, "Right edge clamps to last real sample")
        check(OathChartFeedback.nearestIndex(to: 28, times: [10, 20, 40]) == 1, "Irregularly spaced samples use time distance")
        check(OathChartFeedback.nearestIndex(to: 31, times: [10, 20, 40]) == 2, "Crossing midpoint advances selection")
        check(OathChartFeedback.intensity(height: -1, movement: -1) == 0.25, "Intensity has a safe floor")
        check(OathChartFeedback.intensity(height: 2, movement: 2) == 1, "Intensity has a safe ceiling")
        check(OathChartFeedback.intensity(height: 0.8, movement: 0) > OathChartFeedback.intensity(height: 0.2, movement: 0), "Higher positions feel stronger")
        check(OathChartFeedback.intensity(height: 0.5, movement: 0.8) > OathChartFeedback.intensity(height: 0.5, movement: 0.1), "Sharper slopes feel stronger")
        print("Passed \(checks) haptic policy, persistence, activation and duplicate-feedback host checks. No simulator or device used.")
    }
}
