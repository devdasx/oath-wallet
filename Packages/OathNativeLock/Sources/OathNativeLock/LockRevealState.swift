/// Successful authentication can reveal a visible foreground scene even while
/// Local Authentication is finishing its UI. Inactive is not backgrounded.
/// Revisions invalidate completions from animations interrupted by a relock.
struct LockRevealState {
    enum Phase { case locked, waitingForPresentation, animating, revealed }
    private(set) var phase: Phase = .locked
    private var revision: UInt = 0

    var isRevealing: Bool { phase != .locked }

    mutating func request() {
        guard phase == .locked else { return }
        revision &+= 1
        phase = .waitingForPresentation
    }

    mutating func begin(isForeground: Bool, isVisible: Bool) -> UInt? {
        guard phase == .waitingForPresentation, isForeground, isVisible else { return nil }
        phase = .animating
        return revision
    }

    mutating func suspend() {
        guard phase == .animating else { return }
        revision &+= 1
        phase = .waitingForPresentation
    }

    mutating func complete(revision: UInt) -> Bool {
        guard phase == .animating, revision == self.revision else { return false }
        phase = .revealed
        return true
    }

    mutating func cancel() {
        revision &+= 1
        phase = .locked
    }
}
