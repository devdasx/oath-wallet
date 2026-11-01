import Combine
import Foundation
import JSONRPC
import XCTest
@testable import WalletConnectKMS
@testable import WalletConnectRelay
@testable import WalletConnectUtils

private enum ProbeError: Error { case send, unused }

private final class ProbeIdentity: ClientIdStoring {
    func getOrCreateKeyPair() throws -> SigningPrivateKey { throw ProbeError.unused }
    func getClientId() throws -> String { throw ProbeError.unused }
}

// Deliver through the same receive callback as the socket, while protectedSend
// is still on the stack. Each case sends just one matching successful reply.
private final class ProbeTransport: Dispatching {
    var onMessage: ((String) -> Void)?
    var beforeSendReturns: ((RPCRequest) throws -> Void)?
    var isSocketConnected: Bool { true }
    var socketConnectionStatusPublisher: AnyPublisher<SocketConnectionStatus, Never> {
        Just(.disconnected).eraseToAnyPublisher()
    }
    var networkConnectionStatusPublisher: AnyPublisher<NetworkConnectionStatus, Never> {
        Just(.connected).eraseToAnyPublisher()
    }
    func connect() throws {}
    func disconnect(closeCode: URLSessionWebSocketTask.CloseCode) throws {}
    func protectedSend(_ string: String, connectUnconditionally: Bool, completion: @escaping (Error?) -> Void) {
        XCTFail("Unexpected callback-based send")
        completion(ProbeError.unused)
    }
    func protectedSend(_ string: String, connectUnconditionally: Bool) async throws {
        let request = try JSONDecoder().decode(RPCRequest.self, from: Data(string.utf8))
        try XCTUnwrap(beforeSendReturns)(request)
    }
}

final class RelayEarlyResponseTests: XCTestCase {
    private enum Operation: CaseIterable {
        case publish, subscribe, batch
        var method: String {
            switch self {
            case .publish: return "irn_publish"
            case .subscribe: return "irn_subscribe"
            case .batch: return "irn_batchSubscribe"
            }
        }
    }
    private func exercise(_ operation: Operation, sendFails: Bool = false) async throws {
        let transport = ProbeTransport(), logger = ConsoleLoggerMock()
        let tracker = SubscriptionsTracker(logger: logger)
        let relay = RelayClient(dispatcher: transport, logger: logger,
            rpcHistory: RPCHistoryFactory.createForRelay(keyValueStorage: RuntimeKeyValueStorage()),
            clientIdStorage: ProbeIdentity(), subscriptionsTracker: tracker, topicsTracker: TopicsTracker())
        let topics = ["synthetic-one", "synthetic-two"]
        transport.beforeSendReturns = { [weak transport] request in
            XCTAssertEqual(request.method, operation.method)
            let id = try XCTUnwrap(request.id)
            // Neither an unrelated ID nor a wrong result kind can satisfy this request.
            try transport?.onMessage?(RPCResponse(id: RPCID("unrelated"), result: ["wrong"]).asJSONEncodedString())
            let response: RPCResponse
            switch operation {
            case .publish:
                try transport?.onMessage?(RPCResponse(id: id, result: "unexpected").asJSONEncodedString())
                response = RPCResponse(id: id, result: true)
            case .subscribe:
                try transport?.onMessage?(RPCResponse(id: id, result: true).asJSONEncodedString())
                response = RPCResponse(id: id, result: "one-id")
            case .batch:
                response = RPCResponse(id: id, result: ["one-id","two-id"])
            }
            try transport?.onMessage?(response.asJSONEncodedString())
            if sendFails { throw ProbeError.send }
        }
        do {
            switch operation {
            case .publish:
                try await relay.publish(topic: topics[0], payload: "synthetic", tag: 1, prompt: false, ttl: 60, tvfData: nil, coorelationId: nil)
            case .subscribe: try await relay.subscribe(topic: topics[0])
            case .batch: try await relay.batchSubscribe(topics: topics)
            }
            XCTAssertFalse(sendFails, "A received reply cannot hide a local send failure")
        } catch ProbeError.send where sendFails {
            XCTAssertTrue(tracker.getTopics().isEmpty)
            return
        } catch RelayError.requestTimeout {
            XCTFail("Lost a matching relay reply delivered before protectedSend returned")
            return
        }
        if operation != .publish { XCTAssertEqual(tracker.getSubscription(for: topics[0]), "one-id") }
        if operation == .batch { XCTAssertEqual(tracker.getSubscription(for: topics[1]), "two-id") }
        if operation == .publish { XCTAssertTrue(tracker.getTopics().isEmpty) }
    }
    func testPublishCapturesEarlyAcknowledgement() async throws { try await exercise(.publish) }
    func testSubscribeCapturesEarlyID() async throws { try await exercise(.subscribe) }
    func testBatchCapturesEarlyIDs() async throws { try await exercise(.batch) }
    func testPublishSendErrorWins() async throws { try await exercise(.publish, sendFails: true) }
    func testSubscribeSendErrorWins() async throws { try await exercise(.subscribe, sendFails: true) }
    func testBatchSendErrorWins() async throws { try await exercise(.batch, sendFails: true) }
}
