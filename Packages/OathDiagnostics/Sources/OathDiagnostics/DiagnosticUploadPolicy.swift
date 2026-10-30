import Foundation

/// User-requested exclusions for the 12 issue groups reviewed on 2026-10-22.
/// This controls telemetry only, never retry, authentication or wallet behavior.
/// The later availability exclusion applies across services/chains; the older
/// rules remain narrowly matched. Fatal/runtime and other app errors stay eligible.
enum DiagnosticUploadPolicy {
    struct Rule: Decodable, Sendable {
        let component: String
        let operation: String
        let domain: String
        let code: Int
        let chain: String
        let host: String
        let method: String
        let messagePrefix: String

        func matches(_ event: DiagnosticEvent) -> Bool {
            event.component == component && event.operation == operation &&
            event.error.domain == domain && event.error.code == code &&
            (event.context["chain"] ?? "") == chain &&
            (event.context["host"] ?? "") == host &&
            (event.context["method"] ?? "") == method &&
            (messagePrefix.isEmpty || event.error.message.hasPrefix(messagePrefix))
        }
    }

    static let rules: [Rule] = {
        // Fail open if a shipped resource is missing/corrupt: never silently
        // disable diagnostics. Host tests verify every bundled rule decodes.
        guard let url = Bundle.module.url(forResource: "reviewed-upload-exclusions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode([Rule].self, from: data) else { return [] }
        return rules
    }()

    static func excludes(_ event: DiagnosticEvent) -> Bool {
        if DiagnosticAvailabilityPolicy.excludes(event) { return true }
        return excludesReviewed(event)
    }

    static func excludesReviewed(_ event: DiagnosticEvent) -> Bool {
        guard event.severity != "fatal", event.runtimeReport == nil,
              event.context["chain"] != "arc", event.context["chain"] != "robinhood" else { return false }
        return rules.contains { $0.matches(event) }
    }
}
