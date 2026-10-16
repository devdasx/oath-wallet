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
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("OathApp/Info.plist")), format: nil) as! [String: Any]
        let types = plist["CFBundleURLTypes"] as? [[String: Any]] ?? []
        try check(types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains("oathwallet") == true }, "Scheme registered in app")
        let entitlements = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("OathApp/OathAtmosphere.entitlements")), format: nil) as! [String: Any]
        try check((entitlements["com.apple.developer.associated-domains"] as? [String]) == ["applinks:oathwallet.org"], "Associated domain registered")
        print("Wallet link checks passed: \(count)")
    }
}
