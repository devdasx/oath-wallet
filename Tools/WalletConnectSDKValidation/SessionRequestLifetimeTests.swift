import XCTest
@testable import Schemas
@testable import WalletConnectNetworking

private enum SyntheticTransportError: Error { case unavailable }

private final class RequestTransportSpy: NetworkingInteractorMock {
    var configs: [RelayConfig] = []
    var payloads: [RPCRequest] = []
    var fail = false
    override func request(_ request: RPCRequest, topic: String, protocolMethod: ProtocolMethod,
                          envelopeType: Envelope.EnvelopeType, tvfData: TVFData?) async throws {
        configs.append(protocolMethod.requestConfig)
        payloads.append(request)
        if fail { throw SyntheticTransportError.unavailable }
    }
}

private final class WalletServiceSpy: WalletServiceSessionRequestable {
    var requests: [Schemas.Request] = []
    var urls: [URL] = []
    var fail = false
    func request(_ request: Schemas.Request, to url: URL) async throws -> AnyCodable {
        requests.append(request); urls.append(url)
        if fail { throw SyntheticTransportError.unavailable }
        return AnyCodable("synthetic-result")
    }
}

final class SessionRequestLifetimeTests: XCTestCase {
    private let chain = Blockchain("eip155:1")!
    private func session(service: Bool, acknowledged: Bool = true) -> WCSession {
        let metadata = AppMetadata(name: "Synthetic", description: "Request lifetime fixture", url: "https://example.invalid", icons: [],
                                   redirect: try! AppMetadata.Redirect(native: "", universal: nil))
        let owner = Participant(publicKey: "synthetic-owner", metadata: metadata)
        let properties = service ? ["eip155:1": "{\"walletService\":[{\"url\":\"https://example.invalid/rpc\",\"methods\":[\"wallet_getAssets\"]}]}"] : nil
        let params = SessionType.SettleParams(relay: RelayProtocolOptions(protocol: "irn", data: nil), controller: owner,
            namespaces: ["eip155": SessionNamespace(accounts: [Account(blockchain: chain, address: "synthetic")!], methods: ["wallet_getAssets"], events: [])],
            sessionProperties: nil, scopedProperties: properties, expiry: Int64(Date().timeIntervalSince1970) + 86400, proposalRequestsResponses: nil)
        return WCSession(topic: "synthetic-session", pairingTopic: "synthetic-pairing", timestamp: Date(), selfParticipant: owner,
            peerParticipant: Participant(publicKey: "synthetic-peer", metadata: metadata), settleParams: params,
            requiredNamespaces: [:], acknowledged: acknowledged, transportType: .relay, verifyContext: nil)
    }
    private func request(expiry: UInt64?, method: String = "wallet_getAssets", chain: Blockchain? = nil) -> Schemas.Request {
        Schemas.Request(id: RPCID(42), topic: "synthetic-session", method: method,
                        params: AnyCodable(["address": "synthetic"]), chainId: chain ?? self.chain, expiryTimestamp: expiry)
    }
    private func fixture(service: Bool = false, acknowledged: Bool = true, missing: Bool = false)
        -> (SessionRequester, RequestTransportSpy, WalletServiceSpy) {
        let storage = WCSessionStorageMock()
        if !missing { storage.setSession(session(service: service, acknowledged: acknowledged)) }
        let network = RequestTransportSpy(); let wallet = WalletServiceSpy()
        return (SessionRequester(sessionStore: storage, networkingInteractor: network, logger: ConsoleLoggerMock(),
                                 tvfCollector: TVFCollectorMock(), walletServiceRequester: wallet), network, wallet)
    }

