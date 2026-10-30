import Foundation
#if canImport(Network)
import Network
#endif

/// Typed, constant-time classification before reporter admission. Implementations
/// must inspect only enum cases/codes, never format error payloads or do I/O.
public protocol DiagnosticAvailabilityError: Error {
    var isDiagnosticAvailabilityFailure: Bool { get }
}

/// User-requested telemetry exclusions (2026-10-25). This never changes retry,
/// validation, trust evaluation, signing, or the error returned to the caller.
/// Match protocol codes and known domain cases, not arbitrary error prose.
enum DiagnosticAvailabilityPolicy {
    static func excludesBeforeAdmission(_ error: any Error, component: String?, severity: String,
                                        context: [String: String], runtimeReport: String?) -> Bool {
        guard severity != "fatal", runtimeReport == nil, component != "runtime" else { return false }
        if retainsSendFailure(component: component, context: context) { return false }
        if let typed = error as? any DiagnosticAvailabilityError {
            return typed.isDiagnosticAvailabilityFailure
        }
        #if canImport(Network)
        if let network = error as? NWError, case .posix(let code) = network {
            return socketCodes.contains(Int(code.rawValue))
        }
        #endif
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return urlCodes.contains(ns.code) }
        if ns.domain == NSPOSIXErrorDomain { return socketCodes.contains(ns.code) }
        if ns.domain == "Oath.HTTP" { return unavailableStatus(ns.code) }
        if ns.domain == "Oath.Provider" || (component == "network" && ns.domain == "OathDiagnostics.DiagnosticFailure") {
            if let status = context["http_status"].flatMap(Int.init), unavailableStatus(status) { return true }
        }
        if ns.domain == "Oath.Provider" {
            if ns.code == 429 || ns.code == -32005 { return true }
            if stalePublicQuote(code: ns.code, message: ns.userInfo[NSLocalizedDescriptionKey] as? String, context: context) { return true }
            if historyProviderAvailability(code: ns.code, message: ns.userInfo[NSLocalizedDescriptionKey] as? String, context: context) { return true }
            // Inspect at most 512 public provider-message characters. Do not
            // traverse underlying errors, stringify userInfo, or run redaction
            // on the caller's actor. Full filtering remains on the worker.
            return (ns.userInfo[NSLocalizedDescriptionKey] as? String).map(providerAvailability) ?? false
        }
        return false
    }

    static func excludes(_ event: DiagnosticEvent) -> Bool {
        guard event.severity != "fatal", event.runtimeReport == nil, event.component != "runtime" else { return false }
        if retainsSendFailure(component: event.component, context: event.context) { return false }
        let error = event.error
        // Serialized SDK timeouts (including older outboxes) are availability
        // failures. Match the complete known case, never a timeout substring.
        if error.domain == "WalletConnectRelay.RelayError", error.message == "requestTimeout" { return true }
        if error.domain == NSURLErrorDomain {
            return urlCodes.contains(error.code)
        }
        if error.domain == NSPOSIXErrorDomain { return socketCodes.contains(error.code) }
        // NWError also carries DNS/TLS codes. Require the serialized POSIX
        // case and matching errno; never classify this domain by code alone.
        if error.domain == "Network.NWError", socketCodes.contains(error.code),
           error.message.hasPrefix("POSIXErrorCode(rawValue: \(error.code)): ") { return true }
        if error.domain == "Oath.HTTP" { return unavailableStatus(error.code) }

        let provider = error.domain == "Oath.Provider"
        if provider || (event.component == "network" && error.domain == "OathDiagnostics.DiagnosticFailure") {
            if let status = event.context["http_status"].flatMap(Int.init), unavailableStatus(status) { return true }
        }
        if provider {
            // -32005 is the provider limit-exceeded code. Generic -32000 and
            // -32603 also represent execution/schema bugs and must not be dropped.
            if error.code == 429 || error.code == -32005 { return true }
            if stalePublicQuote(code: error.code, message: error.message, context: event.context) { return true }
            if historyProviderAvailability(code: error.code, message: error.message, context: event.context) { return true }
            return providerAvailability(error.message)
        }

        if error.domain.hasPrefix("OathAnkr.") || error.domain.hasPrefix("OathBitcoin.")
            || error.domain == "OathMarketData.MarketDataError" || error.domain == "OathTokenImages.ArtworkError" {
            // Swift enum codes are not stable; use the complete known case.
            if error.message.range(of: #"^http\([0-9]{3}\)$"#, options: .regularExpression) != nil,
               let status = Int(error.message.dropFirst(5).dropLast()), unavailableStatus(status) { return true }
        }
        if error.domain.hasPrefix("OathAnkr."), transportDomains.contains(error.domain), error.message == "transport" { return true }
        if error.domain.hasPrefix("OathAnkr."), ["rpc(429)", "rpc(-32005)"].contains(error.message) { return true }
        // Older incompleteHistory reports lack a validated positive ledger; retain them.
        if ["OathAnkr.XrplError", "OathAnkr.XrplSendError"].contains(error.domain),
           ["rpc(tooBusy)", "rpc(slowDown)", "rpc(noNetwork)"].contains(error.message) { return true }
        switch (error.domain, error.message) {
        case ("OathAnkr.ThorchainError", "rateLimited"), ("OathAnkr.SuiError", "resourceExhausted"),
             ("OathAnkr.SuiError", "checkpointUnavailable"), ("OathAnkr.StellarError", "indexUnavailable"),
             ("OathAnkr.SolanaError", "rpc(-32019)"),
             ("OathMarketData.MarketDataError", "rateLimited"), ("OathMarketData.MarketDataError", "unavailable"),
             ("OathAnkr.TokenDiscoveryError", "unavailable"),
             ("OathBitcoin.BitcoinError", "timeout"), ("OathBitcoin.BitcoinError", "disconnected"),
             ("OathBitcoin.BitcoinError", "tls"), ("OathBitcoin.BitcoinError", "unavailable"):
            return true
        default: return false
        }
    }

    // Preserve exhausted send failures at the service boundary. Intermediate
    // provider availability failures still use the normal exclusion policy.
    private static func retainsSendFailure(component: String?, context: [String: String]) -> Bool {
        let stages = ["quote", "reserve", "authenticate", "persist", "broadcast", "permission_recheck", "multisig_preflight", "status"]
        let supported = component == "evm_send" && ["chiliz", "chilizSpicy", "sei", "seiTestnet", "zerog", "zerogGalileo", "iotex", "iotexTestnet"].contains(context["chain"] ?? "")
            || component == "polkadot_send" && context["chain"] == "polkadot"
        return supported && stages.contains(context["stage"] ?? "")
    }

    // Preserve only these public enum codes before quoted-value redaction.
    // Arbitrary RPC messages still pass through the full privacy filter.
    static func normalizedPublicCode(domain: String, message: String) -> String? {
        guard ["OathAnkr.XrplError", "OathAnkr.XrplSendError"].contains(domain) else { return nil }
        switch message {
        case #"rpc("tooBusy")"#: return "rpc(tooBusy)"
        case #"rpc("slowDown")"#: return "rpc(slowDown)"
        case #"rpc("noNetwork")"#: return "rpc(noNetwork)"
        default: return nil
        }
    }

    private static func unavailableStatus(_ code: Int) -> Bool {
        code == 408 || code == 429 || (500...599).contains(code)
    }
    // Exact public-provider envelope retained by older app versions. Never infer
    // availability from a bare 404, generic RPC code 5 or another host's message.
    private static func stalePublicQuote(code: Int, message: String?, context: [String: String]) -> Bool {
        code == 5 && context["host"] == "api.coinbase.com" && context["http_status"] == "404" &&
        message == "rpc error: code = NotFound desc = rate found but was stale"
    }
    private static func historyProviderAvailability(code: Int, message: String?, context: [String: String]) -> Bool {
        guard context["http_status"] == "200", let message, message.utf8.prefix(101).count <= 100 else { return false }
        if context["chain"] == "sui", code == -1,
           ["rpc.ankr.com", "graphql.mainnet.sui.io"].contains(context["host"] ?? ""),
           message.hasPrefix("Checkpoint "), message.hasSuffix(" in the future") {
            let text = String(message.dropFirst(11).dropLast(14))
            guard let checkpoint = UInt64(text), checkpoint > 0, checkpoint <= 9_007_199_254_740_991,
                  String(checkpoint) == text else { return false }
            return true
        }
        return context["chain"] == "solana" && code == -32019 &&
            ["rpc.ankr.com", "api.mainnet-beta.solana.com"].contains(context["host"] ?? "") &&
            ["getSignaturesForAddress", "getTransaction", "getBlock"].contains(context["method"] ?? "") &&
            message == "Failed to query long-term storage; please try again"
    }
    private static let urlCodes = Set([
        URLError.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
        .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff, .callIsActive,
        .dataNotAllowed, .secureConnectionFailed, .serverCertificateHasBadDate,
        .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
        .clientCertificateRejected, .clientCertificateRequired
    ].map(\.rawValue))
    private static let socketCodes = Set([
        POSIXErrorCode.ENETDOWN, .ENETUNREACH, .ECONNABORTED, .ECONNRESET, .ENOTCONN,
        .ETIMEDOUT, .ECONNREFUSED, .EHOSTDOWN, .EHOSTUNREACH
    ].map { Int($0.rawValue) })
    private static let transportDomains = Set([
        "AnkrError", "SolanaError", "AptosError", "TonError", "TronError", "StellarError",
        "XrplError", "NearError", "SuiError", "ThorchainError", "EVMSendError", "SolanaSendError",
        "AptosSendError", "TonSendError", "TronSendError", "StellarSendError", "XrplSendError",
        "NearSendError", "SuiSendError", "ThorchainSendError", "ArcSendError", "RobinhoodSendError"
    ].map { "OathAnkr." + $0 })

    private static func providerAvailability(_ message: String) -> Bool {
        let first = String(message.prefix(512)).split(separator: "\n", omittingEmptySubsequences: false).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let exact: Set<String> = [
            "too many requests", "rate limit exceeded", "request rate exceeded",
            "eapi:rate limit exceeded", "egeneral:too many requests", "service unavailable",
            "temporarily unavailable", "bad gateway", "gateway timeout", "request timeout",
            "request timed out", "connection refused", "connection reset by peer",
            "toobusy", "slowdown", "nonetwork", "nonetwork: server is not synchronized"
        ]
        if exact.contains(first) { return true }
        // Documented provider envelopes append quota values or retry guidance.
        return ["rate bucket full (", "rate limit exceeded:", "rate limit exceeded.",
                "too many requests:", "too many requests.", "request rate exceeded:",
                "your request was rate limited", "requests are rate limited", "daily request limit reached",
                "your app has exceeded its compute units per second capacity"].contains { first.hasPrefix($0) }
    }
}
