import Foundation
import Observation

private final class ChangeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func changed() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@main struct CheckRefreshObservation {
    @MainActor static func main() {
        let model = RefreshIndicatorModel()
        let changes = ChangeCount()

        func observe() {
            withObservationTracking { _ = model.cycle } onChange: { changes.changed() }
        }
        observe()
        for _ in 0..<10_000 { model.resetIfNeeded() }
        precondition(changes.value == 0, "A disabled/locked Home must not invalidate itself on every update")

        precondition(model.cycle.begin())
        precondition(changes.value == 1)
        observe()
        model.resetIfNeeded()
        precondition(changes.value == 2 && model.cycle == RefreshCycle(), "An active refresh must cancel once")
        observe()
        for _ in 0..<10_000 { model.resetIfNeeded() }
        precondition(changes.value == 2, "Repeated stop calls must leave observation quiescent")

        var pull = model.cycle
        pull.pull(distance: 24, isDragging: true)
        model.cycle = pull
        precondition(changes.value == 3)
        observe()
        model.resetIfNeeded()
        precondition(changes.value == 4 && model.cycle == RefreshCycle(), "A partial gesture cancels once too")
        print("PASS: idle observation is quiet across 20,000 repeated stops; active and partial refresh cancel once")
    }
}
