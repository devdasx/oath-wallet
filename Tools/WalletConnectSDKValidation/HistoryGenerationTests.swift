import XCTest
import Foundation
import Combine
import JSONRPC
@testable import Schemas
@testable import WalletConnectUtils
@testable import WalletConnectKMS
@testable import WalletConnectRelay
@testable import WalletConnectNetworking

private enum GenerationFailure: Error { case sendFailed, unused }
private struct GenerationClock: TimeProvider {
    var currentDate: Date { Date(timeIntervalSince1970: 1_793_500_000) }
}
private final class GenerationIdentity: ClientIdStoring {
    func getOrCreateKeyPair() throws -> SigningPrivateKey { throw GenerationFailure.unused }
    func getClientId() throws -> String { throw GenerationFailure.unused }
}
private final class GenerationDispatcher: Dispatching {
    var onMessage: ((String) -> Void)?
    var onSend: (@MainActor (String) throws -> Void)?
    var isSocketConnected: Bool { true }
    var networkConnectionStatusPublisher: AnyPublisher<NetworkConnectionStatus,Never> { Just(.connected).eraseToAnyPublisher() }
    var socketConnectionStatusPublisher: AnyPublisher<SocketConnectionStatus,Never> { Just(.disconnected).eraseToAnyPublisher() }
    private let lock = NSLock()
    private var pumps: [Task<Void,Never>] = []
    func protectedSend(_ string: String,connectUnconditionally: Bool,completion: @escaping (Error?) -> Void) { completion(nil) }
    func protectedSend(_ string: String,connectUnconditionally: Bool) async throws {
        try await onSend?(string)
        let request = try JSONDecoder().decode(RPCRequest.self,from:Data(string.utf8))
        if request.method == "irn_publish", let id = request.id {
            let acknowledgement = try RPCResponse(id:id,result:true).asJSONEncodedString()
            // RelayClient subscribes to acknowledgements after protectedSend returns.
            // Repeated synthetic ACKs isolate history completion from that separate
            // early-ACK ordering concern. This is not a live-relay timing test.
            let pump = Task { [weak self] in
                for _ in 0..<100 {
                    if Task.isCancelled { break }
                    self?.onMessage?(acknowledgement)
                    do { try await Task.sleep(nanoseconds: 20_000_000) } catch { break }
                }
            }
            lock.withLock { pumps.append(pump) }
        }
    }
    func stop() { lock.withLock { pumps.forEach { $0.cancel() }; pumps.removeAll() } }
    func connect() throws {}
    func disconnect(closeCode: URLSessionWebSocketTask.CloseCode) throws {}
}

