import Foundation

// Mac-host regression checks; no simulator, device or wallet data is used.
// swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
//   OathAtmosphere/Shared/OathAutofocusGate.swift Tools/CheckAutofocus.swift \
//   -o /tmp/oath-autofocus-check && /tmp/oath-autofocus-check
@main struct CheckAutofocus {
    @MainActor static func main() async {
        var deliveries = 0
        let gate = OathAutofocusGate()
        let focus: @MainActor () -> Void = { deliveries += 1 }
        gate.update(enabled: true, active: true, action: focus)
        await drain()
        precondition(deliveries == 0, "Focus must wait for native appearance")

        let push = gate.beginAnimation()
        let content = gate.beginAnimation()
        gate.setAppeared(true)
        await drain()
        precondition(deliveries == 0, "The first frame is not transition completion")
        gate.endAnimation(push)
        await drain()
        precondition(deliveries == 0, "Overlapping animations must all finish")
        gate.endAnimation(content)
        precondition(deliveries == 0, "Focus must leave the current layout transaction")
        await drain()
        precondition(deliveries == 1)
        gate.update(enabled: true, active: true, action: focus)
        gate.endAnimation(content)
        gate.setAppeared(true)
        await drain()
        precondition(deliveries == 1, "Rendering and repeated completions cannot reopen a dismissed keyboard")

        // Data arriving after navigation is complete is a separate readiness
        // condition (for example, loading the contact editor's networks).
        gate.setAppeared(false)
        gate.update(enabled: false, active: true, action: focus)
        gate.setAppeared(true)
        await drain()
        precondition(deliveries == 1)
        gate.update(enabled: true, active: true, action: focus)
        await drain()
        precondition(deliveries == 2)

        // Leaving before the queued request or a transition completion must
        // never show the keyboard on the previous screen.
        gate.setAppeared(false)
        gate.setAppeared(true)
        gate.setAppeared(false)
        await drain()
        precondition(deliveries == 2)
        let cancelled = gate.beginAnimation()
        gate.setAppeared(true)
        gate.setAppeared(false)
        gate.endAnimation(cancelled)
        await drain()
        precondition(deliveries == 2)

        gate.setAppeared(true)
        gate.update(enabled: true, active: false, action: focus)
        await drain()
        precondition(deliveries == 2, "Inactive scenes cannot open a keyboard")
        gate.update(enabled: true, active: true, action: focus)
        await drain()
        precondition(deliveries == 3)

        // A visible bottom sheet replaces its list with a password form, lays
        // it out, then animates a detent change. The old layout completion must
        // not release the keyboard while that resize is still running.
        let sheet = OathAutofocusPresentation()
        let layout = sheet.begin()
        let observer = sheet.observe { gate.setPresentationReady($0) }
        gate.setAppeared(false)
        gate.setAppeared(true)
        let resize = sheet.begin()
        sheet.end(layout)
        await drain()
        precondition(!sheet.isReady && deliveries == 3)
        sheet.end(resize)
        await drain()
        precondition(sheet.isReady && deliveries == 4)

        // Reduce Motion / no-animation paths need no artificial delay; a new
        // resize arriving before the scheduled callback still blocks it.
        gate.setAppeared(false)
        gate.setAppeared(true)
        let latestResize = sheet.begin()
        await drain()
        precondition(deliveries == 4)
        sheet.end(latestResize)
        await drain()
        precondition(deliveries == 5)

        gate.setAppeared(false)
        gate.setAppeared(true)
        sheet.invalidate()
        await drain()
        precondition(deliveries == 5, "Sheet teardown cancels queued keyboard work")
        sheet.removeObserver(observer)

        gate.setPresentationReady(true)
        gate.invalidate()
        await drain()
        precondition(deliveries == 5)
        // SwiftUI may rebuild the lifecycle bridge while retaining View state.
        gate.activate()
        gate.update(enabled: true, active: true, action: focus)
        gate.setAppeared(true)
        await drain()
        precondition(deliveries == 6)

        var removed: OathAutofocusGate? = OathAutofocusGate()
        weak let weakRemoved = removed
        removed?.update(enabled: true, active: true, action: focus)
        removed?.setAppeared(true)
        removed = nil
        await drain()
        precondition(weakRemoved == nil && deliveries == 6, "Queued requests must not retain removed screens")

        print("PASS: appearance, overlapping animations, deferred delivery, one-shot focus, data loading, navigation cancellation, inactive scenes, sheet resize, Reduce Motion, teardown, bridge recreation and deallocation")
    }

    private static func drain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
