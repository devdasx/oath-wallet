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
        // Only transient failures from the two public rate feeds match this rule.
        if event.sourceFile == "OathExchangeRates/ExchangeRateService.swift",
           ["cdn.jsdelivr.net", "latest.currency-api.pages.dev"].contains(event.context["host"]),
           event.component == "network" || (event.component == "prices" && event.context["stage"] == "feed_request") {
            if event.error.domain == NSURLErrorDomain {
                return [-1001, -1003, -1004, -1005, -1006, -1009, -1018, -1019, -1020].contains(event.error.code)
            }
            if event.error.domain == "Oath.HTTP" || event.error.domain == "Oath.Provider" {
                let status = event.error.domain == "Oath.HTTP" ? event.error.code : Int(event.context["http_status"] ?? "")
                if let status, status == 408 || status == 429 || (500...599).contains(status) { return true }
            }
        }
        // The shared RPC already excludes this exact provider rate limit.
        // Keep the Aptos read client and its sync wrapper from filling the
        // local outbox with copies while the indexer cooldown is active.
        if event.context["chain"] == "aptos",
           event.component != "runtime", event.error.domain == "OathAnkr.AptosError",
           event.error.code == 0, event.error.message == "http(429)",
           ["OathAnkr/AptosClient.swift", "OathDatabase/AptosSynchronizer.swift"].contains(event.sourceFile) {
            return true
        }
        // A null hash lookup starts an independently verified archive read.
        // Terminal lookup failures and invalid receipt evidence still report.
        if event.component == "provider", event.operation == "history_rpc_recovery",
           event.sourceFile == "OathAnkr/IndexedEVMClient.swift",
           ["celo", "filecoin", "sei", "zerog", "iotex"].contains(event.context["chain"]),
           event.error.code == 0, event.error.message == "missingRPCRecord",
           event.error.domain.range(of: #"^OathAnkr\.IndexedEVMClient\.(unknowncontextat[0-9a-f]{1,16}\.)?HistoryAvailability$"#,
                                    options: .regularExpression) != nil { return true }
        return rules.contains { $0.matches(event) }
    }
}
