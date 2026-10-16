import Foundation

@main struct CheckArtworkScheduling {
    static func main() {
        let gate = OathArtworkFrameGate()
        precondition(gate.begin() == nil, "A background/stopped surface must not render")
        gate.setEnabled(true)
        let first = gate.begin()!
        precondition(gate.isCurrent(first))
        // Simulate a drawable/GPU that stays busy while many display ticks arrive.
        // Every tick must return immediately without adding work to a queue.
        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in
            precondition(gate.begin() == nil, "Only one frame may be outstanding")
        }
        gate.setEnabled(false)
        precondition(!gate.isCurrent(first))
        gate.setEnabled(true)
        precondition(gate.begin() == nil, "Resume must not build a backlog behind old work")
        gate.finish(first)
        let resumed = gate.begin()!
        precondition(resumed != first && gate.isCurrent(resumed))
        gate.finish(first)
        precondition(gate.begin() == nil, "A stale completion cannot release a new frame")
        gate.finish(resumed)
        let next = gate.begin()!
        precondition(next != resumed, "Every frame needs a unique ticket, even without a lifecycle change")
        gate.finish(resumed)
        precondition(gate.begin() == nil, "A delayed completion cannot free a newer frame in the same generation")
        gate.setEnabled(false)
        precondition(!gate.isCurrent(next), "A queued callback must be invalidated before it reaches a backgrounded view")
        gate.finish(next)
        precondition(gate.begin() == nil)
        print("PASS: bounded frame scheduling, 10,000 concurrent busy ticks, pause/resume and stale completions")
    }
}