@MainActor final class HistoryGenerationTests: XCTestCase {
    private let topic = "synthetic-topic", settleTopic = "synthetic-settlement"
    private struct Method: ProtocolMethod {
        let method = "wc_sessionPing"
        let requestConfig = RelayConfig(tag:1114,prompt:false,ttl:30)
        let responseConfig = RelayConfig(tag:1115,prompt:false,ttl:30)
    }
    private struct Fixture {
        let storage: RuntimeKeyValueStorage
        let history: RPCHistory
        let serializer: Serializer
        let dispatcher: GenerationDispatcher
        let relay: RelayClient
        let network: NetworkingInteractor
        let link: LinkEnvelopesDispatcher
    }
    private func fixture() throws -> Fixture {
        let storage = RuntimeKeyValueStorage(), dispatcher = GenerationDispatcher(), logger = ConsoleLoggerMock()
        let history = RPCHistoryFactory.createForNetwork(keyValueStorage:storage)
        let kms = KeyManagementServiceMock()
        for (name,byte) in [(topic,UInt8(6)),(settleTopic,UInt8(7))] {
            try kms.setSymmetricKey(SymmetricKey(rawRepresentation:Data(repeating:byte,count:32)),for:name)
        }
        let serializer = Serializer(kms:kms,logger:logger)
        let relay = RelayClient(dispatcher:dispatcher,logger:logger,
            rpcHistory:RPCHistoryFactory.createForRelay(keyValueStorage:RuntimeKeyValueStorage()),
            clientIdStorage:GenerationIdentity(),subscriptionsTracker:SubscriptionsTracker(logger:logger),topicsTracker:TopicsTracker())
        return Fixture(storage:storage,history:history,serializer:serializer,dispatcher:dispatcher,relay:relay,
            network:NetworkingInteractor(relayClient:relay,serializer:serializer,logger:logger,rpcHistory:history),
            link:LinkEnvelopesDispatcher(serializer:serializer,logger:logger,rpcHistory:history))
    }
    private func request(_ id: Int64 = 42, method: String = "wc_sessionPing") -> RPCRequest {
        RPCRequest(method:method,params:[String:String](),id:id)
    }
    private func store(_ request: RPCRequest,in f: Fixture,origin: RPCHistory.Record.Origin = .remote) throws {
        try f.history.set(request,forTopic:topic,emmitedBy:origin,time:GenerationClock(),transportType:.relay)
    }
    private func replace(_ request: RPCRequest,in f: Fixture,origin: RPCHistory.Record.Origin = .remote) throws {
        // Same ID, topic, origin, method, params, time and transport. Content or
        // timestamp comparison alone must not mistake a replacement for its predecessor.
        let reopened = RPCHistoryFactory.createForNetwork(keyValueStorage:f.storage)
        reopened.delete(id:request.id!); try reopened.set(request,forTopic:topic,emmitedBy:origin,time:GenerationClock(),transportType:.relay)
    }
    private func makeLegacy(_ f: Fixture) throws {
        for (key,value) in f.storage.dictionaryRepresentation() {
            guard let data = value as? Data else { continue }
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
            object.removeValue(forKey:"generation")
            f.storage.set(try JSONSerialization.data(withJSONObject:object),forKey:key)
        }
    }
    private func linkResponse(replaced: Bool,legacy: Bool = false,fail: Bool = false) async throws {
        let f = try fixture(), r = request(); try store(r,in:f); if legacy { try makeLegacy(f) }
        var opened = 0
        UIApplication.shared.openHandler = { url,_,done in
            opened += 1
            do {
                let encoded = try XCTUnwrap(URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "wc_ev" }?.value)
                let (decoded,_,raw): (RPCResponse,String?,Data) = try f.serializer.deserialize(topic:self.topic,codingType:.base64UrlEncoded,envelopeString:encoded)
                XCTAssertEqual(decoded.id,r.id)
                let wire = try XCTUnwrap(JSONSerialization.jsonObject(with:raw) as? [String:Any]); XCTAssertNil(wire["generation"])
                if replaced { try self.replace(r,in:f) }
                done(!fail)
            } catch { XCTFail("Fixture failed: \(error)"); done(false) }
        }
        defer { UIApplication.shared.openHandler = nil; f.dispatcher.stop() }
        var threw = false
        do { _ = try await f.link.respond(topic:topic,response:RPCResponse(id:r.id!,result:true),peerUniversalLink:"https://example.invalid/wallet",envelopeType:.type0) }
        catch { threw = true }
        XCTAssertEqual(opened,1)
        XCTAssertEqual(threw,replaced || fail,"Changed history must reject stale response completion")
        XCTAssertEqual(f.history.get(recordId:r.id!) != nil,replaced || fail,"Response completion must preserve the replacement record")
    }
    private func failedRequest(link: Bool,replaced: Bool,separateResponseTopic: Bool = false) async throws {
        let f = try fixture(), r = separateResponseTopic ? request().expectingResponse(on:"synthetic-response-topic") : request(); var sent = 0
        if link {
            UIApplication.shared.openHandler = { _,_,done in
                sent += 1
                if replaced { do { try self.replace(r,in:f,origin:.local) } catch { XCTFail("Fixture failed: \(error)") } }
                done(false)
            }
        } else {
            f.dispatcher.onSend = { _ in
                sent += 1
                if replaced { try self.replace(r,in:f,origin:.local) }
                throw GenerationFailure.sendFailed
            }
        }
        defer { UIApplication.shared.openHandler = nil; f.dispatcher.stop() }
        var threw = false
        do {
            if link { _ = try await f.link.request(topic:topic,request:r,peerUniversalLink:"https://example.invalid/wallet",envelopeType:.type0) }
            else { try await f.network.request(r,topic:topic,protocolMethod:Method()) }
        } catch { threw = true }
        XCTAssertTrue(threw); XCTAssertEqual(sent,1)
        XCTAssertEqual(f.history.get(recordId:r.id!) != nil,replaced,"Failed request rollback must preserve a replacement record")
    }
    private func relayResponse(replaced: Bool,approve: Bool = false) async throws {
        let f = try fixture(), r = request(method:approve ? "wc_sessionPropose" : "wc_sessionPing")
        try store(r,in:f); var sent = 0
        f.dispatcher.onSend = { frame in
            sent += 1
            let object = try JSONDecoder().decode(RPCRequest.self,from:Data(frame.utf8))
            XCTAssertEqual(object.method,approve ? "wc_approveSession" : "irn_publish")
            if replaced { try self.replace(r,in:f) }
        }
        defer { f.dispatcher.stop() }
        var threw = false
        do {
            if approve {
                try await f.network.approveSession(pairingTopic:topic,sessionTopic:settleTopic,
                    sessionProposalResponse:RPCResponse(id:r.id!,result:true),sessionSettleRequest:request(43,method:"wc_sessionSettle"),
                    approvedChains:["eip155:1"],approvedMethods:["personal_sign"],approvedEvents:[])
            } else { try await f.network.respond(topic:topic,response:RPCResponse(id:r.id!,result:true),protocolMethod:Method()) }
        } catch { threw = true }
        XCTAssertEqual(sent,1)
        XCTAssertEqual(threw,replaced,"Changed history must reject stale response completion")
        XCTAssertEqual(f.history.get(recordId:r.id!) != nil,replaced,"Response completion must preserve the replacement record")
        if approve { XCTAssertEqual(f.history.get(recordId:RPCID(43))?.topic,settleTopic) }
    }
    func testLinkResponsePreservesIdenticalReplacement() async throws { try await linkResponse(replaced:true) }
    func testLinkLegacyResponsePreservesReplacement() async throws { try await linkResponse(replaced:true,legacy:true) }
    func testLinkFailedRequestPreservesReplacement() async throws { try await failedRequest(link:true,replaced:true) }
    func testRelayResponsePreservesIdenticalReplacement() async throws { try await relayResponse(replaced:true) }
    func testRelayFailedRequestPreservesReplacement() async throws { try await failedRequest(link:false,replaced:true) }
    func testRelayApprovalPreservesReplacement() async throws { try await relayResponse(replaced:true,approve:true) }
    func testLinkResponseSuccessCompletesOriginal() async throws { try await linkResponse(replaced:false) }
    func testLinkLegacyResponseSuccessCompletesOriginal() async throws { try await linkResponse(replaced:false,legacy:true) }
    func testLinkFailedResponsePreservesOriginal() async throws { try await linkResponse(replaced:false,fail:true) }
    func testLinkFailedRequestRemovesOriginal() async throws { try await failedRequest(link:true,replaced:false) }
    func testRelayResponseSuccessCompletesOriginal() async throws { try await relayResponse(replaced:false) }
    func testRelayFailedRequestRemovesOriginal() async throws { try await failedRequest(link:false,replaced:false) }
    func testFailedRequestWithResponseRoutingRemovesOriginal() async throws { try await failedRequest(link:false,replaced:false,separateResponseTopic:true) }
    func testRelayApprovalSuccessCompletesOriginal() async throws { try await relayResponse(replaced:false,approve:true) }
}