    private func checkRelayLifetime(seconds: UInt64) async throws {
        let (subject, network, wallet) = fixture()
        let value = request(expiry: UInt64(Date().timeIntervalSince1970) + seconds)
        let before = try value.calculateTtl()
        try await subject.request(value)
        let after = try value.calculateTtl()
        let config = try XCTUnwrap(network.configs.first)
        XCTAssertEqual(network.configs.count, 1)
        XCTAssertTrue((after...before).contains(config.ttl), "Relay TTL must follow request expiry")
        XCTAssertEqual(config.tag, 1108); XCTAssertTrue(config.prompt)
        let rpc = try XCTUnwrap(network.payloads.first)
        XCTAssertEqual(rpc.id, value.id); XCTAssertEqual(rpc.method, "wc_sessionRequest")
        let params = try XCTUnwrap(rpc.params).get(SessionType.RequestParams.self)
        XCTAssertEqual(params.chainId, value.chainId)
        XCTAssertEqual(params.request.expiryTimestamp, value.expiryTimestamp)
        XCTAssertEqual(params.request.method, value.method)
        XCTAssertEqual(params.request.params, value.params)
        XCTAssertTrue(wallet.requests.isEmpty)
    }
    func testCustomRelayLifetimeIsPreserved() async throws { try await checkRelayLifetime(seconds: 3600) }
    func testElapsedRelayLifetimeIsNotReset() async throws { try await checkRelayLifetime(seconds: 60) }

    func testMissingExpiryRetainsDefaultLifetime() async throws {
        let (subject, network, wallet) = fixture()
        try await subject.request(request(expiry: nil))
        XCTAssertEqual(network.configs.map(\.ttl), [300]); XCTAssertTrue(wallet.requests.isEmpty)
    }

    private func reject(expiry: UInt64, service: Bool, expired: Bool) async {
        let (subject, network, wallet) = fixture(service: service)
        do { try await subject.request(request(expiry: expiry)); XCTFail("Invalid request lifetime must throw") }
        catch let error as Schemas.Request.Errors {
            switch (error, expired) {
            case (.requestExpired, true), (.invalidTtl, false): break
            default: XCTFail("Wrong request lifetime error")
            }
        } catch { XCTFail("Unexpected request lifetime error") }
        XCTAssertTrue(network.configs.isEmpty, "Rejected request must not reach relay")
        XCTAssertTrue(wallet.requests.isEmpty, "Rejected request must not reach wallet service")
    }
    func testExpiredRelayRequestIsRejected() async { await reject(expiry: 1, service: false, expired: true) }
    func testUnboundedRelayRequestIsRejected() async { await reject(expiry: .max, service: false, expired: false) }
    func testExpiredWalletServiceRequestIsRejected() async { await reject(expiry: 1, service: true, expired: true) }
    func testUnboundedWalletServiceRequestIsRejected() async { await reject(expiry: .max, service: true, expired: false) }

    func testValidWalletServiceRequestIsPreserved() async throws {
        let (subject, network, wallet) = fixture(service: true)
        let value = request(expiry: UInt64(Date().timeIntervalSince1970) + 3600)
        try await subject.request(value)
        XCTAssertEqual(wallet.requests, [value]); XCTAssertEqual(wallet.urls.map(\.absoluteString), ["https://example.invalid/rpc"])
        XCTAssertTrue(network.configs.isEmpty)
    }

    func testPermissionFailuresDoNotReachEitherTransport() async {
        for service in [false, true] {
            for value in [request(expiry: nil, method: "eth_sendTransaction"), request(expiry: nil, chain: Blockchain("eip155:137")!)] {
                let (subject, network, wallet) = fixture(service: service)
                do { try await subject.request(value); XCTFail("Missing permission must throw") }
                catch WalletConnectError.invalidPermissions { }
                catch { XCTFail("Unexpected permission error") }
                XCTAssertTrue(network.configs.isEmpty); XCTAssertTrue(wallet.requests.isEmpty)
            }
        }
    }
    func testMissingAndUnacknowledgedSessionsCannotSend() async throws {
        for missing in [false, true] {
            let (subject, network, wallet) = fixture(service: true, acknowledged: false, missing: missing)
            try await subject.request(request(expiry: nil))
            XCTAssertTrue(network.configs.isEmpty); XCTAssertTrue(wallet.requests.isEmpty)
        }
    }
    func testTransportFailureIsPropagatedWithoutFallback() async {
        for service in [false, true] {
            let (subject, network, wallet) = fixture(service: service); network.fail = true; wallet.fail = true
            do { try await subject.request(request(expiry: nil)); XCTFail("Transport failure must propagate") }
            catch SyntheticTransportError.unavailable { }
            catch { XCTFail("Unexpected transport error") }
            XCTAssertEqual(network.configs.count, service ? 0 : 1)
            XCTAssertEqual(wallet.requests.count, service ? 1 : 0)
        }
    }
}
