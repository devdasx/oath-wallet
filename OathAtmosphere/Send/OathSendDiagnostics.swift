import Foundation
import OathBitcoin
import OathDatabase
import OathDiagnostics

/// All sends use the same outbox/table as every other app feature. The adapter
/// preserves call sites while draining diagnostics queued by older builds.
actor OathSendDiagnostics {
    static let shared = OathSendDiagnostics()
    private var flushing = false
    func record(network: String = "bitcoin", stage: String, error: Error, inputCount: Int = 0,
                file: String = #fileID, function: String = #function, line: UInt = #line) async {
        OathDiagnostics.record(error, component: "send", operation: stage,
            context: ["chain": network, "stage": stage, "input_count": String(inputCount)],
            file: file, function: function, line: line)
    }
    func flush() async {
        guard !flushing else { return }; flushing = true; defer { flushing = false }
        do {
            let db = try await OathDataEnvironment.shared.database()
            let events = try await db.sendDiagnostics()
            for event in events {
                guard let id = UUID(uuidString: event.id) else { continue }
                let report = DiagnosticEvent(error: DiagnosticFailure(event.code), component: "send", operation: event.stage,
                    context: ["chain": event.network, "stage": event.stage, "input_count": String(event.inputCount), "source": "legacy_queue"],
                    sessionID: id, id: id)
                // Move only after the independent outbox has persisted the report.
                if await OathDiagnostics.enqueuePersisted(report) { try await db.removeSendDiagnostic(id: event.id) }
            }
        } catch { OathDiagnostics.record(error, component: "diagnostics", operation: "migrate_send_queue") }
        await OathDiagnostics.flush()
    }
}
