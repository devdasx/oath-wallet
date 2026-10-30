import Foundation
import UIKit
import MetricKit
import OathDiagnostics

/// Apple owns crash capture; never install unsafe Swift POSIX signal handlers.
/// Payloads arrive later, often on a subsequent launch, not at crash time.
final class OathDiagnosticsRuntime: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = OathDiagnosticsRuntime()
    @MainActor private var started = false
    @MainActor private var launchReported = false
    @MainActor private var observers: [NSObjectProtocol] = []
    #if !DEBUG
    private let watchdog = DiagnosticWatchdog { @Sendable duration in
        OathDiagnostics.record(DiagnosticFailure("Main run loop did not respond for at least two seconds"),
            component: "runtime", operation: "foreground_stall", severity: "warning",
            context: ["duration_ms": String(Int(duration * 1000))])
    }
    @MainActor private var heartbeat: Timer?
    #endif
    private let launchTime = ProcessInfo.processInfo.systemUptime

    @MainActor func start() {
        guard !started, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        started = true
        let file = URL.applicationSupportDirectory.appendingPathComponent("OathDiagnostics", isDirectory: true)
            .appendingPathComponent("outbox-v1.json")
        OathDiagnostics.configure(file: file)
        MXMetricManager.shared.add(self)
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { @Sendable [weak self] _ in
            #if !DEBUG
            self?.watchdog.setActive(true)
            #endif
            OathDiagnostics.requestFlush()
        })
        #if !DEBUG
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { @Sendable [weak self] _ in
            self?.watchdog.setActive(false)
        })
        #endif
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { @Sendable _ in
            OathDiagnostics.record(DiagnosticFailure("iOS memory pressure warning"), component: "runtime", operation: "memory_pressure", severity: "warning")
        })
        // Do not install either timer in Debug: debugger pauses are not hangs.
        // MetricKit remains registered in Debug for explicit developer testing.
        #if !DEBUG
        // A single main-run-loop heartbeat plus one utility timer. Never enqueue
        // a new main-thread block on every watchdog tick while the main is stuck.
        let watchdog = self.watchdog
        let timer = Timer(timeInterval: 0.25, repeats: true) { @Sendable _ in watchdog.beat() }
        RunLoop.main.add(timer, forMode: .common); heartbeat = timer
        watchdog.start()
        watchdog.setActive(UIApplication.shared.applicationState == .active)
        #endif
    }
    @MainActor func launchReady() {
        guard !launchReported else { return }
        launchReported = true
        let duration = ProcessInfo.processInfo.systemUptime - launchTime
        if duration > 5 {
            OathDiagnostics.record(DiagnosticFailure("Local startup exceeded five seconds"), component: "runtime",
                operation: "slow_launch", severity: "warning", context: ["duration_ms": String(Int(duration * 1000))])
        }
    }
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for report in payload.crashDiagnostics ?? [] { record(report, category: "crash", fatal: true, date: payload.timeStampEnd) }
            for report in payload.hangDiagnostics ?? [] { record(report, category: "hang", date: payload.timeStampEnd) }
            for report in payload.cpuExceptionDiagnostics ?? [] { record(report, category: "cpu_exception", date: payload.timeStampEnd) }
            for report in payload.diskWriteExceptionDiagnostics ?? [] { record(report, category: "disk_write_exception", date: payload.timeStampEnd) }
            for report in payload.appLaunchDiagnostics ?? [] { record(report, category: "app_launch", date: payload.timeStampEnd) }
        }
    }
    private func record(_ report: MXDiagnostic, category: String, fatal: Bool = false, date: Date) {
        // The shared runtime privacy filter alone owns the allowlist. Raw Apple
        // payloads are never persisted or uploaded before that filter runs.
        let data = report.jsonRepresentation()
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            OathDiagnostics.record(DiagnosticFailure("Apple MetricKit report exceeded the diagnostic size limit"), component: "runtime",
                operation: category, severity: fatal ? "fatal" : "warning", context: ["source": "MetricKit"], occurredAt: date)
            return
        }
        OathDiagnostics.record(DiagnosticFailure("Apple MetricKit " + category), component: "runtime", operation: category,
            severity: fatal ? "fatal" : "warning", context: ["source": "MetricKit"], runtimeReport: text, occurredAt: date)
    }
}
