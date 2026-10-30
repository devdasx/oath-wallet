import Foundation

/// Runs on the Mac host; no app, simulator, GPU or real power setting is used.
@main struct CheckArtworkEnergyNotifications {
    @MainActor private final class Deliveries {
        var count = 0
        func receive() {
            MainActor.assertIsolated()
            dispatchPrecondition(condition: .onQueue(.main))
            count += 1
        }
    }

    @MainActor static func main() async throws {
        let center = NotificationCenter()
        let deliveries = Deliveries()
        let observer = OathArtworkEnergyObserver(center: center) { deliveries.receive() }

        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await wait { deliveries.count == 1 }

        // Exercise the actual Objective-C selector through NotificationCenter,
        // including the off-main delivery that caused the reported crash.
        await Task.detached {
            dispatchPrecondition(condition: .notOnQueue(.main))
            center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
            center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        }.value
        try await wait { deliveries.count == 3 }

        await Task.detached {
            DispatchQueue.concurrentPerform(iterations: 256) { index in
                let name = index.isMultiple(of: 2)
                    ? ProcessInfo.thermalStateDidChangeNotification : .NSProcessInfoPowerStateDidChange
                center.post(name: name, object: nil)
            }
        }.value
        try await wait { deliveries.count == 259 }

        // Queue a callback while MainActor is occupied, then cancel before it
        // can run. It must not update a stopped surface, even if retained.
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        observer.cancel()
        observer.cancel()
        let afterCancel = Deliveries()
        let replacement = OathArtworkEnergyObserver(center: center) { afterCancel.receive() }
        await Task.detached {
            center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        }.value
        try await wait { afterCancel.count == 1 }
        precondition(deliveries.count == 259, "Cancellation must discard queued and future notifications")

        let lifetimeDeliveries = Deliveries()
        var released: OathArtworkEnergyObserver? = OathArtworkEnergyObserver(center: center) {
            lifetimeDeliveries.receive()
        }
        weak let weakObserver = released
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        released = nil
        precondition(weakObserver == nil, "A queued notification must not retain a removed renderer's observer")
        try await wait { afterCancel.count == 2 }
        precondition(lifetimeDeliveries.count == 0, "A released observer must not deliver queued changes")

        // A separate center and unrelated names must not reach this renderer.
        NotificationCenter().post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        center.post(name: Notification.Name("UnrelatedArtworkNotification"), object: nil)
        await Task.detached {
            center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        }.value
        try await wait { afterCancel.count == 3 }
        precondition(deliveries.count == 259 && lifetimeDeliveries.count == 0)
        replacement.cancel()
        print("PASS: main/background energy delivery, 256 concurrent notifications, cancellation, replacement, filtering and deallocation")
    }

    @MainActor private static func wait(until ready: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !ready(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        precondition(ready(), "Energy notifications did not reach MainActor before the deadline")
    }
}
