import Foundation
import Dispatch

/// Observes a main-run-loop heartbeat without ever scheduling work on that run
/// loop. All mutable state is protected by `lock`; callbacks run outside it.
public final class DiagnosticWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var state = DiagnosticWatchdogState()
    private var timer: DispatchSourceTimer?
    private var generation = UUID()
    private let threshold: TimeInterval
    private let interval: DispatchTimeInterval
    private let leeway: DispatchTimeInterval
    private let onStall: @Sendable (TimeInterval) -> Void

    public convenience init(onStall: @escaping @Sendable (TimeInterval) -> Void) {
        self.init(threshold: 2, interval: .seconds(1), leeway: .milliseconds(200), onStall: onStall)
    }

    // Internal timing controls let host tests exercise the production callback
    // registration without waiting for a multi-second main-thread stall.
    init(threshold: TimeInterval, interval: DispatchTimeInterval, leeway: DispatchTimeInterval,
         onStall: @escaping @Sendable (TimeInterval) -> Void) {
        self.threshold = threshold
        self.interval = interval
        self.leeway = leeway
        self.onStall = onStall
    }

    public nonisolated func start() {
        lock.withLock {
            guard timer == nil else { return }
            state.beat(at: ProcessInfo.processInfo.systemUptime)
            let generation = UUID()
            self.generation = generation
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(
                label: "org.oathwallet.diagnostics.watchdog", qos: .utility))
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
            // Dispatch invokes this synchronously on its utility queue. Never
            // inherit MainActor isolation from the app's startup method.
            timer.setEventHandler { @Sendable [weak self] in
                self?.checkStall(generation: generation)
            }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        let previous = lock.withLock {
            let previous = timer
            timer = nil
            state.setActive(false, at: ProcessInfo.processInfo.systemUptime)
            return previous
        }
        // An already-executing report may finish; stale queued callbacks cannot
        // change the state of a subsequently restarted watchdog.
        previous?.cancel()
    }

    public func setActive(_ active: Bool) {
        lock.withLock { state.setActive(active, at: ProcessInfo.processInfo.systemUptime) }
    }

    public func beat() {
        lock.withLock { state.beat(at: ProcessInfo.processInfo.systemUptime) }
    }

    private func checkStall(generation: UUID) {
        let duration = lock.withLock { () -> TimeInterval? in
            guard timer != nil, self.generation == generation else { return nil }
            return state.stallDuration(at: ProcessInfo.processInfo.systemUptime, threshold: threshold)
        }
        if let duration { onStall(duration) }
    }

    deinit { timer?.cancel() }
}

/// Pure monotonic-time state machine, kept separate from timer scheduling so
/// foreground/background transitions and report suppression are deterministic.
struct DiagnosticWatchdogState {
    private var active = false
    private var lastBeat: TimeInterval = 0
    private var reportedStall = false

    mutating func setActive(_ active: Bool, at uptime: TimeInterval) {
        self.active = active
        beat(at: uptime)
    }

    mutating func beat(at uptime: TimeInterval) {
        lastBeat = uptime
        reportedStall = false
    }

    mutating func stallDuration(at uptime: TimeInterval, threshold: TimeInterval) -> TimeInterval? {
        let elapsed = uptime - lastBeat
        guard active, elapsed >= threshold, !reportedStall else { return nil }
        reportedStall = true
        return elapsed
    }
}
