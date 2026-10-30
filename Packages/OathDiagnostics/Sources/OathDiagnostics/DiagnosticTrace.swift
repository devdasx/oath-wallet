import Foundation

/// Code-defined labels only. Never pass a title, wallet name, URL or user input.
public struct DiagnosticTrace: Sendable {
    public let screen: String
    public let action: String
    public let step: String
    public let startedAt: Date
    private let startedUptime: TimeInterval
    private let explicitStep: Bool

    init(screen: String, action: String, step: String, startedAt: Date = Date(),
         startedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime, explicitStep: Bool = false) {
        self.screen = screen; self.action = action; self.step = step
        self.startedAt = startedAt; self.startedUptime = startedUptime; self.explicitStep = explicitStep
    }
    func stepping(_ step: String) -> Self {
        .init(screen: screen, action: action, step: step, startedAt: startedAt, startedUptime: startedUptime, explicitStep: true)
    }
    var hasExplicitStep: Bool { explicitStep }
    var context: [String: String] {
        ["origin_screen": screen, "action": action, "step": step,
         "action_started_at": ISO8601DateFormatter().string(from: startedAt),
         "elapsed_ms": String(Int(min(86_400_000, max(0, (ProcessInfo.processInfo.systemUptime - startedUptime) * 1_000))))]
    }
}

/// Bounded, in-memory observations. They describe what was visible at failure
/// time; origin_screen separately identifies where a traced action began.
final class DiagnosticPresentationState: @unchecked Sendable {
    private let lock = NSLock()
    private var screens: [(UUID, String)] = []
    private var lifecycle = "unknown"
    func appear(_ id: UUID, screen: String) {
        lock.withLock {
            screens.removeAll { $0.0 == id }
            screens.append((id, screen))
            if screens.count > 64 { screens.removeFirst(screens.count - 64) }
        }
    }
    func disappear(_ id: UUID) { lock.withLock { screens.removeAll { $0.0 == id } } }
    func setLifecycle(_ value: String) { lock.withLock { lifecycle = value } }
    func snapshot() -> [String: String] {
        lock.withLock {
            ["screen": screens.last?.1 ?? "unknown", "screen_source": screens.isEmpty ? "unknown" : "visible_view",
             "app_state": lifecycle]
        }
    }
}

extension OathDiagnostics {
    @TaskLocal public static var trace: DiagnosticTrace?
    private static let presentation = DiagnosticPresentationState()

    public enum Lifecycle: String, Sendable { case active, inactive, background }
    public static func setLifecycle(_ phase: Lifecycle) { presentation.setLifecycle(phase.rawValue) }
    public static func screenAppeared(_ token: UUID, file: StaticString = #fileID, line: UInt = #line) {
        presentation.appear(token, screen: DiagnosticPrivacy.identifier("\(file):\(line)"))
    }
    public static func screenDisappeared(_ token: UUID) { presentation.disappear(token) }

    /// Child Tasks inherit this action's ID and origin, even after navigation.
    /// Detached tasks/native callbacks must explicitly carry a captured trace.
    public static func withAction<T>(file: StaticString = #fileID, function: StaticString = #function,
                                     line: UInt = #line, body: () throws -> T) rethrows -> T {
        let source = DiagnosticPrivacy.identifier("\(file):\(function):\(line)")
        let scope = DiagnosticTrace(screen: presentation.snapshot()["screen"] ?? "unknown", action: source, step: source)
        return try $operationID.withValue(UUID()) { try $trace.withValue(scope, operation: body) }
    }
    public static func withStep<T>(_ step: StaticString, isolation: isolated (any Actor)? = #isolation,
                                    body: () async throws -> T) async rethrows -> T {
        try await withNamedStep(String(describing: step), body: body)
    }
    static func withNamedStep<T>(_ step: String, isolation: isolated (any Actor)? = #isolation,
                                 body: () async throws -> T) async rethrows -> T {
        let scope = (trace ?? DiagnosticTrace(screen: presentation.snapshot()["screen"] ?? "unknown", action: step, step: step)).stepping(step)
        return try await $trace.withValue(scope) { try await body() }
    }
    static func withNamedStep<T>(_ step: String, body: () throws -> T) rethrows -> T {
        let scope = (trace ?? DiagnosticTrace(screen: presentation.snapshot()["screen"] ?? "unknown", action: step, step: step)).stepping(step)
        return try $trace.withValue(scope, operation: body)
    }
    static func failureContext(_ supplied: [String: String], operation: String, function: String) -> [String: String] {
        // Apple delivers reports later: today's screen is not the crash screen.
        if supplied["source"] == "MetricKit" {
            return supplied.merging(["screen": "unknown", "origin_screen": "unknown", "screen_source": "historical_report",
                                     "app_state": "unknown", "action": operation, "step": function,
                                     "step_source": "report_delivery", "time_source": "metrickit_payload_end"]) { _, new in new }
        }
        var result = presentation.snapshot()
        if let trace { result.merge(trace.context) { _, new in new } }
        result.merge(supplied) { _, new in new }
        if result["action"] == nil { result["action"] = operation }
        if let stage = supplied["stage"], supplied["step"] == nil { result["step"] = stage }
        else if trace?.hasExplicitStep != true && supplied["step"] == nil { result["step"] = function }
        if result["origin_screen"] == nil { result["origin_screen"] = "unknown" }
        result["step_source"] = supplied["stage"] != nil ? "explicit_stage" : (trace?.hasExplicitStep == true ? "traced_step" : "source_function")
        return result
    }
}
