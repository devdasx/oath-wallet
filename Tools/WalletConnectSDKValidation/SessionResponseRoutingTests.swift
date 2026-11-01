import XCTest
import Combine
@testable import Schemas
@testable import WalletConnectKMS
import WalletConnectNetworking
import WalletConnectRelay
import Events

private final class RoutingEvents: EventsClientProtocol {
    func startTrace(topic: String) {}
    func saveTraceEvent(_ event: TraceEventItem) {}
    func setTopic(_ topic: String) {}
    func setTelemetryEnabled(_ enabled: Bool) {}
    func saveMessageEvent(_ event: MessageEventType) {}
}

@MainActor final class SessionResponseRoutingTests: XCTestCase {
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
          for sessionTopic in [topic, "other-session"] {
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
            let session = WCSession(topic: sessionTopic, pairingTopic: "synthetic-pairing", timestamp: Date(), selfParticipant: owner,
                peerParticipant: Participant(publicKey: "synthetic-peer", metadata: decoded), settleParams: params,
                requiredNamespaces: [:], acknowledged: true, transportType: mode, verifyContext: nil)
            // Exercise the real persisted Codable form, including optional metadata.
            sessions.setSession(try JSONDecoder().decode(WCSession.self, from: JSONEncoder().encode(session)))
        }
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
        LinkSessionRequester(sessionStore: f.sessions, linkEnvelopesDispatcher: f.dispatcher, logger: ConsoleLoggerMock(), eventsClient: RoutingEvents())
    }
    private func responder(_ f: Fixture) -> LinkSessionResponder {
        LinkSessionResponder(logger: ConsoleLoggerMock(), sessionStore: f.sessions, linkEnvelopesDispatcher: f.dispatcher,
            sessionRequestsProvider: f.provider, historyService: f.service, eventsClient: RoutingEvents())
    }

    private func check(link: Bool, storedTopic: String? = nil, origin: RPCHistory.Record.Origin = .remote,
                       outerMethod: String = "wc_sessionRequest", expired: Bool = false, valid: Bool = false) async throws {
        let f = try fixture(mode: link ? .linkMode : .relay)
        let r = request(expired: expired)
        try f.history.set(RPCRequest(method: outerMethod, params: params(r), rpcid: r.id),
                          forTopic: storedTopic ?? topic, emmitedBy: origin, transportType: link ? .linkMode : .relay)
        let network = NetworkingInteractorMock()
        let verify = CodableStore<VerifyContext>(defaults: RuntimeKeyValueStorage(), identifier: "synthetic-verify")
        let relay = SessionResponder(logger: ConsoleLoggerMock(), sessionStore: f.sessions, networkingInteractor: network,
            verifyContextStore: verify, sessionRequestsProvider: f.provider, historyService: f.service, tvfCollector: TVFCollector())
        var opened: [URL] = []
        UIApplication.shared.openHandler = { url,_,done in opened.append(url); done(true) }
        defer { UIApplication.shared.openHandler = nil }
        var threw = false
        do {
            if link {
                _ = try await responder(f).respondSessionRequest(topic: topic, requestId: r.id, response: .response(AnyCodable("synthetic-result")))
            } else {
                try await relay.respondSessionRequest(topic: topic, requestId: r.id, response: .response(AnyCodable("synthetic-result")))
            }
        } catch { threw = true }
        // If the old implementation sent an envelope, prove the requested
        // session key decrypts it; the expected rejection assertions still fail.
        if !valid, let url = opened.first {
            let envelope = try XCTUnwrap(URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "wc_ev" }?.value)
            let (result,_,_): (RPCResponse,String?,Data) = try f.serializer.deserialize(topic:topic,codingType:.base64UrlEncoded,envelopeString:envelope)
            XCTAssertEqual(result.id,r.id)
            if expired { XCTAssertEqual(result.error?.code,SignReasonCode.sessionRequestExpired.code) }
            else { XCTAssertEqual(try result.result?.get(String.self),"synthetic-result") }
        }
        if !valid {
            XCTAssertTrue(threw, "Mismatched pending request must be rejected")
            XCTAssertTrue(opened.isEmpty, "Mismatched pending request must not open a response link")
            XCTAssertNil(network.didRespondOnTopic, "Mismatched pending request must not reach relay response")
            XCTAssertFalse(network.didRespondError, "Mismatched pending request must not send a relay expiry response")
            XCTAssertNotNil(f.history.get(recordId: r.id), "Mismatched pending request must remain pending")
        } else {
            XCTAssertEqual(threw, expired)
            if link {
                XCTAssertEqual(opened.count, 1)
                XCTAssertNil(f.history.get(recordId: r.id))
                let url = try XCTUnwrap(opened.first)
                let envelope = try XCTUnwrap(URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "wc_ev" }?.value)
                let (result,_,_): (RPCResponse,String?,Data) = try f.serializer.deserialize(topic:topic,codingType:.base64UrlEncoded,envelopeString:envelope)
                XCTAssertEqual(result.id,r.id)
                if expired { XCTAssertEqual(result.error?.code, SignReasonCode.sessionRequestExpired.code) }
                else { XCTAssertEqual(try result.result?.get(String.self),"synthetic-result") }
            } else {
                XCTAssertEqual(network.didRespondOnTopic, expired ? nil : topic)
                XCTAssertEqual(network.didRespondError, expired)
                // The relay endpoint is a recorder, not a live transport/history acknowledgement.
                XCTAssertNotNil(f.history.get(recordId:r.id))
            }
        }
    }
    func testLinkRejectsOtherSessionRequest() async throws { try await check(link:true,storedTopic:"other-session") }
    func testRelayRejectsOtherSessionRequest() async throws { try await check(link:false,storedTopic:"other-session") }
    func testLinkRejectsOtherSessionExpiredRequest() async throws { try await check(link:true,storedTopic:"other-session",expired:true) }
    func testRelayRejectsOtherSessionExpiredRequest() async throws { try await check(link:false,storedTopic:"other-session",expired:true) }
    func testLinkRejectsLocallyOriginatedRequest() async throws { try await check(link:true,origin:.local) }
    func testRelayRejectsLocallyOriginatedRequest() async throws { try await check(link:false,origin:.local) }
    func testLinkRejectsOtherProtocolMethod() async throws { try await check(link:true,outerMethod:"wc_sessionUpdate") }
    func testRelayRejectsOtherProtocolMethod() async throws { try await check(link:false,outerMethod:"wc_sessionUpdate") }
    func testLinkValidResponseCompletesHistory() async throws { try await check(link:true,valid:true) }
    func testRelayValidResponseReachesEndpoint() async throws { try await check(link:false,valid:true) }
    func testLinkExpiredRequestSendsExpiryError() async throws { try await check(link:true,expired:true,valid:true) }
    func testRelayExpiredRequestSendsExpiryError() async throws { try await check(link:false,expired:true,valid:true) }
}
