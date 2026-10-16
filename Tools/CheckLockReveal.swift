import Foundation

@main
struct CheckLockReveal {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        var state = LockRevealState()
        check(!state.isRevealing, "A fresh lock must not reveal itself")
        check(state.begin(isForeground: true, isVisible: true) == nil,
              "A foreground scene alone is not successful authentication")
        state.request()
        check(state.begin(isForeground: false, isVisible: true) == nil,
              "Backgrounded or detached scenes must not reveal")
        check(state.phase == .waitingForPresentation, "Offscreen authentication stays pending")
        check(state.begin(isForeground: true, isVisible: false) == nil,
              "A cold-launch lock must wait until it has appeared")
        // Both active PIN success and foreground-inactive Face ID success can
        // begin immediately. No activation callback is needed after request().
        let first = state.begin(isForeground: true, isVisible: true)!
        check(state.phase == .animating, "Successful Face ID must not wait for its finishing UI")
        state.request()
        check(state.begin(isForeground: true, isVisible: true) == nil,
              "Repeated SwiftUI updates must not start overlapping reveals")

        state.suspend()
        check(!state.complete(revision: first), "An offscreen animation must not dismiss the lock")
        check(state.begin(isForeground: false, isVisible: true) == nil,
              "Suspension must not resume while still backgrounded")
        let resumed = state.begin(isForeground: true, isVisible: true)!
        check(!state.complete(revision: first), "A stale completion must not finish a newer reveal")
        check(state.complete(revision: resumed), "Foregrounding must resume the pending authenticated reveal")
        check(!state.complete(revision: resumed), "Dismissal completion must run only once")

        state.cancel()
        check(!state.isRevealing, "Relocking must immediately restore the locked state")
        state.request()
        let interrupted = state.begin(isForeground: true, isVisible: true)!
        state.cancel()
        check(!state.complete(revision: interrupted), "Relocking during the fade invalidates its completion")
        state.request()
        let next = state.begin(isForeground: true, isVisible: true)!
        check(!state.complete(revision: interrupted), "Old authentication cannot dismiss a new lock")
        check(state.complete(revision: next), "A later successful authentication must still reveal normally")

        state.cancel()
        state.request()
        state.cancel()
        check(state.begin(isForeground: true, isVisible: true) == nil,
              "Relocking while awaiting presentation cancels the queued reveal")

        // A stale completion can arrive after a new background lock even when
        // UIKit never started the next animation. Authentication must be fresh.
        check(!state.complete(revision: next), "An old completion cannot dismiss an unauthenticated lock")
        print("Passed \(checks) lock reveal lifecycle checks")
    }
}
