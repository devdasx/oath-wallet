import Foundation
import Observation

/// WalletConnect entry points only. URLs never authorize an account or signature.
/// Payloads stay in memory; never use them as navigation IDs, logs or restoration data.
enum OathWalletLink: Equatable, Sendable {
    static let native = "oathwallet://"
    static let universal = "https://oathwallet.org"
    case connections
    case pair(String)

    static func parse(_ url: URL, now: Date = .now) -> Self? {
        guard url.absoluteString.utf8.count <= 8_192,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else { return nil }
        switch parts.scheme?.lowercased() {
        case "oathwallet":
            guard (parts.host == "wc" && ["", "/"].contains(parts.path)) ||
                    ((parts.host ?? "").isEmpty && ["", "/", "/wc", "/wc/"].contains(parts.path)) else { return nil }
        case "https":
            guard parts.host?.lowercased() == "oathwallet.org", ["/wc", "/wc/"].contains(parts.path) else { return nil }
        default: return nil
        }
        guard let query = parts.query, !query.isEmpty else { return .connections }
        let items = parts.queryItems ?? []
        guard items.first?.name == "uri", items.filter({ $0.name == "uri" }).count == 1,
              let first = items.first?.value, !first.isEmpty else { return nil }
        let uri: String
        if items.count == 1 { uri = first }
        else {
            // Older clients use the documented unescaped nested WC URI. Accept
            // only its protocol parameters, never arbitrary redirect parameters.
            let allowed: Set<String> = ["symKey", "relay-protocol", "relay-data", "expiryTimestamp"]
            guard first.hasPrefix("wc:"), first.contains("?"),
                  items.dropFirst().allSatisfy({ allowed.contains($0.name) && $0.value != nil }),
                  Set(items.map(\.name)).count == items.count,
                  let encoded = parts.percentEncodedQuery, encoded.hasPrefix("uri="),
                  let decoded = String(encoded.dropFirst(4)).removingPercentEncoding else { return nil }
            uri = decoded
        }
        // Incomplete URIs wake the wallet for an existing signing request;
        // they are never passed to the pairing API (WalletConnect mobile spec).
        if let inner = URLComponents(string: uri), inner.scheme == "wc", inner.host == nil,
           inner.query == nil, inner.fragment == nil, inner.path.hasSuffix("@2") {
            let topic = String(inner.path.dropLast(2))
            if (topic.count == 64 && topic.utf8.allSatisfy(isHex)) || UUID(uuidString: topic) != nil { return .connections }
        }
        if case .walletConnect(let validated) = OathScanParser.walletConnect(uri, now: now) { return .pair(validated) }
        // Untrusted malformed/expired links are expected input validation,
        // not app failures. Pairing/transport failures use shared diagnostics.
        return nil
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}

@MainActor @Observable final class OathWalletLinkInbox {
    static let shared = OathWalletLinkInbox()
    struct Entry: Identifiable {
        let id = UUID()
        let route: OathWalletLink
        let expires: Date
        var uri: String? { if case .pair(let uri) = route { return uri }; return nil }
    }
    private(set) var pending: Entry?
    @ObservationIgnored private var active: Entry?
    @ObservationIgnored private var delivered: Entry?

    func receive(_ url: URL, now: Date = .now) {
        guard let route = OathWalletLink.parse(url, now: now) else { return }
        if active?.route == route { return }
        if let pending, pending.expires > now { return } // One bounded request; never replace an in-flight consent.
        if let delivered, delivered.route == route, delivered.expires > now { return }
        pending = Entry(route: route, expires: now.addingTimeInterval(300))
    }

    func take(now: Date = .now) -> Entry? {
        guard let entry = pending else { return nil }
        pending = nil
        guard entry.expires > now else { return nil }
        // Coalesce UIKit + SwiftUI delivery of the same URL. No persistent secret.
        delivered = Entry(route: entry.route, expires: now.addingTimeInterval(3))
        active = entry
        return entry
    }

    func didDismiss() { active = nil }
    func clear() { pending = nil; delivered = nil; active = nil }
}
