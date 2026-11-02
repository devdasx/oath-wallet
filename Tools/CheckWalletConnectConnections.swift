import Foundation

/// Production connection lifecycle, metadata policy and scanner routing on the
/// host. Isolated defaults and synthetic session IDs; no user wallet or relay.
@main struct CheckWalletConnectConnections {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        typealias Failure = OathWalletConnectPolicy.ConnectionFailure
        let secret = "wc:private-topic?symKey=private-key"
        let cases: [(String, Int, Failure)] = [
            ("WalletConnectPairing.WalletPairService.Errors", 0, .usedQR),
            ("WalletConnectPairing.WalletPairService.Errors", 1, .relayUnavailable),
            ("WalletConnectRelay.RelayError", 0, .relayTimeout),
            ("WalletConnectSign.ApproveEngine.Errors", 0, .proposalUnavailable),
            ("WalletConnectSign.ApproveEngine.Errors", 2, .proposalUnavailable),
            ("WalletConnectSign.ApproveEngine.Errors", 3, .proposalUnavailable),
            ("WalletConnectSign.ApproveEngine.Errors", 4, .invalidQR),
            ("WalletConnectSign.ApproveEngine.Errors", 5, .relayUnavailable),
            ("WalletConnectSign.ApproveEngine.Errors", 6, .expiredQR),
            ("WalletConnectSign.ApproveEngine.Errors", 7, .unsupportedNetworks),
            (NSURLErrorDomain, NSURLErrorNotConnectedToInternet, .offline),
            (NSURLErrorDomain, NSURLErrorTimedOut, .relayTimeout),
            (NSURLErrorDomain, NSURLErrorNetworkConnectionLost, .relayUnavailable),
            ("Unexpected.Provider", 0, .unknown),
            ("WalletConnectPairing.WalletPairService.Errors", 99, .unknown)
        ]
        for (domain, code, expected) in cases {
            let error = NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: secret])
            check(Failure.classify(error) == expected, "Connection reason must use structured error identity")
            check(!String(describing: Failure.classify(error)).contains(secret), "Connection secrets cannot enter display errors")
        }
        check(Failure.classify(CancellationError()) == nil, "Task cancellation does not create a failure screen")
        check(Failure.classify(URLError(.cancelled)) == nil, "Transport cancellation does not create a failure screen")
        check(Failure.peerTimeout != .expiredQR, "An unresponsive website is not evidence of expiry")
        check(Failure.peerTimeout.allowsPairingRetry && Failure.offline.allowsPairingRetry, "Temporary failures allow retry")
        check(!Failure.usedQR.allowsPairingRetry && !Failure.expiredQR.allowsPairingRetry && !Failure.invalidQR.allowsPairingRetry, "Invalid and consumed codes need a fresh QR")
        let qr = "wc:" + String(repeating: "a", count: 64) + "@2?relay-protocol=irn&symKey=" + String(repeating: "b", count: 64)
        let now = Date(timeIntervalSince1970: 1_000)
        if case .invalid(.expiredWalletConnect) = OathScanParser.walletConnect(qr + "&expiryTimestamp=999", now: now) { checks += 1 }
        else { preconditionFailure("Expired QR must keep the WalletConnect-specific explanation") }
        if case .invalid(.invalidWalletConnect) = OathScanParser.walletConnect(qr + "&symKey=duplicate", now: now) { checks += 1 }
        else { preconditionFailure("Malformed QR must keep the WalletConnect-specific explanation") }
        if case .walletConnect = OathScanParser.walletConnect(qr, now: now) { checks += 1 }
        else { preconditionFailure("Codes without expiry cannot be assumed expired") }
        var ownership = OathWalletConnectPolicy.PresentationOwnership()
        let firstPresentation = UUID(), secondPresentation = UUID()
        check(ownership.claim(firstPresentation), "First request reserves its sheet before presentation")
        check(ownership.claim(firstPresentation), "Reappearing beneath a cover retains its owner")
        check(!ownership.claim(secondPresentation), "A second presenter cannot take the active consent")
        check(!ownership.release(secondPresentation), "Unrelated dismissal cannot clear consent")
        check(ownership.id == firstPresentation, "Consent remains active after an unrelated sheet closes")
        ownership.beginDismissal(secondPresentation)
        check(!ownership.isDismissing, "Unrelated sheets cannot start dismissal")
        ownership.beginDismissal(firstPresentation)
        check(ownership.isDismissing, "Outgoing sheet remains occupied throughout the animation")
        check(ownership.release(firstPresentation), "Actual dismissal releases the sheet")
        check(!ownership.isDismissing, "Next request is not held by an old animation")
        check(ownership.claim(secondPresentation), "Queued request claims the next presentation")
        check(!ownership.release(firstPresentation), "Late dismissal cannot clear a newer request")
        check(ownership.id == secondPresentation, "Newer request keeps its owner")
        var pairing = OathWalletConnectPolicy.PairingProgress.waiting
        check(pairing.fail(), "Waiting pairing reports a real transport failure")
        check(pairing == .failed, "Failure remains visible while no proposal exists")
        check(pairing.receiveProposal(), "Late valid proposal recovers a timeout or earlier pairing error")
        check(pairing == .reviewing, "Recovered proposal is reviewable")
        check(!pairing.fail(), "Late transport failure cannot overwrite proposal review or approval")
        check(!pairing.receiveProposal(), "Duplicate proposal must not reset an approval in flight")
        pairing = .connected
        check(!pairing.fail(), "Late transport failure cannot overwrite successful connection")
        check(!pairing.receiveProposal(), "Duplicate proposal cannot reopen completed consent")
        pairing = .idle
        check(!pairing.receiveProposal() && !pairing.fail(), "Dismissed pairing ignores delayed callbacks")
        pairing = .waiting
        check(pairing.receiveProposal() && !pairing.fail(), "Proposal-before-pair-error ordering remains successful")
        let handoff = OathWalletConnectPolicy.CompletionHandoff.self
        check(handoff.shouldQueue(presentation: .completed(topic: "one"), topic: "one", requiresApproval: true),
              "Same-peer follow-up waits for the minimum receipt display before an in-place review")
        check(!handoff.shouldQueue(presentation: .completed(topic: "one"), topic: "two", requiresApproval: true),
              "Unrelated peer cannot replace a result")
        check(!handoff.shouldQueue(presentation: .completed(topic: "one"), topic: "one", requiresApproval: false),
              "Account and chain reads do not dismiss the result or wait for a visual timer")
        for state: OathWalletConnectPolicy.RequestPresentation in [.idle, .committingConnection, .reviewing, .connected(topic: "one")] {
            check(!handoff.shouldQueue(presentation: state, topic: "one", requiresApproval: true),
                  "Result handoff cannot replace an active review or connection approval")
        }
        let receiptID = UUID(), nextReceiptID = UUID()
        check(handoff.canReplace(owner: ownership, presentationID: secondPresentation,
              completionID: receiptID, expectedID: receiptID, requestedID: receiptID),
              "Current owner may replace its receipt in place without releasing presentation")
        check(ownership.id == secondPresentation && !ownership.isDismissing,
              "In-place handoff preserves presentation ownership")
        check(!handoff.canReplace(owner: ownership, presentationID: firstPresentation,
              completionID: receiptID, expectedID: receiptID, requestedID: receiptID),
              "Timer from an older sheet cannot hand off a newer sheet")
        check(!handoff.canReplace(owner: ownership, presentationID: secondPresentation,
              completionID: nextReceiptID, expectedID: receiptID, requestedID: receiptID),
              "Timer from a previous receipt cannot replace the next receipt")
        check(!handoff.canReplace(owner: ownership, presentationID: secondPresentation,
              completionID: receiptID, expectedID: receiptID, requestedID: nil),
              "Showing a receipt does not fabricate another request")
        ownership.beginDismissal(secondPresentation)
        check(!handoff.canReplace(owner: ownership, presentationID: secondPresentation,
              completionID: receiptID, expectedID: receiptID, requestedID: receiptID),
              "Close wins over a simultaneous follow-up timer")
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
