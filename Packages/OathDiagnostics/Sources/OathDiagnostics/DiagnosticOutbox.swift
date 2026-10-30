import Foundation

public protocol DiagnosticTransport: Sendable {
    /// Optional event consumer used by tests. The app supplies no consumer.
    func upload(_ events: [DiagnosticEvent]) async throws
}

/// Independent of the wallet database/keychain. Bounded, private, crash-safe
/// snapshots; failed uploads never erase events and never recursively log.
public actor DiagnosticOutbox {
    private let file: URL
    private let transport: (any DiagnosticTransport)?
    private let limit: Int
    private let now: @Sendable () -> Date
    private var pending: [DiagnosticEvent] = []
    private var loaded = false
    private var flushing = false
    private var retry: Task<Void, Never>?
    private var nextAttempt: Date?
    private var failures = 0
    private var writeFailed = false
    public private(set) var dropped = 0
    public init(file: URL, transport: (any DiagnosticTransport)? = nil, limit: Int = 256, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file; self.transport = transport; self.limit = max(2, limit); self.now = now
    }
    private func load() {
        guard !loaded else { return }; loaded = true
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 8 * 1_024 * 1_024 else { throw URLError(.dataLengthExceedsMaximum) }
            pending = try DiagnosticEvent.decoder().decode([DiagnosticEvent].self, from: Data(contentsOf: file))
            // Apply policy to offline events saved by older builds too. These
            // are intentional exclusions, not retention loss to report again.
            let previousCount = pending.count
            pending.removeAll(where: DiagnosticUploadPolicy.excludes)
            let policyChanged = previousCount != pending.count
            // Hard lifetime and capacity bounds even if offline for months.
            expire()
            dropped += max(0, pending.count - limit)
            pending = Array(pending.suffix(limit))
            if policyChanged { persist() }
        } catch is DecodingError {
            // The queue itself contains only filtered diagnostics. Quarantine one
            // corrupt snapshot rather than permanently blocking all future reports.
            quarantine()
        } catch let error as URLError where error.code == .dataLengthExceedsMaximum {
            quarantine()
        } catch {
            // Protected data may be unavailable before first device unlock. Retry
            // loading later instead of overwriting a queue we could not read.
            loaded = false; writeFailed = true
        }
    }
    private func quarantine() {
        do {
            let quarantine = file.appendingPathExtension("corrupt")
            if FileManager.default.fileExists(atPath: quarantine.path) { try FileManager.default.removeItem(at: quarantine) }
            try FileManager.default.moveItem(at: file, to: quarantine)
            pending = []; dropped += 1
        } catch { loaded = false; writeFailed = true }
    }
    private func expire() {
        let current = now(), count = pending.count
        pending.removeAll { current.timeIntervalSince($0.occurredAt) >= 14 * 86_400 || $0.occurredAt.timeIntervalSince(current) > 86_400 }
        dropped += count - pending.count
    }
    @discardableResult public func enqueue(_ event: DiagnosticEvent) -> Bool {
        // A deliberate exclusion is consumed successfully without disk/network
        // work or a replacement diagnostics-loss event.
        guard !DiagnosticUploadPolicy.excludes(event) else { return true }
        load()
        guard loaded else { dropped += 1; scheduleRetry(); return false }
        expire()
        if pending.contains(where: { $0.id == event.id }) {
            if writeFailed { persist() }
            return !writeFailed
        }
        if pending.count >= limit {
            // Acknowledgements remove by ID so enqueueing during upload is safe.
            // Prefer retaining fatal reports and account for bounded loss.
            let index = pending.firstIndex(where: { $0.severity != "fatal" }) ?? 0
            pending.remove(at: index); dropped += 1
        }
        pending.append(event)
        expire()
        persist()
        return !writeFailed
    }
    private func persist() {
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var excluded = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            var data = try DiagnosticEvent.encoder().encode(pending)
            while data.count > 6 * 1_024 * 1_024, !pending.isEmpty {
                pending.removeFirst(); dropped += 1
                data = try DiagnosticEvent.encoder().encode(pending)
            }
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file, options: .atomic)
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            writeFailed = false
        } catch { writeFailed = true } // Keep the in-memory copy; no recursion.
    }
    public func flush(force: Bool = false) async {
        guard !flushing else { return }
        // Newly arriving failures must not bypass an offline/rate-limit backoff.
        if !force, let nextAttempt, now() < nextAttempt { scheduleRetry(); return }
        retry?.cancel(); retry = nil
        nextAttempt = nil
        load()
        guard loaded else { scheduleRetry(); return }
        flushing = true
        defer { flushing = false }
        expire()
        if dropped > 0 {
            let count = dropped; dropped = 0
            let event = DiagnosticEvent(error: DiagnosticFailure("diagnostics_retention_limit"), component: "diagnostics",
                                        operation: "retention", severity: "warning", context: ["count": String(count)], sessionID: UUID())
            _ = enqueue(event)
        }
        if writeFailed { persist() }
        guard let transport else { return }
        for _ in 0..<8 {
            let batch = Array(pending.prefix(10))
            guard !batch.isEmpty else { failures = 0; return }
            do {
                try await transport.upload(batch)
                let sent = Set(batch.map(\.id))
                pending.removeAll { sent.contains($0.id) }
                failures = 0; persist()
            } catch {
                failures = min(failures + 1, 10); scheduleRetry(); return
            }
        }
        if !pending.isEmpty { scheduleRetry() }
    }
    public nonisolated func requestFlush() {
        Task(priority: .utility) { await self.flush(force: true) }
    }
    private func scheduleRetry() {
        guard retry == nil else { return }
        let deadline = nextAttempt ?? now().addingTimeInterval(min(3_600.0, 5 * pow(2, Double(failures))))
        nextAttempt = deadline
        let delay = max(0.05, deadline.timeIntervalSince(now()))
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.retryReady()
        }
    }
    private func retryReady() async { retry = nil; await flush() }
    public func status() -> (pending: Int, writeFailed: Bool, dropped: Int) {
        load(); return (pending.count, writeFailed, dropped)
    }
}

public struct DiagnosticFailure: Error, Sendable, CustomStringConvertible, DiagnosticCausalError {
    public let description: String
    public let diagnosticCause: (any Error)?
    public init(_ description: String, cause: (any Error)? = nil) { self.description = description; diagnosticCause = cause }
}
