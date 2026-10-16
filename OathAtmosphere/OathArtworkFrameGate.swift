import Foundation

/// No semaphore waits and no frame backlog. A busy GPU keeps its last complete
/// frame while UIKit can continue processing the next touch/scroll update.
/// Generation tickets discard work captured before backgrounding or teardown.
final class OathArtworkFrameGate: @unchecked Sendable {
    struct Ticket: Equatable, Sendable {
        fileprivate let generation: UInt64
        fileprivate let frame: UInt64
    }

    private let lock = NSLock()
    private var enabled = false
    private var generation: UInt64 = 0
    private var frame: UInt64 = 0
    private var pending: Ticket?

    func setEnabled(_ enabled: Bool) {
        lock.withLock {
            guard self.enabled != enabled else { return }
            self.enabled = enabled
            generation &+= 1
            // Keep the pending slot until its worker/GPU completes. Resuming
            // must not queue new work behind an older blocked drawable request.
        }
    }

    func begin() -> Ticket? {
        lock.withLock {
            guard enabled, pending == nil else { return nil }
            frame &+= 1
            let ticket = Ticket(generation: generation, frame: frame)
            pending = ticket
            return ticket
        }
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        lock.withLock { enabled && generation == ticket.generation && pending == ticket }
    }

    func finish(_ ticket: Ticket) {
        lock.withLock {
            if pending == ticket { pending = nil }
        }
    }
}
