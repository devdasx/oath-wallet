import Foundation
import OathBitcoin
import OathDatabase
import OathDiagnostics

/// These operations use only the immutable reviewed plan and public metadata.
/// Authentication runs alongside them inside the vault. No signature leaves
/// the vault until both finish, and structured cancellation joins both before
/// the service releases any unsigned reservation.
enum OathSendPreparation {
    static func run(chain: String,
                    reserve: @Sendable () async throws -> Void,
                    validate: @Sendable () async throws -> Void) async throws {
        async let reservation: Void = observed(chain: chain, stage: "reserve", operation: reserve)
        async let validation: Void = observed(chain: chain, stage: "preflight", operation: validate)
        _ = try await (reservation, validation)
    }

    private static func observed(chain: String, stage: String,
                                 operation: @Sendable () async throws -> Void) async throws {
        do { try Task.checkCancellation(); try await operation(); try Task.checkCancellation() }
        catch {
            OathDiagnostics.record(error, component: "send", operation: stage,
                                   context: ["chain": chain, "stage": stage])
            throw error
        }
    }
}

/// All sends use the same outbox/table as every other app feature. The adapter
/// preserves call sites while draining diagnostics queued by older builds.
actor OathSendDiagnostics {
    static let shared = OathSendDiagnostics()
    private var flushing = false
    nonisolated static func isExpectedAuthenticationFallback(_ error: any Error) -> Bool {
        (error as? OathBiometricCredentialError)?.isExpectedAuthenticationOutcome == true
    }
    func record(network: String = "bitcoin", stage: String, error: Error, inputCount: Int = 0,
                file: String = #fileID, function: String = #function, line: UInt = #line) async {
        // Missing/declined biometrics route to the app PIN before signing.
        // Keep this exclusion at authentication; damaged credentials and other
        // send-stage failures still use the shared privacy-filtered outbox.
        if stage == "authenticate", Self.isExpectedAuthenticationFallback(error) { return }
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
        OathDiagnostics.requestFlush()
    }
}
