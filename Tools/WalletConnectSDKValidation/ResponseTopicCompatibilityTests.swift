import XCTest
import Foundation
import Combine
import WalletConnectUtils
import JSONRPC
@testable import WalletConnectKMS
@testable import WalletConnectRelay
@testable import WalletConnectNetworking

@MainActor final class ResponseTopicCompatibilityTests: XCTestCase {
    private struct Method: ProtocolMethod {
        let method = "wc_sessionPing"
        let requestConfig = RelayConfig(tag: 1114, prompt: false, ttl: 30)
        let responseConfig = RelayConfig(tag: 1115, prompt: false, ttl: 30)
    }

    private func exercise(crossTopic: Bool, error: Bool, separateResponseTopic: Bool = false, type1: Bool = false) throws {
        let expectedTopic = String(repeating: "6", count: 64)
        let otherTopic = String(repeating: "7", count: 64)
        let kms = KeyManagementServiceMock()
        try kms.setSymmetricKey(SymmetricKey(rawRepresentation: Data(repeating: 6, count: 32)), for: expectedTopic)
        try kms.setSymmetricKey(SymmetricKey(rawRepresentation: Data(repeating: 7, count: 32)), for: otherTopic)
        let dispatcher = CompatibilityRelayDispatcher(), logger = ConsoleLoggerMock()
        let history = RPCHistoryFactory.createForNetwork(keyValueStorage: RuntimeKeyValueStorage())
        let relay = RelayClient(dispatcher: dispatcher, logger: logger,
            rpcHistory: RPCHistoryFactory.createForRelay(keyValueStorage: RuntimeKeyValueStorage()),
            clientIdStorage: CompatibilityRelayIdentity(), subscriptionsTracker: SubscriptionsTracker(logger: logger), topicsTracker: TopicsTracker())
        let network = NetworkingInteractor(relayClient: relay, serializer: Serializer(kms: kms, logger: logger), logger: logger, rpcHistory: history)
        let original = RPCRequest(method: "wc_sessionPing", params: [String:String](), id: Int64(123))
        let request = separateResponseTopic ? original.expectingResponse(on: expectedTopic) : original
        try history.set(request, forTopic: separateResponseTopic ? "pairing-topic" : expectedTopic, emmitedBy: .local, transportType: .relay)
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
            let envelope: String
            if type1 {
                let receivingKey = try AgreementPrivateKey(rawRepresentation: Data(repeating: 4, count: 32))
                let sendingKey = try AgreementPrivateKey(rawRepresentation: Data(repeating: 5, count: 32))
                try kms.setPrivateKey(receivingKey)
                try kms.setPublicKey(publicKey: receivingKey.publicKey, for: topic)
                try senderKMS.setPrivateKey(sendingKey)
                let agreement = try senderKMS.performKeyAgreement(selfPublicKey: sendingKey.publicKey, peerPublicKey: receivingKey.publicKey.hexRepresentation)
                senderKMS.setAgreementSecret(agreement, topic: topic)
                envelope = try sender.serialize(topic: topic, encodable: response, envelopeType: .type1(pubKey: sendingKey.publicKey.rawRepresentation), codingType: .base64Encoded)
            } else {
                envelope = try sender.serialize(topic: topic, encodable: response, envelopeType: .type0, codingType: .base64Encoded)
            }
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
    func testExplicitSeparateResponseTopicSupportsType1Success() throws { try exercise(crossTopic: true, error: false, separateResponseTopic: true, type1: true) }
    func testExplicitSeparateResponseTopicSupportsType1Error() throws { try exercise(crossTopic: true, error: true, separateResponseTopic: true, type1: true) }
    func testResponseTopicIsLocalOnlyAndCannotBeInjectedByJSON() throws {
        let original = RPCRequest(method: "synthetic", params: [String:String](), id: Int64(123))
        let marked = original.expectingResponse(on: "expected")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? NSDictionary, try JSONSerialization.jsonObject(with: JSONEncoder().encode(marked)) as? NSDictionary)
        let data = Data(#"{"id":123,"method":"synthetic","jsonrpc":"2.0","params":{},"expectedResponseTopic":"attacker"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(RPCRequest.self, from: data).expectedResponseTopic)
    }
    func testExpectedResponseTopicSurvivesHistoryRestart() throws {
        let storage = RuntimeKeyValueStorage()
        let initial = RPCHistoryFactory.createForNetwork(keyValueStorage: storage)
        let request = RPCRequest(method: "synthetic", params: [String:String](), id: Int64(123)).expectingResponse(on: "response")
        try initial.set(request, forTopic: "pairing", emmitedBy: .local, transportType: .relay)
        let reopened = RPCHistoryFactory.createForNetwork(keyValueStorage: storage)
        let response = RPCResponse(id: request.id!, result: true)
        XCTAssertThrowsError(try reopened.resolve(response, forResponseTopic: "pairing"))
        XCTAssertNotNil(reopened.get(recordId: request.id!))
        XCTAssertEqual(try reopened.resolve(response, forResponseTopic: "response").topic, "pairing")
    }
    func testLegacyRecordWithoutResponseTopicStillResolvesOnOriginalTopic() throws {
        let storage = RuntimeKeyValueStorage()
        let initial = RPCHistoryFactory.createForNetwork(keyValueStorage: storage)
        let request = RPCRequest(method: "synthetic", params: [String:String](), id: Int64(123))
        try initial.set(request, forTopic: "original", emmitedBy: .local, transportType: .relay)
        for (key,value) in storage.dictionaryRepresentation() {
            guard let data = value as? Data else { continue }
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String:Any])
            object.removeValue(forKey: "expectedResponseTopic")
            storage.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
        }
        let reopened = RPCHistoryFactory.createForNetwork(keyValueStorage: storage)
        XCTAssertEqual(try reopened.resolve(RPCResponse(id: request.id!, result: true), forResponseTopic: "original").topic, "original")
    }
    func testLegacyAuthenticationUsesOnlyItsDerivedResponseTopic() throws {
        let storage = RuntimeKeyValueStorage()
        let initial = RPCHistoryFactory.createForNetwork(keyValueStorage: storage)
        let request = RPCRequest(method: "wc_sessionAuthenticate", params: ["requester":["publicKey":String(repeating:"04",count:32)]], id: Int64(123))
        try initial.set(request, forTopic: "pairing", emmitedBy: .local, transportType: .relay)
        let reopened = RPCHistoryFactory.createForNetwork(keyValueStorage: storage)
        let response = RPCResponse(id: request.id!, result: true)
        XCTAssertThrowsError(try reopened.resolve(response, forResponseTopic: "pairing"))
        XCTAssertThrowsError(try reopened.resolve(response, forResponseTopic: String(repeating:"7",count:64)))
        // SHA256 of 32 bytes of 0x04, independently calculated by Python hashlib.
        XCTAssertEqual(try reopened.resolve(response, forResponseTopic: "9f4fb68f3e1dac82202f9aa581ce0bbf1f765df0e9ac3c8c57e20f685abab8ed").topic, "pairing")
    }
    func testMalformedLegacyAuthenticationRoutingFailsClosed() throws {
        for key in ["", "04", String(repeating:"g",count:64), String(repeating:"０",count:64)] {
            let history = RPCHistoryFactory.createForNetwork(keyValueStorage: RuntimeKeyValueStorage())
            let request = RPCRequest(method: "wc_sessionAuthenticate", params: ["requester":["publicKey":key]], id: Int64(123))
            try history.set(request, forTopic: "pairing", emmitedBy: .local, transportType: .relay)
            XCTAssertThrowsError(try history.resolve(RPCResponse(id: request.id!, result: true), forResponseTopic: "pairing"))
            XCTAssertNotNil(history.get(recordId: request.id!))
        }
    }
    func testRemoteRequestCannotBeConsumedAsLocalResponse() throws {
        let history = RPCHistoryFactory.createForNetwork(keyValueStorage: RuntimeKeyValueStorage())
        let request = RPCRequest(method: "synthetic", params: [String:String](), id: Int64(123))
        try history.set(request, forTopic: "original", emmitedBy: .remote, transportType: .relay)
        XCTAssertThrowsError(try history.resolve(RPCResponse(id: request.id!, result: true), forResponseTopic: "original"))
        XCTAssertNotNil(history.get(recordId: request.id!))
    }

}

private final class CompatibilityRelayDispatcher: Dispatching {
    var onMessage: ((String) -> Void)?
    var isSocketConnected: Bool { true }
    var networkConnectionStatusPublisher: AnyPublisher<NetworkConnectionStatus, Never> { Just(.connected).eraseToAnyPublisher() }
    var socketConnectionStatusPublisher: AnyPublisher<SocketConnectionStatus, Never> { Just(.disconnected).eraseToAnyPublisher() }
    func protectedSend(_ string: String, connectUnconditionally: Bool, completion: @escaping (Error?) -> Void) { completion(nil) }
    func protectedSend(_ string: String, connectUnconditionally: Bool) async throws {}
    func connect() throws {}
    func disconnect(closeCode: URLSessionWebSocketTask.CloseCode) throws {}
}
private final class CompatibilityRelayIdentity: ClientIdStoring {
    func getOrCreateKeyPair() throws -> SigningPrivateKey { throw FixtureError.unused }
    func getClientId() throws -> String { throw FixtureError.unused }
    private enum FixtureError: Error { case unused }
}
