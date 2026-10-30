import Foundation

/// One scan presentation can hand off only once. Its next flow belongs to the
/// caller, never to the camera cover. Generic payloads stay transient/in memory.
struct OathScannerHandoff<Destination> {
    enum Phase { case idle, scanning, dismissingCamera, destination, finished }
    enum Dismissal { case close, present(Destination) }
    private(set) var phase: Phase = .idle
    private var pending: Destination?

    mutating func begin() -> Bool {
        guard phase == .idle || phase == .finished else { return false }
        phase = .scanning
        return true
    }

    mutating func accept(_ destination: Destination) -> Bool {
        guard phase == .scanning else { return false }
        pending = destination
        phase = .dismissingCamera
        return true
    }

    mutating func cameraDidDismiss(stillPresented: Bool) -> Dismissal? {
        guard phase == .scanning || phase == .dismissingCamera else { return nil }
        let destination = pending
        pending = nil
        if stillPresented, let destination {
            phase = .destination
            return .present(destination)
        }
        phase = .finished
        return .close
    }

    mutating func finishDestination() -> Bool {
        guard phase == .destination else { return false }
        pending = nil
        phase = .finished
        return true
    }

    mutating func rejectDestination() -> Bool {
        guard phase == .destination else { return false }
        phase = .scanning
        return true
    }
}

/// The UI can invalidate a queued camera callback immediately, even while an
/// AVFoundation start/stop call occupies the capture queue. The lock only guards
/// these small values; no camera work or payload processing runs under it.
final class OathScannerCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var generation: UInt64 = 0
    private var delivered = false

    func request(_ active: Bool, retry: Bool = false) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard self.active != active || retry else { return nil }
        self.active = active
        generation &+= 1
        delivered = false
        return generation
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.generation == generation
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    var revision: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    /// Claim the first nonempty QR batch, without retaining any scanned data.
    func claimDelivery() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard active, !delivered else { return nil }
        delivered = true
        return generation
    }
}
