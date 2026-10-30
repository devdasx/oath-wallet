/// Visual feedback only: never stores a passcode or changes authentication.
struct OathPasscodeFeedback {
    static let holdDuration: Duration = .milliseconds(600)
    private(set) var revision = 0
    private(set) var isRejecting = false

    mutating func reject() {
        revision &+= 1
        isRejecting = true
    }

    mutating func finish(revision completedRevision: Int) {
        guard completedRevision == revision else { return }
        isRejecting = false
    }

    mutating func reset() { isRejecting = false }
}
