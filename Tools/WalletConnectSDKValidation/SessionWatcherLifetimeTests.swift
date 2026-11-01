import XCTest
import Combine
@testable import Schemas
import WalletConnectNetworking

private final class CountingProposalWatcher: ProposalExpiryWatcher {
    var checks = 0
    override func checkForProposalsExpiry() { checks += 1; super.checkForProposalsExpiry() }
}
private final class CountingRequestWatcher: RequestsExpiryWatcher {
    var checks = 0
    override func checkForRequestExpiry() { checks += 1; super.checkForRequestExpiry() }
}

final class SessionWatcherLifetimeTests: XCTestCase {
    private func proposals() -> CodableStore<RequestSubscriptionPayload<SessionType.ProposeParams>> {
        CodableStore(defaults: RuntimeKeyValueStorage(), identifier: "synthetic-proposals")
    }
    private func history() -> RPCHistory { RPCHistoryFactory.createForNetwork(keyValueStorage: RuntimeKeyValueStorage()) }
    private func historyService(_ history: RPCHistory) -> HistoryService {
        HistoryService(history: history, verifyContextStore: CodableStore(defaults: RuntimeKeyValueStorage(), identifier: "synthetic-context"))
    }
    // Exercise real Foundation scheduling beyond the production 3-second period.
    private func runTimerWindow() {
        XCTAssertTrue(Thread.isMainThread, "Timer fixture requires main-thread XCTest execution")
        var witnessFired = false
        let witness = Timer.scheduledTimer(withTimeInterval: 3.1, repeats: false) { _ in witnessFired = true }
        defer { witness.invalidate() }
        RunLoop.current.run(until: Date().addingTimeInterval(3.35))
        XCTAssertTrue(witnessFired, "The run loop must execute a scheduled timer")
    }

    func testReleasedProposalWatcherDoesNotCrash() {
        var watcher: ProposalExpiryWatcher? = ProposalExpiryWatcher(proposalPayloadsStore: proposals(), rpcHistory: history())
        weak var released = watcher; watcher = nil
        XCTAssertNil(released, "Watcher must be released before timer window")
        runTimerWindow()
    }
    func testReleasedRequestWatcherDoesNotCrash() {
        let rpc = history()
        var watcher: RequestsExpiryWatcher? = RequestsExpiryWatcher(proposalPayloadsStore: proposals(), rpcHistory: rpc, historyService: historyService(rpc))
        weak var released = watcher; watcher = nil
        XCTAssertNil(released, "Watcher must be released before timer window")
        runTimerWindow()
    }
    func testProposalTimerSetupReplacesOldTimer() {
        let watcher = CountingProposalWatcher(proposalPayloadsStore: proposals(), rpcHistory: history())
        watcher.setUpExpiryCheckTimer()
        runTimerWindow()
        XCTAssertEqual(watcher.checks, 1, "Repeated setup must leave one proposal timer")
        withExtendedLifetime(watcher) { }
    }
    func testRequestTimerSetupReplacesOldTimer() {
        let rpc = history()
        let watcher = CountingRequestWatcher(proposalPayloadsStore: proposals(), rpcHistory: rpc, historyService: historyService(rpc))
        watcher.setUpExpiryCheckTimer()
        runTimerWindow()
        XCTAssertEqual(watcher.checks, 1, "Repeated setup must leave one request timer")
        withExtendedLifetime(watcher) { }
    }

