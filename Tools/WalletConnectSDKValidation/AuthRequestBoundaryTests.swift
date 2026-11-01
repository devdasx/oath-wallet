import XCTest
@testable import Schemas
@testable import WalletConnectNetworking
import Events

private final class AuthRelaySpy: NetworkingInteractorMock {
    var payloads: [RPCRequest] = []
    var configs: [RelayConfig] = []
    override func request(_ request: RPCRequest, topic: String, protocolMethod: ProtocolMethod,
                          envelopeType: Envelope.EnvelopeType, tvfData: TVFData?) async throws {
        payloads.append(request); configs.append(protocolMethod.requestConfig)
    }
}
private final class AuthLinkSpy: LinkEnvelopeRequesting {
    var payloads: [RPCRequest] = []
    var links: [String] = []
    func request(topic: String, request: RPCRequest, peerUniversalLink: String,
                 envelopeType: Envelope.EnvelopeType) async throws -> String {
        payloads.append(request); links.append(peerUniversalLink)
        return "synthetic-envelope"
    }
}
private final class AuthEventsSpy: EventsClientProtocol {
    func startTrace(topic: String) { }
    func saveTraceEvent(_ event: TraceEventItem) { }
    func setTopic(_ topic: String) { }
    func setTelemetryEnabled(_ enabled: Bool) { }
    func saveMessageEvent(_ event: MessageEventType) { }
}

