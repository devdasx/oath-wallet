import XCTest
import Foundation
import Combine
@testable import Schemas
@testable import WalletConnectKMS
import WalletConnectNetworking

/// Full production dispatcher, serializer and history; memory-only synthetic keys.
/// The host UIKit endpoint traps if reached. These tests only receive URLs.
final class LinkEnvelopeBoundaryTests: XCTestCase {
    private let topic = String(repeating: "6", count: 64)
    private let other = String(repeating: "7", count: 64)
    private let id: Int64 = 123
    private struct Method: ProtocolMethod {
        let method = "wc_sessionRequest"
        let requestConfig = RelayConfig(tag: 1108, prompt: false, ttl: 300)
        let responseConfig = RelayConfig(tag: 1109, prompt: false, ttl: 300)
    }
    private struct Fixture {
        let kms: KeyManagementServiceMock
        let serializer: Serializer
        let history: RPCHistory
        let dispatcher: LinkEnvelopesDispatcher
    }
    private func fixture() throws -> Fixture {
        let kms = KeyManagementServiceMock(), logger = ConsoleLoggerMock()
        try kms.setSymmetricKey(SymmetricKey(rawRepresentation: Data(repeating: 6, count: 32)), for: topic)
        try kms.setSymmetricKey(SymmetricKey(rawRepresentation: Data(repeating: 7, count: 32)), for: other)
        let history = RPCHistoryFactory.createForNetwork(keyValueStorage: RuntimeKeyValueStorage())
        let serializer = Serializer(kms: kms, logger: logger)
        return Fixture(kms: kms, serializer: serializer, history: history,
                       dispatcher: LinkEnvelopesDispatcher(serializer: serializer, logger: logger, rpcHistory: history))
    }
    private func inject(_ f: Fixture, envelope: String, topic: String) throws {
        var url = URLComponents(string: "https://example.invalid/wallet")!
        url.queryItems = [URLQueryItem(name: "wc_ev", value: envelope), URLQueryItem(name: "topic", value: topic)]
        try f.dispatcher.dispatchEnvelope(url.url!.absoluteString)
    }
    private func exerciseResponse(wrongTopic: Bool = false, plaintext: Bool = false, remote: Bool = false, error: Bool = false) throws {
        let f = try fixture()
        let request = RPCRequest(method: Method().method, params: [String: String](), id: id)
        try f.history.set(request, forTopic: topic, emmitedBy: remote ? .remote : .local, transportType: .linkMode)
        var delivered = [String]()
        let success = f.dispatcher.responseSubscription(on: Method()).sink { (p: ResponseSubscriptionPayload<[String:String], Bool>) in delivered.append(p.topic) }
        let failure = f.dispatcher.responseErrorSubscription(on: Method()).sink { (p: ResponseSubscriptionErrorPayload<[String:String]>) in delivered.append(p.topic) }
        let response = error ? RPCResponse(id: request.id!, error: JSONRPCError(code: 5000, message: "synthetic")) : RPCResponse(id: request.id!, result: true)
        let incomingTopic = wrongTopic ? other : topic
        // Each sender has only its own topic's key. Plaintext sender has none.
        let senderKMS = KeyManagementServiceMock()
        if !plaintext {
            try senderKMS.setSymmetricKey(SymmetricKey(rawRepresentation: Data(repeating: wrongTopic ? 7 : 6, count: 32)), for: incomingTopic)
        }
        let sender = Serializer(kms: senderKMS, logger: ConsoleLoggerMock())
        let envelope = try sender.serialize(topic: incomingTopic, encodable: response,
            envelopeType: plaintext ? .type2 : .type0, codingType: .base64UrlEncoded)
        try inject(f, envelope: envelope, topic: incomingTopic)
        if wrongTopic || plaintext || remote {
            XCTAssertTrue(delivered.isEmpty, "Rejected link response must not publish")
            XCTAssertNotNil(f.history.get(recordId: request.id!), "Rejected link response must preserve pending history")
            if !remote {
                let valid = try f.serializer.serialize(topic: topic, encodable: response, envelopeType: .type0, codingType: .base64UrlEncoded)
                try inject(f, envelope: valid, topic: topic)
                XCTAssertEqual(delivered, [topic], "Legitimate response must still complete")
                XCTAssertNil(f.history.get(recordId: request.id!))
            }
        } else {
            XCTAssertEqual(delivered, [topic])
            XCTAssertNil(f.history.get(recordId: request.id!))
            try inject(f, envelope: envelope, topic: topic)
            XCTAssertEqual(delivered, [topic], "Duplicate link response must not publish twice")
        }
        withExtendedLifetime((success, failure, f)) {}
    }
    func testCrossTopicSuccessPreservesPendingRequest() throws { try exerciseResponse(wrongTopic: true) }
    func testCrossTopicErrorPreservesPendingRequest() throws { try exerciseResponse(wrongTopic: true, error: true) }
    func testPlaintextSuccessPreservesPendingRequest() throws { try exerciseResponse(plaintext: true) }
    func testPlaintextErrorPreservesPendingRequest() throws { try exerciseResponse(plaintext: true, error: true) }
    func testRemoteOriginCannotBeConsumedBySuccess() throws { try exerciseResponse(remote: true) }
    func testRemoteOriginCannotBeConsumedByError() throws { try exerciseResponse(remote: true, error: true) }
    func testMatchingSuccessCompletesOnce() throws { try exerciseResponse() }
    func testMatchingErrorCompletesOnce() throws { try exerciseResponse(error: true) }