    private func metadata() -> AppMetadata {
        AppMetadata(name: "Synthetic", description: "Lifecycle fixture", url: "https://example.invalid", icons: [],
                    redirect: try! AppMetadata.Redirect(native: "", universal: nil))
    }
    private func session(expired: Bool = false) -> WCSession {
        let owner = Participant(publicKey: "synthetic-owner", metadata: metadata())
        let params = SessionType.SettleParams(relay: RelayProtocolOptions(protocol: "irn", data: nil), controller: owner,
            namespaces: [:], sessionProperties: nil, scopedProperties: nil,
            expiry: expired ? 1 : Int64(Date().timeIntervalSince1970) + 3600, proposalRequestsResponses: nil)
        return WCSession(topic: "synthetic-session", pairingTopic: "synthetic-pairing", timestamp: Date(), selfParticipant: owner,
            peerParticipant: Participant(publicKey: "synthetic-peer", metadata: metadata()), settleParams: params,
            requiredNamespaces: [:], acknowledged: true, transportType: .relay, verifyContext: nil)
    }
    private func sequences() -> SequenceStore<WCSession> {
        SequenceStore(store: CodableStore(defaults: RuntimeKeyValueStorage(), identifier: "synthetic-sequences"))
    }
    func testStorageUpdateCanOutliveReleasedWrapper() {
        let store = sequences()
        var wrapper: SessionStorage? = SessionStorage(storage: store)
        var callbacks = 0; wrapper?.onSessionsUpdate = { callbacks += 1 }
        weak var released = wrapper; wrapper = nil
        XCTAssertNil(released)
        store.setSequence(session())
        XCTAssertEqual(callbacks, 0)
        XCTAssertTrue(store.hasSequence(forTopic: "synthetic-session"))
    }
    func testStorageExpiryCanOutliveReleasedWrapper() throws {
        let store = sequences(); store.setSequence(session(expired: true))
        var wrapper: SessionStorage? = SessionStorage(storage: store)
        var callbacks = 0; wrapper?.onSessionExpiration = { _ in callbacks += 1 }
        // Isolate the expiration callback from the separate update callback.
        store.onSequenceUpdate = nil
        weak var released = wrapper; wrapper = nil
        XCTAssertNil(released)
        XCTAssertNil(try store.getSequence(forTopic: "synthetic-session"))
        XCTAssertEqual(callbacks, 0)
    }
    func testReplacingWrapperPreservesNewOwnerCallbacks() {
        let store = sequences(); var old: SessionStorage? = SessionStorage(storage: store)
        var oldCalls = 0; old?.onSessionsUpdate = { oldCalls += 1 }
        let replacement = SessionStorage(storage: store)
        var newCalls = 0; replacement.onSessionsUpdate = { newCalls += 1 }
        old = nil; store.setSequence(session())
        XCTAssertEqual(oldCalls, 0); XCTAssertEqual(newCalls, 1)
        withExtendedLifetime(replacement) { }
    }
    func testLiveWrapperReceivesUpdateAndExpiry() throws {
        let store = sequences(); let wrapper = SessionStorage(storage: store)
        var updates = 0; var expirations: [String] = []
        wrapper.onSessionsUpdate = { updates += 1 }; wrapper.onSessionExpiration = { expirations.append($0.topic) }
        store.setSequence(session(expired: true))
        XCTAssertNil(try store.getSequence(forTopic: "synthetic-session"))
        XCTAssertEqual(updates, 2); XCTAssertEqual(expirations, ["synthetic-session"])
        withExtendedLifetime(wrapper) { }
    }

    func testProposalExpiryDeletesOnlyExpiredItems() throws {
        let store = proposals(); let rpc = history(); let watcher = ProposalExpiryWatcher(proposalPayloadsStore: store, rpcHistory: rpc)
        var events: [String] = []; let token = watcher.sessionProposalExpirationPublisher.sink { events.append($0.id) }
        defer { token.cancel() }
        for (id, expired) in [(41, true), (42, false)] {
            let proposal = SessionProposal(relays: [], proposer: Participant(publicKey: "synthetic-\(id)", metadata: metadata()), requiredNamespaces: [:])
            var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(proposal)) as? [String: Any])
            if expired { encoded["expiryTimestamp"] = 1 }
            let value = try JSONDecoder().decode(SessionProposal.self, from: JSONSerialization.data(withJSONObject: encoded))
            let payload = RequestSubscriptionPayload(id: RPCID(Int64(id)), topic: "synthetic-pairing", request: value,
                decryptedPayload: Data(), publishedAt: Date(), derivedTopic: nil, encryptedMessage: "synthetic", attestation: nil)
            store.set(payload, forKey: value.proposer.publicKey)
            try rpc.set(RPCRequest(method: "wc_sessionPropose", params: value, rpcid: RPCID(Int64(id))), forTopic: "synthetic-pairing", emmitedBy: .remote, transportType: .relay)
        }
        watcher.checkForProposalsExpiry(); watcher.checkForProposalsExpiry()
        XCTAssertEqual(events, ["synthetic-41"]); XCTAssertNil(rpc.get(recordId: RPCID(41))); XCTAssertNotNil(rpc.get(recordId: RPCID(42)))
        XCTAssertEqual(store.getAll().count, 1)
        withExtendedLifetime(watcher) { }
    }
    func testRequestExpiryDeletesOnlyExpiredItems() throws {
        let rpc = history(); let watcher = RequestsExpiryWatcher(proposalPayloadsStore: proposals(), rpcHistory: rpc, historyService: historyService(rpc))
        var events: [RPCID] = []; let token = watcher.requestExpirationPublisher.sink { events.append($0) }
        defer { token.cancel() }
        for (id, expiry) in [(41, UInt64(1)), (42, UInt64(Date().timeIntervalSince1970) + 3600)] {
            let value = SessionType.RequestParams(request: .init(method: "synthetic", params: AnyCodable([String]()), expiryTimestamp: expiry), chainId: Blockchain("eip155:1")!)
            try rpc.set(RPCRequest(method: "wc_sessionRequest", params: value, rpcid: RPCID(Int64(id))), forTopic: "synthetic-session", emmitedBy: .remote, transportType: .relay)
        }
        watcher.checkForRequestExpiry(); watcher.checkForRequestExpiry()
        XCTAssertEqual(events, [RPCID(41)]); XCTAssertNil(rpc.get(recordId: RPCID(41))); XCTAssertNotNil(rpc.get(recordId: RPCID(42)))
        withExtendedLifetime(watcher) { }
    }
}