final class AuthRequestBoundaryTests: XCTestCase {
    private let link = "https://example.invalid/wallet"
    private func params(chains: [String] = ["eip155:1"], ttl: TimeInterval = 3600) throws -> AuthRequestParams {
        try AuthRequestParams(domain: "example.invalid", chains: chains, nonce: "synthetic-nonce",
            uri: "https://example.invalid/login", nbf: nil, exp: nil, statement: "Synthetic test", requestId: "fixture",
            resources: ["https://example.invalid/resource"], methods: ["personal_sign"],
            signatureTypes: ["eip155": ["eip191"]], ttl: ttl)
    }
    private func decodedTTL(_ value: Any) throws -> AuthRequestParams {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(params())) as? [String: Any])
        object["ttl"] = value
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try decoder.decode(AuthRequestParams.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func metadata() -> AppMetadata {
        AppMetadata(name: "Synthetic", description: "Auth input fixture", url: "https://example.invalid", icons: [],
                    redirect: try! AppMetadata.Redirect(native: "", universal: nil))
    }
    private struct Fixture {
        let relay: SessionAuthRequestService
        let link: LinkAuthRequester
        let kms: KeyManagementServiceMock
        let network: AuthRelaySpy
        let dispatcher: AuthLinkSpy
        let records: CodableStore<AuthResponseTopicRecord>
    }
    private func fixture(provenLink: Bool = true) -> Fixture {
        let kms = KeyManagementServiceMock(); let network = AuthRelaySpy(); let dispatcher = AuthLinkSpy()
        let records = CodableStore<AuthResponseTopicRecord>(defaults: RuntimeKeyValueStorage(), identifier: "synthetic-auth-records")
        let links = CodableStore<Bool>(defaults: RuntimeKeyValueStorage(), identifier: "synthetic-links")
        if provenLink { links.set(true, forKey: link) }
        let relay = SessionAuthRequestService(networkingInteractor: network, kms: kms, appMetadata: metadata(),
            logger: ConsoleLoggerMock(), iatProvader: DefaultIATProvider(), authResponseTopicRecordsStore: records)
        let sender = LinkAuthRequester(kms: kms, appMetadata: metadata(), logger: ConsoleLoggerMock(),
            iatProvader: DefaultIATProvider(), authResponseTopicRecordsStore: records, linkEnvelopesDispatcher: dispatcher,
            linkModeLinksStore: links, eventsClient: AuthEventsSpy())
        return Fixture(relay: relay, link: sender, kms: kms, network: network, dispatcher: dispatcher, records: records)
    }
    private func send(_ value: AuthRequestParams, through f: Fixture, linkMode: Bool) async throws {
        if linkMode { _ = try await f.link.request(params: value, walletUniversalLink: link) }
        else { try await f.relay.request(params: value, topic: "synthetic-pairing") }
    }
    private func assertNoSideEffects(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.kms.privateKeys.count, 0, "Rejected auth must not create keys", file: file, line: line)
        XCTAssertEqual(f.kms.publicKeys.count, 0, "Rejected auth must not store response keys", file: file, line: line)
        XCTAssertEqual(f.records.getAll().count, 0, "Rejected auth must not store response topics", file: file, line: line)
        XCTAssertEqual(f.network.payloads.count + f.dispatcher.payloads.count, 0, "Rejected auth must not send", file: file, line: line)
        XCTAssertEqual(f.network.subscriptions.count, 0, "Rejected auth must not subscribe", file: file, line: line)
    }
    func testDecodedOutOfRangeTTLIsRejected() throws {
        for value in [-1.0, 0.0, 299.0, 604801.0, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try decodedTTL(value), "Decoded TTL must respect constructor bounds")
        }
    }
    func testDecodedNonfiniteTTLIsRejected() throws {
        for value in ["NaN", "Infinity", "-Infinity"] {
            XCTAssertThrowsError(try decodedTTL(value), "Decoded TTL must reject nonfinite values")
        }
    }
    private func rejectDirectTTL(_ ttl: TimeInterval) throws {
        let value = try params(); let payload = AuthPayload(requestParams: value, iat: "2026-01-01T00:00:00Z")
        XCTAssertThrowsError(try SessionAuthenticateRequestParams(requester: Participant(publicKey: "synthetic", metadata: metadata()),
            authPayload: payload, ttl: ttl), "Auth expiry construction must reject invalid TTL")
    }
    func testNegativeDirectTTLDoesNotTrap() throws { try rejectDirectTTL(-1) }
    func testNaNDirectTTLDoesNotTrap() throws { try rejectDirectTTL(.nan) }
    func testInfiniteDirectTTLDoesNotTrap() throws { try rejectDirectTTL(.infinity) }
    func testHugeDirectTTLDoesNotTrap() throws { try rejectDirectTTL(.greatestFiniteMagnitude) }

    private func reject(chains: [String], linkMode: Bool) async throws {
        let f = fixture()
        do { try await send(params(chains: chains), through: f, linkMode: linkMode); XCTFail("Invalid auth chains must throw") }
        catch { }
        assertNoSideEffects(f)
    }
    func testEmptyRelayChainsDoNotTrap() async throws { try await reject(chains: [], linkMode: false) }
    func testEmptyLinkChainsDoNotTrap() async throws { try await reject(chains: [], linkMode: true) }
    func testUnsupportedRelayChainDoesNotCreateKeys() async throws { try await reject(chains: ["solana:mainnet"], linkMode: false) }
    func testUnsupportedLinkChainDoesNotCreateKeys() async throws { try await reject(chains: ["solana:mainnet"], linkMode: true) }
    func testMixedRelayChainsDoNotSend() async throws { try await reject(chains: ["eip155:1", "solana:mainnet"], linkMode: false) }
    func testMixedLinkChainsDoNotSend() async throws { try await reject(chains: ["eip155:1", "solana:mainnet"], linkMode: true) }
    func testMalformedTrailingRelayChainDoesNotSend() async throws { try await reject(chains: ["eip155:1", "bad"], linkMode: false) }
    func testMalformedTrailingLinkChainDoesNotSend() async throws { try await reject(chains: ["eip155:1", "bad"], linkMode: true) }
    private func rejectDecoded(ttl: Any, linkMode: Bool) async {
        let f = fixture()
        do { try await send(decodedTTL(ttl), through: f, linkMode: linkMode); XCTFail("Invalid decoded auth must throw") }
        catch { }
        assertNoSideEffects(f)
    }
    func testNegativeDecodedRelayTTLDoesNotTrap() async { await rejectDecoded(ttl: -1, linkMode: false) }
    func testHugeDecodedLinkTTLDoesNotTrap() async { await rejectDecoded(ttl: Double.greatestFiniteMagnitude, linkMode: true) }

    private func valid(linkMode: Bool) async throws {
        for ttl in [300.0, 3600.0, 604800.0] {
            let f = fixture(); let value = try params(chains: ["eip155:1", "eip155:137"], ttl: ttl)
            let before = UInt64(Date().timeIntervalSince1970)
            try await send(value, through: f, linkMode: linkMode)
            let after = UInt64(Date().timeIntervalSince1970)
            let request = try XCTUnwrap((linkMode ? f.dispatcher.payloads : f.network.payloads).first)
            let body = try XCTUnwrap(request.params).get(SessionAuthenticateRequestParams.self)
            XCTAssertEqual(request.method, "wc_sessionAuthenticate")
            XCTAssertEqual(body.authPayload.chains, value.chains); XCTAssertEqual(body.authPayload.domain, value.domain)
            XCTAssertEqual(body.authPayload.nonce, value.nonce); XCTAssertEqual(body.authPayload.signatureTypes, value.signatureTypes)
            XCTAssertTrue((before + UInt64(ttl)...after + UInt64(ttl)).contains(body.expiryTimestamp))
            XCTAssertEqual(f.records.getAll().count, 1); XCTAssertEqual(f.kms.privateKeys.count, 1); XCTAssertEqual(f.kms.publicKeys.count, 1)
            XCTAssertEqual(request.expectedResponseTopic, Data(hex: body.requester.publicKey).sha256().toHexString())
            if linkMode { XCTAssertEqual(f.dispatcher.links, [link]); XCTAssertTrue(f.network.payloads.isEmpty) }
            else { XCTAssertEqual(f.network.configs.map(\.ttl), [Int(ttl)]); XCTAssertEqual(f.network.subscriptions.count, 1) }
        }
    }
    func testValidRelayBoundsAndRoutingArePreserved() async throws { try await valid(linkMode: false) }
    func testValidLinkBoundsAndRoutingArePreserved() async throws { try await valid(linkMode: true) }
    func testGeneralAuthModelPreservesOtherChainFamilies() throws {
        let value = try params(chains: ["solana:mainnet", "bip122:000000000019d6689c085ae165831e93"])
        let decoded = try JSONDecoder().decode(AuthRequestParams.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.chains, value.chains); XCTAssertEqual(decoded.ttl, value.ttl)
        XCTAssertEqual(decoded.legacyMethods, value.legacyMethods); XCTAssertEqual(decoded.resources, value.resources)
    }
    func testUnprovenLinkDoesNotCreateKeys() async throws {
        let f = fixture(provenLink: false)
        do { try await send(params(), through: f, linkMode: true); XCTFail("Unproven link must throw") }
        catch { }
        assertNoSideEffects(f)
    }
}
