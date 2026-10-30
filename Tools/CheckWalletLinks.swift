import Foundation

@main struct CheckWalletLinks {
    enum Failure: Error { case assertion(String) }
    @MainActor static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Synthetic public fixture, never paired and never containing user keys.
        let topic = String(repeating: "a1", count: 32)
        let uri = "wc:\(topic)@2?relay-protocol=irn&symKey=\(String(repeating: "b2", count: 32))&expiryTimestamp=1800000300"
        func link(_ base: String, _ value: String) -> URL {
            var parts = URLComponents(string: base)!
            parts.queryItems = [.init(name: "uri", value: value)]
            return parts.url!
        }
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw Failure.assertion(label) }; count += 1
        }
        for base in ["oathwallet://wc", "oathwallet:///wc", "oathwallet://wc/", "https://oathwallet.org/wc", "https://oathwallet.org/wc/"] {
            try check(OathWalletLink.parse(link(base, uri), now: now) == .pair(uri), "Encoded pairing")
            try check(OathWalletLink.parse(URL(string: base + "?uri=" + uri)!, now: now) == .pair(uri), "Legacy unescaped pairing")
            try check(OathWalletLink.parse(URL(string: base)!, now: now) == .connections, "Open connections")
            try check(OathWalletLink.parse(link(base, "wc:\(topic)@2"), now: now) == .connections, "Session wake must not pair")
            try check(OathWalletLink.parse(link(base, "wc:00e46b69-d0cc-4b3e-b6a2-cee442f97188@2"), now: now) == .connections, "Legacy UUID wake")
            try check(OathWalletLink.parse(link(base, uri), now: now.addingTimeInterval(301)) == nil, "Expired pair")
        }
        try check(OathWalletLink.parse(URL(string: "oathwallet://")!) == .connections, "Base native link")
        try check(OathWalletLink.parse(URL(string: uri)!, now: now) == .pair(uri), "Camera raw WalletConnect pairing")
        try check(OathWalletLink.parse(URL(string: "wc:\(topic)@2")!, now: now) == .connections, "Camera session wake")
        let modernURI = uri + "&methods=[wc_sessionPropose],[wc_authRequest,wc_authBatchRequest]"
        try check(OathWalletLink.parse(URL(string: modernURI)!, now: now) == .pair(URL(string: modernURI)!.absoluteString), "Current WalletConnect method metadata")
        try check(OathWalletLink.parse(link("oathwallet://wc", modernURI), now: now) == .pair(modernURI), "Encoded current WalletConnect methods")
        for bad in [uri + "&methods=bad%26redirect", uri + "&methods=", uri + "&methods=a&methods=b",
                    uri.replacingOccurrences(of: "expiryTimestamp=1800000300", with: "expiryTimestamp=1800000300.5"),
                    uri.replacingOccurrences(of: "wc:", with: "wc://evil/"), uri + "#fragment"] {
            try check(OathWalletLink.parse(URL(string: bad)!, now: now) == nil, "Malformed direct pairing rejected")
        }
        for base in ["https://evil.example/wc", "https://oathwallet.org.evil.example/wc", "http://oathwallet.org/wc", "https://oathwallet.org:443/wc", "https://evil@oathwallet.org/wc", "oathwallet://evil", "oathwallet://wc/evil", "https://oathwallet.org/privacy"] {
            let url = link(base, uri)
            try check(OathWalletLink.parse(url, now: now) == nil, "Foreign or unsupported origin/route")
        }
        let good = link("oathwallet://wc", uri)
        for value in [good.absoluteString + "&uri=other", good.absoluteString + "&redirect=https://evil.example", good.absoluteString + "#fragment",
                      "oathwallet://wc?uri=", "oathwallet://wc?key=x", "oathwallet://wc?uri=" + String(repeating: "a", count: 9000)] {
            try check(OathWalletLink.parse(URL(string: value)!, now: now) == nil, "Ambiguous/malformed input")
        }
        for value in [uri + "&symKey=duplicate", uri.replacingOccurrences(of: "@2", with: "@1"),
                      "wc:\(topic)@2?relay-protocol=irn", uri + "&unsupported=1", "https://evil.example", "javascript:alert(1)"] {
            try check(OathWalletLink.parse(link("oathwallet://wc", value), now: now) == nil, "Invalid nested protocol")
        }
        let inbox = OathWalletLinkInbox()
        inbox.receive(good, now: now)
        let id = inbox.pending?.id
        inbox.receive(good, now: now)
        try check(inbox.pending?.id == id, "Duplicate cold/SwiftUI delivery")
        inbox.receive(URL(string: "oathwallet://")!, now: now)
        try check(inbox.pending?.id == id, "Busy inbox never overwrites consent")
        try check(inbox.take(now: now)?.route == .pair(uri), "Deferred unlock delivery")
        try check(inbox.take(now: now) == nil, "Exactly once consumption")
        inbox.receive(good, now: now.addingTimeInterval(1))
        try check(inbox.pending == nil, "Duplicate delivery after consumption")
        inbox.receive(good, now: now.addingTimeInterval(4))
        try check(inbox.pending == nil, "Active approval never queues a duplicate")
        inbox.didDismiss()
        inbox.receive(good, now: now.addingTimeInterval(4))
        try check(inbox.pending != nil, "Explicit later retry works")
        inbox.clear()
        try check(inbox.pending == nil, "Clear drops pending payload")
        inbox.receive(URL(string: "oathwallet://")!, now: now)
        try check(inbox.take(now: now.addingTimeInterval(301)) == nil, "Pending launch request expires")
        let address = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"
        let payment = "bitcoin:\(address)?amount=0.125&label=Invoice&message=Order%20one"
        let parser = OathScanParser(validator: nil, evmNetworks: [:])
        guard case .recipient(let expected) = parser.parse(payment) else { throw Failure.assertion("Payment fixture") }
        let paymentLink = link("oathwallet://pay", payment)
        try check(OathWalletLink.parse(URL(string: payment)!, now: now) == .payment(expected), "Raw payment keeps amounts and notes")
        try check(OathWalletLink.parse(paymentLink, now: now) == .payment(expected), "Wrapped payment keeps amounts and notes")
        try check(OathWalletLink.parse(URL(string: paymentLink.absoluteString + "&network=bitcoin")!, now: now) == .payment(expected), "Explicit matching network")
        for bad in [paymentLink.absoluteString + "&network=ethereum", paymentLink.absoluteString + "&uri=other",
                    paymentLink.absoluteString + "&network=bitcoin&network=bitcoin", paymentLink.absoluteString + "&redirect=evil",
                    paymentLink.absoluteString + "#fragment", "oathwallet://pay?network=bitcoin", "oathwallet://pay?uri="] {
            try check(OathWalletLink.parse(URL(string: bad)!, now: now) == nil, "Ambiguous payment wrapper rejected")
        }
        for bad in ["oathwallet://pay", paymentLink.absoluteString, " \n" + paymentLink.absoluteString,
                    "https://example.com/pay", "javascript:alert(1)", uri,
                    "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
                    "bitcoin:\(address)?amount=1&amount=2", "bitcoin:\(address)?req-unsupported=1"] {
            try check(OathWalletLink.parse(link("oathwallet://pay", bad), now: now) == nil, "Nested, secret or unsupported request rejected")
        }
        try check(OathWalletLink.paymentURL(address: address, chain: .ethereum) == nil, "Cannot share the wrong network")
        inbox.receive(paymentLink, now: now)
        let paymentID = inbox.pending?.id
        inbox.receive(paymentLink, now: now)
        try check(inbox.pending?.id == paymentID && !inbox.hasWalletConnectRequest, "Payment launch delivery coalesces")
        try check(inbox.take(now: now, walletConnectOnly: true) == nil && inbox.pending?.id == paymentID, "WalletConnect page cannot consume a payment")
        try check(inbox.take(now: now)?.route == .payment(expected), "Unlock resumes a queued payment")
        inbox.receive(paymentLink, now: now.addingTimeInterval(4))
        try check(inbox.pending == nil, "Active send review never duplicates")
        inbox.didDismiss()
        inbox.receive(paymentLink, now: now.addingTimeInterval(4))
        try check(inbox.take(now: now.addingTimeInterval(305)) == nil, "Stale payments expire without review")
        let expiring = URL(string: "solana:So11111111111111111111111111111111111111112?amount=1&exp=1800000010")!
        inbox.receive(expiring, now: now)
        try check(inbox.pending != nil, "Unexpired payment is queued")
        try check(inbox.take(now: now.addingTimeInterval(11)) == nil && inbox.pending == nil, "Payment expiration rechecked after unlock")
        inbox.receive(link("oathwallet://pay", expiring.absoluteString), now: now)
        try check(inbox.take(now: now.addingTimeInterval(11)) == nil, "Wrapped payment expiration rechecked after unlock")
        let shortPair = URL(string: uri.replacingOccurrences(of: "1800000300", with: "1800000010"))!
        inbox.receive(shortPair, now: now)
        try check(inbox.take(now: now.addingTimeInterval(11)) == nil, "Pairing expiration rechecked after unlock")
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("OathApp/Info.plist")), format: nil) as! [String: Any]
        let types = plist["CFBundleURLTypes"] as? [[String: Any]] ?? []
        try check(types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains("oathwallet") == true }, "Scheme registered in app")
        let registered = Set(types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] })
        try check(registered == OathScanParser.registeredPaymentSchemes.union(["oathwallet", "wc"]), "Every supported OS scheme registered; no foreign app schemes")
        for chain in OathImportChain.allCases {
            try check(registered.contains(chain.rawValue), "Every chain can receive an OS payment link")
        }
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let projectSchemes = Set(project.components(separatedBy: .newlines).filter { $0.contains("CFBundleURLSchemes:") }.flatMap { line in
            line.components(separatedBy: "[").last!.replacingOccurrences(of: "]", with: "").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        })
        try check(projectSchemes == registered, "Project regeneration preserves all URL schemes")
        let entitlements = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("OathApp/OathAtmosphere.entitlements")), format: nil) as! [String: Any]
        try check((entitlements["com.apple.developer.associated-domains"] as? [String]) == ["applinks:oathwallet.org"], "Associated domain registered")
        print("Wallet link checks passed: \(count)")
    }
}
