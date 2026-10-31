import XCTest
import Foundation
import Combine
import WalletConnectUtils
import JSONRPC
@testable import WalletConnectKMS
@testable import WalletConnectRelay
@testable import WalletConnectNetworking

/// Synthetic relay frames only. No live relay, wallet keys or session storage.
@MainActor final class RelayEnvelopeAuthenticationTests: XCTestCase {
    private let topic = String(repeating: "7", count: 64)
    private let request = #"{"id":123,"jsonrpc":"2.0","method":"wc_sessionDelete","params":{"code":6000,"message":"synthetic"}}"#

    private func delivered(_ envelope: String, kms: KeyManagementServiceMock) throws -> [RPCRequest] {
        let dispatcher = AuditRelayDispatcher()
        let logger = ConsoleLoggerMock()
        let relay = RelayClient(dispatcher: dispatcher, logger: logger,
            rpcHistory: RPCHistoryFactory.createForRelay(keyValueStorage: RuntimeKeyValueStorage()),
            clientIdStorage: AuditRelayIdentity(), subscriptionsTracker: SubscriptionsTracker(logger: logger),
            topicsTracker: TopicsTracker())
        let network = NetworkingInteractor(relayClient: relay,
            serializer: Serializer(kms: kms, logger: logger), logger: logger,
            rpcHistory: RPCHistoryFactory.createForNetwork(keyValueStorage: RuntimeKeyValueStorage()))
        var received = [RPCRequest]()
        let observation = network.requestPublisher.sink { received.append($0.request) }
        let frame = Subscription(id: "synthetic-subscription", topic: topic, message: envelope, attestation: nil).asRPCRequest()
        dispatcher.onMessage?(try frame.asJSONEncodedString())
        withExtendedLifetime((network, relay, observation)) {}
        return received
    }

    func testPlaintextEnvelopeCannotInjectARequestOnAnEncryptedRelayTopic() throws {
        let receiver = KeyManagementServiceMock()
        try receiver.setSymmetricKey(SymmetricKey(rawRepresentation: Data(repeating: 3, count: 32)), for: topic)
        // The injecting sender does not possess the receiver's topic key.
        let attacker = Serializer(kms: KeyManagementServiceMock(), logger: ConsoleLoggerMock())
        let envelope = try attacker.serialize(topic: nil, json: request, envelopeType: .type2, codingType: .base64Encoded)
        XCTAssertTrue(try delivered(envelope, kms: receiver).isEmpty,
                      "Unauthenticated plaintext must never enter encrypted relay request dispatch")
    }

    func testPlaintextEnvelopeCannotInjectARequestWithoutAnyTopicKey() throws {
        let attacker = Serializer(kms: KeyManagementServiceMock(), logger: ConsoleLoggerMock())
        let envelope = try attacker.serialize(topic: nil, json: request, envelopeType: .type2, codingType: .base64Encoded)
        XCTAssertTrue(try delivered(envelope, kms: KeyManagementServiceMock()).isEmpty)
    }

    func testAuthenticatedType1RelayEnvelopeStillDispatches() throws {
        let receiver = KeyManagementServiceMock(), sender = KeyManagementServiceMock()
        let receiverKey = try AgreementPrivateKey(rawRepresentation: Data(repeating: 4, count: 32))
        let senderKey = try AgreementPrivateKey(rawRepresentation: Data(repeating: 5, count: 32))
        try receiver.setPrivateKey(receiverKey)
        try sender.setPrivateKey(senderKey)
        try receiver.setPublicKey(publicKey: receiverKey.publicKey, for: topic)
        let agreement = try sender.performKeyAgreement(selfPublicKey: senderKey.publicKey,
                                                      peerPublicKey: receiverKey.publicKey.hexRepresentation)
        sender.setAgreementSecret(agreement, topic: topic)
        let serializer = Serializer(kms: sender, logger: ConsoleLoggerMock())
        let envelope = try serializer.serialize(topic: topic, json: request,
            envelopeType: .type1(pubKey: senderKey.publicKey.rawRepresentation), codingType: .base64Encoded)
        XCTAssertEqual(try delivered(envelope, kms: receiver).count, 1)
    }

    func testAuthenticatedRelayEnvelopeStillDispatchesAndTamperingIsRejected() throws {
        let receiver = KeyManagementServiceMock()
        try receiver.setSymmetricKey(SymmetricKey(rawRepresentation: Data(repeating: 3, count: 32)), for: topic)
        let sender = Serializer(kms: receiver, logger: ConsoleLoggerMock())
        let envelope = try sender.serialize(topic: topic, json: request, envelopeType: .type0, codingType: .base64Encoded)
        let delivered = try delivered(envelope, kms: receiver)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.method, "wc_sessionDelete")
        var bytes = try XCTUnwrap(Data(base64Encoded: envelope))
        bytes[bytes.count - 1] ^= 1
        XCTAssertTrue(try self.delivered(bytes.base64EncodedString(), kms: receiver).isEmpty)
    }
}

private final class AuditRelayDispatcher: Dispatching {
    var onMessage: ((String) -> Void)?
    var isSocketConnected: Bool { true }
    var networkConnectionStatusPublisher: AnyPublisher<NetworkConnectionStatus, Never> { Just(.connected).eraseToAnyPublisher() }
    var socketConnectionStatusPublisher: AnyPublisher<SocketConnectionStatus, Never> { Just(.disconnected).eraseToAnyPublisher() }
    func protectedSend(_ string: String, connectUnconditionally: Bool, completion: @escaping (Error?) -> Void) { completion(nil) }
    func protectedSend(_ string: String, connectUnconditionally: Bool) async throws {}
    func connect() throws {}
    func disconnect(closeCode: URLSessionWebSocketTask.CloseCode) throws {}
}
private final class AuditRelayIdentity: ClientIdStoring {
    func getOrCreateKeyPair() throws -> SigningPrivateKey { throw FixtureError.unused }
    func getClientId() throws -> String { throw FixtureError.unused }
    private enum FixtureError: Error { case unused }
}
