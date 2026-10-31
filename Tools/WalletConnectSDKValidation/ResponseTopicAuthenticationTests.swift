import XCTest
import Foundation
import Combine
import WalletConnectUtils
import JSONRPC
@testable import WalletConnectKMS
@testable import WalletConnectRelay
@testable import WalletConnectNetworking

@MainActor final class ResponseTopicAuthenticationTests: XCTestCase {
    private struct Method: ProtocolMethod {
        let method = "wc_sessionPing"
        let requestConfig = RelayConfig(tag: 1114, prompt: false, ttl: 30)
        let responseConfig = RelayConfig(tag: 1115, prompt: false, ttl: 30)
    }

    private func exercise(crossTopic: Bool, error: Bool) throws {
        let expectedTopic = String(repeating: "6", count: 64)
        let otherTopic = String(repeating: "7", count: 64)
        let kms = KeyManagementServiceMock()
        try kms.setSymmetricKey(SymmetricKey(rawRepresentation: Data(repeating: 6, count: 32)), for: expectedTopic)
        try kms.setSymmetricKey(SymmetricKey(rawRepresentation: Data(repeating: 7, count: 32)), for: otherTopic)
        let dispatcher = ResponseRelayDispatcher(), logger = ConsoleLoggerMock()
        let history = RPCHistoryFactory.createForNetwork(keyValueStorage: RuntimeKeyValueStorage())
        let relay = RelayClient(dispatcher: dispatcher, logger: logger,
            rpcHistory: RPCHistoryFactory.createForRelay(keyValueStorage: RuntimeKeyValueStorage()),
            clientIdStorage: ResponseRelayIdentity(), subscriptionsTracker: SubscriptionsTracker(logger: logger), topicsTracker: TopicsTracker())
        let network = NetworkingInteractor(relayClient: relay, serializer: Serializer(kms: kms, logger: logger), logger: logger, rpcHistory: history)
        let request = RPCRequest(method: "wc_sessionPing", params: [String:String](), id: Int64(123))
        try history.set(request, forTopic: expectedTopic, emmitedBy: .local, transportType: .relay)
        var responses = [String](), errors = [String]()
        let success = network.responseSubscription(on: Method()).sink { (p: ResponseSubscriptionPayload<[String:String],Bool>) in responses.append(p.topic) }
        let failure = network.responseErrorSubscription(on: Method()).sink { (p: ResponseSubscriptionErrorPayload<[String:String]>) in errors.append(p.topic) }
        let response = error
            ? RPCResponse(id: request.id!, error: JSONRPCError(code: 5000, message: "synthetic"))
            : RPCResponse(id: request.id!, result: true)
        func inject(topic: String) throws {
            // Sender owns only this topic's key; the receiver owns both.
            let senderKMS = KeyManagementServiceMock()
            try senderKMS.setSymmetricKey(SymmetricKey(rawRepresentation: Data(repeating: topic == expectedTopic ? 6 : 7, count: 32)), for: topic)
            let sender = Serializer(kms: senderKMS, logger: logger)
            let envelope = try sender.serialize(topic: topic, encodable: response, envelopeType: .type0, codingType: .base64Encoded)
            let frame = Subscription(id: "synthetic", topic: topic, message: envelope, attestation: nil).asRPCRequest()
            dispatcher.onMessage?(try frame.asJSONEncodedString())
        }
        if crossTopic {
            try inject(topic: otherTopic)
            XCTAssertTrue(responses.isEmpty && errors.isEmpty, "A different encrypted topic must not resolve this request")
            XCTAssertNotNil(history.get(recordId: request.id!), "Rejected frame must preserve the legitimate pending request")
        }
        try inject(topic: expectedTopic)
        XCTAssertEqual(error ? errors : responses, [expectedTopic])
        XCTAssertNil(history.get(recordId: request.id!))
        try inject(topic: expectedTopic)
        XCTAssertEqual(error ? errors : responses, [expectedTopic], "Duplicate response must not dispatch twice")
        withExtendedLifetime((network,relay,success,failure)) {}
    }
    func testDifferentTopicCannotResolveSuccess() throws { try exercise(crossTopic: true, error: false) }
    func testDifferentTopicCannotResolveError() throws { try exercise(crossTopic: true, error: true) }
    func testMatchingTopicSuccessDispatchesOnce() throws { try exercise(crossTopic: false, error: false) }
    func testMatchingTopicErrorDispatchesOnce() throws { try exercise(crossTopic: false, error: true) }
}

private final class ResponseRelayDispatcher: Dispatching {
    var onMessage: ((String) -> Void)?
    var isSocketConnected: Bool { true }
    var networkConnectionStatusPublisher: AnyPublisher<NetworkConnectionStatus, Never> { Just(.connected).eraseToAnyPublisher() }
    var socketConnectionStatusPublisher: AnyPublisher<SocketConnectionStatus, Never> { Just(.disconnected).eraseToAnyPublisher() }
    func protectedSend(_ string: String, connectUnconditionally: Bool, completion: @escaping (Error?) -> Void) { completion(nil) }
    func protectedSend(_ string: String, connectUnconditionally: Bool) async throws {}
    func connect() throws {}
    func disconnect(closeCode: URLSessionWebSocketTask.CloseCode) throws {}
}
private final class ResponseRelayIdentity: ClientIdStoring {
    func getOrCreateKeyPair() throws -> SigningPrivateKey { throw FixtureError.unused }
    func getClientId() throws -> String { throw FixtureError.unused }
    private enum FixtureError: Error { case unused }
}
