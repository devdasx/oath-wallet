import Foundation
import Observation

/// External wallet links only prepare a review; they never authorize an account or signature.
/// Payloads stay in memory; never use them as navigation IDs, logs or restoration data.
enum OathWalletLink: Equatable, Sendable {
    static let native = "oathwallet://"
    static let universal = "https://oathwallet.org"
    case connections
    case pair(String)
    case payment(OathScannedRecipient)

    var isWalletConnect: Bool {
        switch self { case .connections, .pair: true; case .payment: false }
    }

    private static let networks = Dictionary(uniqueKeysWithValues: OathTokenNetwork.all.filter { $0.chain.isEVM }
        .compactMap { row in row.chainID.map { ($0, row.chain) } })

    static func parse(_ url: URL, now: Date = .now, evmNetworks: [UInt64: OathImportChain]? = nil) -> Self? {
        guard url.absoluteString.utf8.count <= 8_192,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else { return nil }
        let scheme = parts.scheme?.lowercased() ?? ""
        let parser = OathScanParser(validator: nil, evmNetworks: evmNetworks ?? networks)
        if scheme == "wc" { return connection(url.absoluteString, now: now) }
        if OathScanParser.registeredPaymentSchemes.contains(scheme) {
            if case .recipient(let recipient) = parser.parse(url.absoluteString, now: now) { return .payment(recipient) }
            return nil
        }
        switch scheme {
        case "oathwallet":
            if (parts.host == "pay" && ["", "/"].contains(parts.path)) ||
                ((parts.host ?? "").isEmpty && ["/pay", "/pay/"].contains(parts.path)) {
                let items = parts.queryItems ?? []
                guard Set(items.map(\.name)).count == items.count,
                      Set(items.map(\.name)).isSubset(of: ["uri", "network"]),
                      let payload = items.first(where: { $0.name == "uri" })?.value, !payload.isEmpty,
                      payload == payload.trimmingCharacters(in: .whitespacesAndNewlines),
                      // Wrappers cannot nest, import secrets, or load remote requests.
                      !["oathwallet", "http", "https", "wc"].contains(URLComponents(string: payload)?.scheme?.lowercased() ?? ""),
                      case .recipient(var recipient) = parser.parse(payload, now: now) else { return nil }
                if let item = items.first(where: { $0.name == "network" }) {
                    guard let value = item.value, let chain = OathImportChain(rawValue: value),
                          recipient.networks.contains(chain) else { return nil }
                    recipient = scoped(recipient, to: chain)
                }
                return .payment(recipient)
            }
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
            let allowed: Set<String> = ["symKey", "relay-protocol", "relay-data", "expiryTimestamp", "methods"]
            guard first.hasPrefix("wc:"), first.contains("?"),
                  items.dropFirst().allSatisfy({ allowed.contains($0.name) && $0.value != nil }),
                  Set(items.map(\.name)).count == items.count,
                  let encoded = parts.percentEncodedQuery, encoded.hasPrefix("uri="),
                  let decoded = String(encoded.dropFirst(4)).removingPercentEncoding else { return nil }
            uri = decoded
        }
        return connection(uri, now: now)
    }

    /// Oath-specific address links avoid competing registrations for bitcoin:, wc:, etc.
    static func paymentURL(address: String, chain: OathImportChain) -> URL? {
        let parser = OathScanParser(validator: nil, evmNetworks: networks)
        guard case .recipient(let recipient) = parser.parse(address), recipient.networks.contains(chain),
              OathScanAddress.decode(address, chain: chain) != nil else { return nil }
        var parts = URLComponents(string: native + "pay")!
        parts.queryItems = [.init(name: "uri", value: address), .init(name: "network", value: chain.rawValue)]
        guard let url = parts.url, url.absoluteString.utf8.count <= 8_192 else { return nil }
        return url
    }

    private static func scoped(_ recipient: OathScannedRecipient, to chain: OathImportChain) -> OathScannedRecipient {
        var result = OathScannedRecipient(original: recipient.original, networks: [chain])
        result.amount = recipient.amount; result.amountIsAtomic = recipient.amountIsAtomic
        result.amountAssetUnspecified = recipient.amountAssetUnspecified
        result.token = recipient.token; result.tokenSymbol = recipient.tokenSymbol
        result.memo = recipient.memo; result.memoType = recipient.memoType
        result.solanaReferences = recipient.solanaReferences
        result.label = recipient.label; result.message = recipient.message
        return result
    }

    private static func connection(_ uri: String, now: Date) -> Self? {
        // Incomplete URIs wake the wallet for an existing signing request;
        // they are never passed to the pairing API (WalletConnect mobile spec).
        if let inner = URLComponents(string: uri), inner.scheme == "wc", inner.host == nil,
           inner.user == nil, inner.password == nil, inner.port == nil,
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
        fileprivate let sourceURL: URL?
        init(route: OathWalletLink, expires: Date, sourceURL: URL? = nil) {
            self.route = route
            self.expires = expires
            self.sourceURL = sourceURL
        }
        var uri: String? { if case .pair(let uri) = route { return uri }; return nil }
    }
    private(set) var pending: Entry?
    var hasWalletConnectRequest: Bool { pending?.route.isWalletConnect == true }
    @ObservationIgnored private var active: Entry?
    @ObservationIgnored private var delivered: Entry?

    func receive(_ url: URL, now: Date = .now) {
        guard let route = OathWalletLink.parse(url, now: now) else { return }
        if active?.route == route { return }
        if let pending, pending.expires > now { return } // One bounded request; never replace an in-flight consent.
        if let delivered, delivered.route == route, delivered.expires > now { return }
        pending = Entry(route: route, expires: now.addingTimeInterval(300), sourceURL: url)
    }

    func take(now: Date = .now, walletConnectOnly: Bool = false) -> Entry? {
        guard let entry = pending else { return nil }
        guard entry.expires > now else { pending = nil; return nil }
        if let source = entry.sourceURL, OathWalletLink.parse(source, now: now) != entry.route {
            pending = nil
            return nil
        }
        guard !walletConnectOnly || entry.route.isWalletConnect else { return nil }
        pending = nil
        // Coalesce UIKit + SwiftUI delivery of the same URL. No persistent secret.
        delivered = Entry(route: entry.route, expires: now.addingTimeInterval(3))
        active = entry
        return entry
    }

    func didDismiss() { active = nil }
    func clear() { pending = nil; delivered = nil; active = nil }
}
