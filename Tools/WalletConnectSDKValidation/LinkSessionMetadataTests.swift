import XCTest
import Combine
@testable import Schemas
@testable import WalletConnectKMS
import WalletConnectNetworking
import Events

private final class MetadataEvents: EventsClientProtocol {
    func startTrace(topic: String) {}
    func saveTraceEvent(_ event: TraceEventItem) {}
    func setTopic(_ topic: String) {}
    func setTelemetryEnabled(_ enabled: Bool) {}
    func saveMessageEvent(_ event: MessageEventType) {}
}

@MainActor final class LinkSessionMetadataTests: XCTestCase {
    private let topic = "synthetic-session"
    private let chain = Blockchain("eip155:1")!
    private enum Metadata { case missingRedirect, missingUniversal, valid }
    private struct Fixture {
        let sessions: WCSessionStorageMock
        let history: RPCHistory
        let service: HistoryService
        let provider: SessionRequestsProvider
        let dispatcher: LinkEnvelopesDispatcher
        let serializer: Serializer
    }
    private func fixture(metadata: Metadata = .valid, mode: WCSession.TransportType = .relay, missing: Bool = false) throws -> Fixture {
        let sessions = WCSessionStorageMock()
        if !missing {
            let data = Data(#"{"name":"Synthetic","description":"Metadata test","url":"https://example.invalid","icons":[],"redirect":{"native":"synthetic:","universal":"https://example.invalid/wallet","linkMode":true}}"#.utf8)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String:Any])
            if metadata == .missingRedirect { object.removeValue(forKey: "redirect") }
            if metadata == .missingUniversal {
                var redirect = try XCTUnwrap(object["redirect"] as? [String:Any]); redirect.removeValue(forKey: "universal"); object["redirect"] = redirect
            }
            let decoded = try JSONDecoder().decode(AppMetadata.self, from: JSONSerialization.data(withJSONObject: object))
            let owner = Participant(publicKey: "synthetic-owner", metadata: decoded)
            let params = SessionType.SettleParams(relay: RelayProtocolOptions(protocol: "irn", data: nil), controller: owner,
                namespaces: ["eip155": SessionNamespace(accounts: [Account(blockchain: chain, address: "synthetic")!], methods: ["personal_sign"], events: [])],
                sessionProperties: nil, scopedProperties: nil, expiry: Int64(Date().timeIntervalSince1970) + 86400, proposalRequestsResponses: nil)
            let session = WCSession(topic: topic, pairingTopic: "synthetic-pairing", timestamp: Date(), selfParticipant: owner,
                peerParticipant: Participant(publicKey: "synthetic-peer", metadata: decoded), settleParams: params,
                requiredNamespaces: [:], acknowledged: true, transportType: mode, verifyContext: nil)
            // Exercise the real persisted Codable form, including optional metadata.
            sessions.setSession(try JSONDecoder().decode(WCSession.self, from: JSONEncoder().encode(session)))
        }
        let history = RPCHistoryFactory.createForNetwork(keyValueStorage: RuntimeKeyValueStorage())
        let service = HistoryService(history: history, verifyContextStore: CodableStore(defaults: RuntimeKeyValueStorage(), identifier: "synthetic-context"))
        let kms = KeyManagementServiceMock(); try kms.setSymmetricKey(SymmetricKey(rawRepresentation: Data(repeating: 6, count: 32)), for: topic)
        let serializer = Serializer(kms: kms, logger: ConsoleLoggerMock())
        return Fixture(sessions: sessions, history: history, service: service, provider: SessionRequestsProvider(historyService: service),
            dispatcher: LinkEnvelopesDispatcher(serializer: serializer, logger: ConsoleLoggerMock(), rpcHistory: history), serializer: serializer)
    }
    private func request(method: String = "personal_sign", chain: Blockchain? = nil, expired: Bool = false) -> Schemas.Request {
        Schemas.Request(id: RPCID(42), topic: topic, method: method, params: AnyCodable(["synthetic"]), chainId: chain ?? self.chain,
                        expiryTimestamp: UInt64(Date().timeIntervalSince1970) + (expired ? 0 : 300) - (expired ? 30 : 0))
    }
    private func params(_ request: Schemas.Request) -> SessionType.RequestParams {
        SessionType.RequestParams(request: .init(method: request.method, params: request.params, expiryTimestamp: request.expiryTimestamp), chainId: request.chainId)
    }
    private func store(_ r: Schemas.Request, in f: Fixture) throws {
        try f.history.set(RPCRequest(method: "wc_sessionRequest", params: params(r), rpcid: r.id), forTopic: topic, emmitedBy: .remote, transportType: .linkMode)
    }
    private func sender(_ f: Fixture) -> LinkSessionRequester {
        LinkSessionRequester(sessionStore: f.sessions, linkEnvelopesDispatcher: f.dispatcher, logger: ConsoleLoggerMock(), eventsClient: MetadataEvents())
    }
    private func responder(_ f: Fixture) -> LinkSessionResponder {
        LinkSessionResponder(logger: ConsoleLoggerMock(), sessionStore: f.sessions, linkEnvelopesDispatcher: f.dispatcher,
            sessionRequestsProvider: f.provider, historyService: f.service, eventsClient: MetadataEvents())
    }
    private func rejectSend(metadata: Metadata, missing: Bool = false, method: String = "personal_sign") async throws {
        let f = try fixture(metadata: metadata, mode: .linkMode, missing: missing)
        var opens = 0
        UIApplication.shared.openHandler = { _,_,done in opens += 1; done(true) }; defer { UIApplication.shared.openHandler = nil }
        do { _ = try await sender(f).request(request(method: method)); XCTFail("Invalid link send must throw") } catch {}
        XCTAssertEqual(opens, 0); XCTAssertTrue(f.history.getPending().isEmpty)
    }
    private func rejectResponse(metadata: Metadata, missing: Bool = false) async throws {
        let f = try fixture(metadata: metadata, mode: .linkMode, missing: missing); let r = request(); try store(r,in:f)
        var opens = 0
        UIApplication.shared.openHandler = { _,_,done in opens += 1; done(true) }; defer { UIApplication.shared.openHandler = nil }
        do { _ = try await responder(f).respondSessionRequest(topic: topic, requestId: r.id, response: .response(AnyCodable("synthetic"))); XCTFail("Invalid link response must throw") } catch {}
        XCTAssertEqual(opens, 0); XCTAssertNotNil(f.history.get(recordId: r.id))
    }
    func testSenderMissingRedirectThrowsWithoutTrapping() async throws { try await rejectSend(metadata: .missingRedirect) }
    func testSenderMissingUniversalThrowsWithoutTrapping() async throws { try await rejectSend(metadata: .missingUniversal) }
    func testResponderMissingRedirectThrowsWithoutTrapping() async throws { try await rejectResponse(metadata: .missingRedirect) }
    func testResponderMissingUniversalPreservesPendingRequest() async throws { try await rejectResponse(metadata: .missingUniversal) }
    func testMissingSessionSendIsRejected() async throws { try await rejectSend(metadata: .valid, missing: true) }
    func testMissingSessionResponseIsRejected() async throws { try await rejectResponse(metadata: .valid, missing: true) }
    func testUnauthorizedSendIsRejectedBeforeMetadata() async throws { try await rejectSend(metadata: .missingRedirect, method: "eth_sendTransaction") }

    private func receive(metadata: Metadata = .valid, method: String = "personal_sign", chain: Blockchain? = nil, expired: Bool = false,
                         valid: Bool = false, existingLink: Bool = false) throws {
        let f = try fixture(metadata: metadata, mode: existingLink ? .linkMode : .relay)
        let r = request(method: method, chain: chain, expired: expired)
        if valid { try store(r,in:f) }
        let subscriber = LinkSessionRequestSubscriber(sessionRequestsProvider: f.provider, sessionStore: f.sessions,
            logger: ConsoleLoggerMock(), envelopesDispatcher: f.dispatcher, eventsClient: MetadataEvents())
        var emitted = 0; let observer = f.provider.sessionRequestPublisher.sink { _ in emitted += 1 }
        let payload = RequestSubscriptionPayload(id: r.id, topic: topic, request: params(r), decryptedPayload: Data(),
            publishedAt: Date(), derivedTopic: nil, encryptedMessage: "", attestation: nil)
        subscriber.onSessionRequest(payload: payload)
        XCTAssertEqual(f.sessions.getSession(forTopic: topic)?.transportType, valid || existingLink ? .linkMode : .relay,
                       "Rejected incoming request must preserve session transport")
        XCTAssertEqual(emitted, valid ? 1 : 0)
        withExtendedLifetime((subscriber, observer)) {}
    }
    func testMissingRedirectDoesNotUpgradeSession() throws { try receive(metadata: .missingRedirect) }
    func testMissingUniversalDoesNotUpgradeSession() throws { try receive(metadata: .missingUniversal) }
    func testUnauthorizedChainDoesNotUpgradeSession() throws { try receive(chain: Blockchain("solana:mainnet")!) }
    func testUnauthorizedMethodDoesNotUpgradeSession() throws { try receive(method: "eth_sendTransaction") }
    func testExpiredRequestDoesNotUpgradeSession() throws { try receive(expired: true) }
    func testValidIncomingRequestUpgradesAndEmits() throws { try receive(valid: true) }
    func testExistingLinkSessionStillEmits() throws { try receive(valid: true, existingLink: true) }

    func testValidSendUsesEncryptedLinkAndKeepsPendingRecord() async throws {
        let f = try fixture(mode: .linkMode); let r = request(); var opens = [URL]()
        UIApplication.shared.openHandler = { url,options,done in XCTAssertEqual(options[.universalLinksOnly], true); opens.append(url); done(true) }
        defer { UIApplication.shared.openHandler = nil }
        let result = try await sender(f).request(r)
        let link = try XCTUnwrap(result); XCTAssertEqual(opens.count, 1)
        let url = try XCTUnwrap(URLComponents(string: link)); XCTAssertEqual(url.host, "example.invalid")
        let envelope = try XCTUnwrap(url.queryItems?.first { $0.name == "wc_ev" }?.value)
        let (decoded,_,_): (RPCRequest, String?, Data) = try f.serializer.deserialize(topic: topic, codingType: .base64UrlEncoded, envelopeString: envelope)
        XCTAssertEqual(decoded.id, r.id); XCTAssertEqual(decoded.method, "wc_sessionRequest")
        XCTAssertNotNil(f.history.get(recordId: r.id))
    }
    func testValidResponseUsesEncryptedLinkAndCompletesHistory() async throws {
        let f = try fixture(mode: .linkMode); let r = request(); try store(r,in:f); var opens = 0
        UIApplication.shared.openHandler = { _,options,done in XCTAssertEqual(options[.universalLinksOnly], true); opens += 1; done(true) }
        defer { UIApplication.shared.openHandler = nil }
        let link = try await responder(f).respondSessionRequest(topic: topic, requestId: r.id, response: .response(AnyCodable("synthetic")))
        XCTAssertEqual(opens,1); XCTAssertNil(f.history.get(recordId:r.id))
        let envelope = try XCTUnwrap(URLComponents(string: link)?.queryItems?.first { $0.name == "wc_ev" }?.value)
        let (decoded,_,_): (RPCResponse,String?,Data) = try f.serializer.deserialize(topic:topic,codingType:.base64UrlEncoded,envelopeString:envelope)
        XCTAssertEqual(decoded.id,r.id); XCTAssertEqual(try decoded.result?.get(String.self),"synthetic")
    }
}