    private func exerciseRequest(method: String, plaintext: Bool, allowed: Bool) throws {
        let f = try fixture(); var received = [String]()
        let subscription = f.dispatcher.requestSubscription(on: method).sink { (p: RequestSubscriptionPayload<[String:String]>) in received.append(p.topic) }
        let request = RPCRequest(method: method, params: [String:String](), id: id)
        let sender = plaintext ? Serializer(kms: KeyManagementServiceMock(), logger: ConsoleLoggerMock()) : f.serializer
        let envelope = try sender.serialize(topic: topic, encodable: request, envelopeType: plaintext ? .type2 : .type0, codingType: .base64UrlEncoded)
        try inject(f, envelope: envelope, topic: topic)
        if allowed {
            XCTAssertEqual(received, [topic]); XCTAssertNotNil(f.history.get(recordId: request.id!))
            try inject(f, envelope: envelope, topic: topic)
            XCTAssertEqual(received, [topic])
        } else {
            XCTAssertTrue(received.isEmpty, "Plaintext session request must not publish")
            XCTAssertTrue(f.history.get(recordId: request.id!) == nil, "Plaintext session request must not occupy history")
        }
        withExtendedLifetime(subscription) {}
    }
    func testPlaintextSessionRequestIsRejected() throws { try exerciseRequest(method: "wc_sessionRequest", plaintext: true, allowed: false) }
    func testPlaintextSessionDeleteIsRejected() throws { try exerciseRequest(method: "wc_sessionDelete", plaintext: true, allowed: false) }
    func testEncryptedSessionRequestStillDispatches() throws { try exerciseRequest(method: "wc_sessionRequest", plaintext: false, allowed: true) }
    func testInitialPlaintextAuthenticationStillDispatches() throws { try exerciseRequest(method: "wc_sessionAuthenticate", plaintext: true, allowed: true) }

    private func exerciseAuthenticationResponse(error: Bool) throws {
        let f = try fixture(); let receiver = try AgreementPrivateKey(rawRepresentation: Data(repeating: 4, count: 32))
        let senderKey = try AgreementPrivateKey(rawRepresentation: Data(repeating: 5, count: 32))
        let responseTopic = receiver.publicKey.rawRepresentation.sha256().toHexString()
        try f.kms.setPrivateKey(receiver)
        try f.kms.setPublicKey(publicKey: receiver.publicKey, for: responseTopic)
        let senderKMS = KeyManagementServiceMock(); try senderKMS.setPrivateKey(senderKey)
        let agreement = try senderKMS.performKeyAgreement(selfPublicKey: senderKey.publicKey, peerPublicKey: receiver.publicKey.hexRepresentation)
        senderKMS.setAgreementSecret(agreement, topic: responseTopic)
        let request = RPCRequest(method: "wc_sessionAuthenticate", params: ["requester": ["publicKey": receiver.publicKey.hexRepresentation]], id: id)
        try f.history.set(request, forTopic: "synthetic-initial-topic", emmitedBy: .local, transportType: .linkMode)
        var received = [String]()
        let subscription = f.dispatcher.responseSubscription(on: SessionAuthenticatedProtocolMethod.responseApprove()).sink { (p: ResponseSubscriptionPayload<[String:[String:String]], Bool>) in received.append(p.topic) }
        let failure = f.dispatcher.responseErrorSubscription(on: SessionAuthenticatedProtocolMethod.responseApprove()).sink { (p: ResponseSubscriptionErrorPayload<[String:[String:String]]>) in received.append(p.topic) }
        let response = error ? RPCResponse(id: request.id!, error: JSONRPCError(code: 5000, message: "synthetic")) : RPCResponse(id: request.id!, result: true)
        let sender = Serializer(kms: senderKMS, logger: ConsoleLoggerMock())
        let envelope = try sender.serialize(topic: responseTopic, encodable: response,
            envelopeType: .type1(pubKey: senderKey.publicKey.rawRepresentation), codingType: .base64UrlEncoded)
        try inject(f, envelope: envelope, topic: responseTopic)
        XCTAssertEqual(received, [responseTopic]); XCTAssertNil(f.history.get(recordId: request.id!))
        withExtendedLifetime((subscription, failure)) {}
    }
    func testAuthenticationResponseUsesDerivedTopic() throws { try exerciseAuthenticationResponse(error: false) }
    func testAuthenticationErrorUsesDerivedTopic() throws { try exerciseAuthenticationResponse(error: true) }
    func testMalformedFramesLeaveHistoryUnchanged() throws {
        let f = try fixture()
        for envelope in ["", "!not-base64!", Data([3]).base64urlEncodedString(), Data([1]).base64urlEncodedString()] {
            try inject(f, envelope: envelope, topic: topic)
        }
        XCTAssertTrue(f.history.getPending().isEmpty)
    }
    func testTamperedEncryptionLeavesPendingRequest() throws {
        let f = try fixture()
        let request = RPCRequest(method: Method().method, params: [String:String](), id: id)
        try f.history.set(request, forTopic: topic, emmitedBy: .local, transportType: .linkMode)
        let envelope = try f.serializer.serialize(topic: topic, encodable: RPCResponse(id: request.id!, result: true), envelopeType: .type0, codingType: .base64UrlEncoded)
        var bytes = try XCTUnwrap(Data(base64url: envelope)); bytes[bytes.count - 1] ^= 1
        try inject(f, envelope: bytes.base64urlEncodedString(), topic: topic)
        XCTAssertNotNil(f.history.get(recordId: request.id!))
    }
}
