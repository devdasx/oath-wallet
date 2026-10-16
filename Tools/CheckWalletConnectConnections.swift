import Foundation

/// Production connection lifecycle, metadata policy and scanner routing on the
/// host. Isolated defaults and synthetic session IDs; no user wallet or relay.
@main struct CheckWalletConnectConnections {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        let suite = "OathWCConnectionsTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = first.addingTimeInterval(50)
        var store = OathWalletConnectConnections(defaults: defaults)
        check(store.connectedAt("legacy") == nil, "Legacy sessions must not invent approval times")
        check(!store.isRevoked("legacy"), "Legacy mapping is not implicitly revoked")
        store.approve("one", pairingTopic: "pairing-one", at: first)
        store.approve("two", at: second)
        check(store.connectedAt("one") == first, "Exact initial approval time retained")
        store.approve("one", at: second)
        check(store.connectedAt("one") == first, "Repeated SDK publication must not reset age")
        store = OathWalletConnectConnections(defaults: defaults)
        check(store.connectedAt("one") == first && store.connectedAt("two") == second, "Dates survive relaunch")
        check(store.isAssociated("one", with: "pairing-one"), "Approved pairing survives repeat approval and relaunch")
        check(!store.isAssociated("one", with: "pairing-other"), "Different QR cannot resume this session")
        check(!store.isAssociated("two", with: "pairing-one"), "Legacy entries without association remain readable and are never guessed")
        check(!String(decoding: defaults.data(forKey: "walletconnect.connectionLifecycle.v1")!, as: UTF8.self).contains("pairing-one"), "No raw pairing topic in persistence")
        store.selectChain(42161, for: "one")
        store = OathWalletConnectConnections(defaults: defaults)
        check(store.activeChain("one") == 42161 && store.activeChain("two") == nil, "Network choice survives relaunch for only its session")
        store.selectChain(0, for: "one")
        check(store.activeChain("one") == 42161, "Invalid chain selection rejected")
        store.revoke("one")
        check(store.isRevoked("one") && !store.isRevoked("two"), "Disconnect revokes only selected session")
        check(!store.isAssociated("one", with: "pairing-one"), "Revoked connection cannot resume from an old QR")
        store = OathWalletConnectConnections(defaults: defaults)
        check(store.isRevoked("one"), "Offline revocation survives relaunch")
        check(store.connectedAt("one") == first, "Retry must not reset timestamp")
        store.reconcile(topics: ["one", "two", "legacy"])
        check(store.isRevoked("one"), "Pending remote disconnect stays revoked during SDK refresh")
        check(store.connectedAt("legacy") == nil, "Discovery cannot manufacture connection time")
        store.reconcile(topics: ["two"])
        store = OathWalletConnectConnections(defaults: defaults)
        check(store.connectedAt("one") == nil && !store.isRevoked("one"), "Peer deletion/expiry prunes supplemental state")
        check(store.connectedAt("two") == second, "Unrelated session preserved")
        store.revoke("legacy")
        check(store.connectedAt("legacy") == nil && store.isRevoked("legacy"), "Legacy offline disconnect is durable without inventing timestamp")
        store.reconcile(topics: [])
        store = OathWalletConnectConnections(defaults: defaults)
        check(!store.isRevoked("legacy") && store.connectedAt("two") == nil, "Empty SDK state cleans stale history")
        store.approve("invalid-date", at: Date(timeIntervalSince1970: -.infinity))
        check(store.connectedAt("invalid-date") == nil, "Invalid timestamps rejected")
        for n in 0..<140 { store.approve("bounded-\(n)", at: first) }
        check((0..<140).filter { store.connectedAt("bounded-\($0)") != nil }.count == 128, "Supplemental state is bounded")
        let encoded = defaults.data(forKey: "walletconnect.connectionLifecycle.v1")!
        check(!String(decoding: encoded, as: UTF8.self).contains("bounded-"), "No raw session topics in supplemental persistence")
        // Malformed storage is diagnosed and recoverable, never a launch crash.
        defaults.set(Data("not JSON".utf8), forKey: "walletconnect.connectionLifecycle.v1")
        store = OathWalletConnectConnections(defaults: defaults)
        check(store.connectedAt("one") == nil, "Malformed storage recovers")

        let valid = ["https://app.example.org", "https://app.example.org/swap?network=1", "https://cdn.example.org:443/logo.svg"]
        for url in valid { check(OathWalletConnectPolicy.website(url) != nil, "Public HTTPS website accepted") }
        let invalid = ["javascript:alert(1)", "file:///tmp/icon.png", "http://example.org", "oathwallet://wc",
                       "https://trusted.example@evil.example", "https://name:pass@example.org", "https://127.0.0.1/logo.png",
                       "https://[::1]/logo.png", "https://localhost", "https://router.local/logo.png", "https://app.example.org:8443",
                       "https://example.org\n", "https://exa\u{202E}mple.org", "https://example..org", "https://-example.org",
                       "https://example.org/" + String(repeating: "a", count: 2_049)]
        for url in invalid { check(OathWalletConnectPolicy.website(url) == nil, "Unsafe/deceptive metadata URL rejected") }
        for url in invalid { check(OathWalletConnectPolicy.safeHost(url) == nil, "Origin comparison cannot discard an unsafe URL or alternate port") }
        check(OathWalletConnectPolicy.displayName("App\u{202E}\n\u{0000} name") == "App name", "Bidi and control characters removed")
        check(OathWalletConnectPolicy.displayText(String(repeating: "x", count: 5_000)).count == 1_000, "Description bounded")
        let candidates = OathWalletConnectPolicy.iconSources([invalid[0], valid[0], valid[0], valid[1], valid[2]])
        check(candidates == valid, "Invalid and duplicate icons removed while fallback order stays intact")
        check(OathWalletConnectPolicy.iconSources((0..<10).map { "https://example.org/\($0).png" }).count == 4, "Logo requests bounded")
        check(OathWalletConnectPolicy.iconSources([]).isEmpty, "Missing logo uses placeholder without network")
        check(OathScannerContext.walletConnect.accepts(.walletConnect("synthetic")), "Connection scanner accepts WalletConnect")
        check(!OathScannerContext.walletConnect.accepts(.privateKey("synthetic")), "Connection scanner cannot import a key")
        let recipient = OathScannedRecipient(original: "synthetic", networks: [.ethereum])
        check(!OathScannerContext.walletConnect.accepts(.recipient(recipient)), "Connection scanner cannot send to an address")
        check(OathScannerContext.walletConnect.route(recipient) == .review, "Connection scanner cannot bypass review into asset picker")
        check(OathScannerContext.home.accepts(.recipient(recipient)), "Home address scanner preserved")
        check(OathScannerContext.walletConnect.accepts(.invalid(.expired)), "Expired QR retains explanatory validation state")
        print("Passed \(checks) WalletConnect management host checks: lifecycle/relaunch/revocation, bounded metadata, safe URLs/icons and shared scanner routing. No simulator, device or live session used.")
    }
}
