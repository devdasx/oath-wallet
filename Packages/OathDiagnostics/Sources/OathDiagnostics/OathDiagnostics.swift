import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

public enum OathDiagnostics {
    @TaskLocal public static var chain: String?
    @TaskLocal public static var operationID: UUID?
    /// Scope a known network at the client boundary, before shared transports
    /// report failures. Retain a caller's correlation across retries/fallbacks;
    /// independent calls get distinct IDs. Task locals restore on every exit.
    public static func withChain<Value>(_ network: String, isolation: isolated (any Actor)? = #isolation,
                                        operation: () async throws -> Value) async rethrows -> Value {
        try await $chain.withValue(network) {
            try await $operationID.withValue(operationID ?? UUID()) {
                try await operation()
            }
        }
    }
    private static let state = State()
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var outbox: DiagnosticOutbox?
        let sessionID = UUID()
        var queued = 0
        var overflow = 0
        // State is accessed only under lock; enqueue admission is bounded before
        // allocating asynchronous work, so reporting cannot freeze the app.
    }
    public static func configure(file: URL, transport: (any DiagnosticTransport)? = nil) {
        let box: DiagnosticOutbox = state.lock.withLock {
            if let box = state.outbox { return box }
            let box = DiagnosticOutbox(file: file, transport: transport); state.outbox = box; return box
        }
        box.requestFlush()
    }
    public static func record(_ error: any Error, component: String? = nil, operation: String? = nil,
                              severity: String = "error", context: [String: String] = [:],
                              runtimeReport: String? = nil, occurredAt: Date = Date(),
                              file: String = #fileID, function: String = #function, line: UInt = #line) {
        if isExpectedCancellation(error) || error is DiagnosticDeferral
            || (error as? any DiagnosticControlFlowError)?.isExpectedDiagnosticControlFlow == true { return }
        // Excluded traffic must not consume admission slots or displace real
        // failures before the worker applies the complete persisted-event policy.
        if DiagnosticAvailabilityPolicy.excludesBeforeAdmission(error, component: component, severity: severity,
                                                                context: context, runtimeReport: runtimeReport) { return }
        let admission: (DiagnosticOutbox, Int)? = state.lock.withLock {
            guard let box = state.outbox else { return nil }
            guard state.queued < 64 else { state.overflow += 1; return nil }
            state.queued += 1; let dropped = state.overflow; state.overflow = 0
            return (box, dropped)
        }
        guard let (box, dropped) = admission else { return }
        var context = context
        if context["chain"] == nil {
            context["chain"] = chain
            if context["chain"] == nil {
                let source = file.components(separatedBy: "/").last?.lowercased().replacingOccurrences(of: "oath", with: "") ?? ""
                context["chain"] = ["thorchain", "bitcoincash", "dogecoin", "litecoin", "solana", "aptos", "polkadot", "stellar", "chiliz", "filecoin", "sei", "zerog", "iotex", "celo", "monad", "unichain", "hyperevm", "robinhood", "xrpl", "near", "tron", "ton", "sui", "arc"].first {
                    source.hasPrefix($0) || function.lowercased().hasPrefix("refresh" + $0)
                }
            }
        }
        let eventContext = failureContext(context, operation: operation ?? function, function: function)
        let eventComponent = component ?? inferredComponent(file)
        let eventOperation = operation ?? function
        let correlationID = operationID ?? UUID()
        Task.detached(priority: .utility) {
            // Redaction and large MetricKit stack processing must never occupy
            // the caller's main actor. Capture task-local correlation beforehand.
            let event = DiagnosticEvent(error: error, component: eventComponent,
                operation: eventOperation, severity: severity, context: eventContext,
                runtimeReport: runtimeReport, sessionID: state.sessionID, operationID: correlationID,
                occurredAt: occurredAt, file: file, function: function, line: line)
            _ = await box.enqueue(event)
            if dropped > 0 {
                _ = await box.enqueue(DiagnosticEvent(error: DiagnosticFailure("diagnostics_queue_overflow"),
                    component: "diagnostics", operation: "admission", severity: "warning", context: ["count": String(dropped)],
                    sessionID: state.sessionID))
            }
            state.lock.withLock { state.queued -= 1 }
            await box.flush()
        }
    }
    /// Report a validation rejection at its exact guard, then throw the SAME
    /// typed error. Static reasons describe code conditions, never response data.
    public static func failure<E: Error>(_ error: E, reason: StaticString,
                                         file: String = #fileID, function: String = #function, line: UInt = #line) -> E {
        record(error, operation: function, context: ["stage": "response_validation", "reason": String(describing: reason)],
               file: file, function: function, line: line)
        return error
    }

    /// Only explicit cancellation/fallback outcomes are excluded. An invalid
    /// context, failed authentication or Keychain failure remains reportable.
    public static func isExpectedCancellation(_ error: any Error) -> Bool {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return true }
        // Native Cocoa callbacks (including alternate app icons) report user
        // cancellation as NSCocoaErrorDomain/3072, not CancellationError.
        // Match the outer domain/code only; underlying cancellations must not
        // conceal a failed storage or authentication operation.
        if (error as? CocoaError)?.code == .userCancelled { return true }
        #if canImport(LocalAuthentication)
        if let authentication = error as? LAError {
            switch authentication.code {
            case .userCancel, .userFallback, .appCancel, .systemCancel: return true
            default: break
            }
        }
        #endif
        return false
    }
    private static func inferredComponent(_ file: String) -> String {
        let value = file.lowercased()
        let groups: [(String, [String])] = [
            ("artwork", ["artwork", "renderer", "tokenimages"]),
            ("backup_restore", ["cloud", "backuppassword"]),
            ("send", ["send"]), ("authentication", ["passcode", "biometric", "unlock"]),
            ("sync", ["synchronizer", "sync", "electrum"]), ("prices", ["market", "exchangerate"]),
            ("address_book", ["contact"]), ("settings", ["settings", "preferences", "security", "reset"]),
            ("wallet", ["wallet", "recovery", "privatekey", "vault", "installation"]),
            ("storage", ["database"]), ("provider", ["ankr"])
        ]
        return groups.first { $0.1.contains(where: value.contains) }?.0 ?? file.components(separatedBy: "/").first ?? "app"
    }
    @discardableResult public static func enqueuePersisted(_ event: DiagnosticEvent) async -> Bool {
        let box = state.lock.withLock { state.outbox }
        return await box?.enqueue(event) ?? false
    }
    public static func flush() async {
        let box = state.lock.withLock { state.outbox }
        // Explicit lifecycle resumption may retry immediately; record() respects
        // backoff so a burst of failures never creates a burst of upload attempts.
        await box?.flush(force: true)
    }
    /// App/lifecycle callers only schedule delivery. Awaitable flush is for
    /// background workers and deterministic tests, never foreground readiness.
    public static func requestFlush() {
        let box = state.lock.withLock { state.outbox }
        box?.requestFlush()
    }
    public static func attemptOptional<T>(_ operation: String, isolation: isolated (any Actor)? = #isolation,
                                          file: String = #fileID, function: String = #function,
                                          line: UInt = #line, body: () async throws -> T?) async -> T? {
        await $operationID.withValue(operationID ?? UUID()) {
            return await withNamedStep(operation) {
                do { return try await body() }
                catch { record(error, operation: operation, file: file, function: function, line: line); return nil }
            }
        }
    }
    /// A named, best-effort operation replaces silent `try?` at failure boundaries.
    /// Own correlation outside the body: an inner provider/chain scope has
    /// already unwound when this boundary records a terminal failure. Preserve
    /// an existing caller's ID; independent operations receive a fresh one.
    public static func attempt<T>(_ operation: String, file: String = #fileID, function: String = #function,
                                  line: UInt = #line, body: () throws -> T) -> T? {
        $operationID.withValue(operationID ?? UUID()) {
            return withNamedStep(operation) {
                do { return try body() }
                catch { record(error, operation: operation, file: file, function: function, line: line); return nil }
            }
        }
    }
    public static func attempt<T>(_ operation: String, isolation: isolated (any Actor)? = #isolation,
                                  file: String = #fileID, function: String = #function,
                                  line: UInt = #line, body: () async throws -> T) async -> T? {
        await $operationID.withValue(operationID ?? UUID()) {
            return await withNamedStep(operation) {
                do { return try await body() }
                catch { record(error, operation: operation, file: file, function: function, line: line); return nil }
            }
        }
    }
}
