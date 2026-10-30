import XCTest
@testable import WalletConnectKMS
@testable import WalletConnectNetworking

@MainActor final class SerializationTests: XCTestCase {
    private struct Payload: Codable, Equatable {
        let method:String
        let value:String
    }
    func testMalformedEnvelopeThrowsWithoutCrashing() throws {
        for coding in [Envelope.CodingType.base64Encoded, .base64UrlEncoded] {
            // Includes the empty-base64 envelope which decodes successfully to
            // zero bytes, and every truncated type-1 public key length.
            var samples=[Data(),Data([255])]
            samples += (1..<33).map { Data([1])+Data(repeating:0,count:$0-1) }
            for bytes in samples {
                let text=coding == .base64Encoded ? bytes.base64EncodedString() : bytes.base64urlEncodedString()
                XCTAssertThrowsError(try Envelope(coding,envelopeString:text))
            }
        }
    }
    func testQueuedType0RoundTripPreservesJSONAndUnicode() async throws {
        let kms=KeyManagementServiceMock(),topic="fixture-topic"
        _=try kms.createSymmetricKey(topic)
        let serializer=Serializer(kms:kms,logger:ConsoleLoggerMock())
        let queue=QueuedSerializer(serializer:serializer)
        let value=Payload(method:"personal_sign",value:"https://fixture.invalid/مرحبا\n\"quoted\"")
        let originalJSON = try value.json()
        let encoded=try await queue.serialize(topic:topic,json:originalJSON,envelopeType:.type0)
        let (decoded,_,bytes):(Payload,String?,Data)=try serializer.deserialize(topic:topic,codingType:.base64Encoded,envelopeString:encoded)
        XCTAssertEqual(value,decoded)
        XCTAssertEqual(String(data:bytes,encoding:.utf8),originalJSON)
    }
    func testQueuedType1CanBeDecryptedByPeer() async throws {
        let sender=KeyManagementServiceMock(),receiver=KeyManagementServiceMock()
        let receiverKey=try receiver.createX25519KeyPair(),senderKey=try sender.createX25519KeyPair()
        let topic="fixture-topic"
        try receiver.setPublicKey(publicKey:receiverKey,for:topic)
        let agreement=try sender.performKeyAgreement(selfPublicKey:senderKey,peerPublicKey:receiverKey.hexRepresentation)
        sender.setAgreementSecret(agreement,topic:topic)
        let queue=QueuedSerializer(serializer:Serializer(kms:sender,logger:ConsoleLoggerMock()))
        let value=Payload(method:"session_authenticate",value:"fixture")
        let encoded=try await queue.serialize(topic:topic,json:value.json(),envelopeType:.type1(pubKey:senderKey.rawRepresentation))
        let (decoded,derived,_):(Payload,String?,Data)=try Serializer(kms:receiver,logger:ConsoleLoggerMock()).deserialize(topic:topic,codingType:.base64Encoded,envelopeString:encoded)
        XCTAssertEqual(value,decoded);XCTAssertEqual(derived,agreement.derivedTopic())
    }
    func testType2WireFormatAndCancelledQueue() async throws {
        let serializer=Serializer(kms:KeyManagementServiceMock(),logger:ConsoleLoggerMock())
        let queue=QueuedSerializer(serializer:serializer)
        let value="https://fixture.invalid/مرحبا"
        let expected=try serializer.serialize(topic:nil,encodable:value,envelopeType:.type2,codingType:.base64Encoded)
        let actual=try await queue.serialize(topic:nil,json:value.asJSONEncodedString(),envelopeType:.type2)
        XCTAssertEqual(expected,actual)
        let task=Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _=try await queue.serialize(topic:nil,json:"{}",envelopeType:.type0)
                XCTFail("Cancelled serialization ran")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
    }
}
