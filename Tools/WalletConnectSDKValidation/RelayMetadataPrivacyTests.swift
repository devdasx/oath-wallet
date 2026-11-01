import XCTest
@testable import WalletConnectRelay
@testable import WalletConnectKMS
@testable import WalletConnectNetworking

@MainActor final class RelayMetadataPrivacyTests: XCTestCase {
    private let transactionHash = "0x" + String(repeating: "a", count: 64)
    private let contract = "0x" + String(repeating: "b", count: 40)

    private func outer(_ metadata: TVFData?, message: String = "fixture-encrypted-message") throws -> [String: Any] {
        let request = Publish(params: .init(topic: "fixture-topic", message: message,
            ttl: 300, prompt: false, tag: 1109, correlationId: RPCID(42), tvfData: metadata)).asRPCRequest()
        let data = Data(try request.asJSONEncodedString().utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "irn_publish")
        return try XCTUnwrap(object["params"] as? [String: Any])
    }

    func testOptionalTransactionMetadataNotPublished() throws {
        let metadata = TVFData(rpcMethods: ["eth_sendTransaction"], chainId: Blockchain("eip155:1"),
            txHashes: [transactionHash], contractAddresses: [contract])
        let params = try outer(metadata)
        for key in ["rpcMethods", "chainId", "txHashes", "contractAddresses"] {
            XCTAssertNil(params[key], "Optional transaction metadata must stay inside the encrypted session: \(key)")
        }
    }

    func testCollectorResponseDoesNotBypassPrivacyBoundary() throws {
        let metadata = TVFCollector().collect(rpcMethod: "eth_sendTransaction",
            rpcParams: AnyCodable([String]()), chainID: try XCTUnwrap(Blockchain("eip155:1")),
            rpcResult: .response(AnyCodable(transactionHash)), tag: 1109)
        XCTAssertEqual(metadata?.txHashes, [transactionHash], "The production collector must exercise the metadata path")
        let params = try outer(metadata)
        for key in ["rpcMethods", "chainId", "txHashes", "contractAddresses"] {
            XCTAssertNil(params[key], "Optional transaction metadata must stay inside the encrypted session: \(key)")
        }
    }

    func testEncryptedResponseAndRoutingFieldsRemainIntact() async throws {
        let kms = KeyManagementServiceMock(), topic = "fixture-topic"
        _ = try kms.createSymmetricKey(topic)
        let serializer = Serializer(kms: kms, logger: ConsoleLoggerMock())
        let response = RPCResponse(id: RPCID(42), result: transactionHash)
        let encrypted = try await QueuedSerializer(serializer: serializer).serialize(
            topic: topic, json: response.json(), envelopeType: .type0)
        let params = try outer(nil, message: encrypted)
        XCTAssertEqual(params["topic"] as? String, topic)
        XCTAssertEqual(params["message"] as? String, encrypted)
        XCTAssertEqual(params["ttl"] as? Int, 300)
        XCTAssertEqual(params["prompt"] as? Bool, false)
        XCTAssertEqual(params["tag"] as? Int, 1109)
        XCTAssertEqual(params["correlationId"] as? Int, 42)
        let (decoded, _, _): (RPCResponse, String?, Data) = try serializer.deserialize(
            topic: topic, codingType: .base64Encoded, envelopeString: encrypted)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(decoded.json().utf8)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(response.json().utf8)) as? NSDictionary)
        XCTAssertFalse(encrypted.contains(transactionHash))
    }

    func testDecodedMetadataCannotBeRepublished() throws {
        let object: [String: Any] = ["topic": "fixture-topic", "message": "fixture-encrypted-message",
            "ttl": 300, "rpcMethods": ["eth_sendTransaction"], "chainId": "eip155:1",
            "txHashes": [transactionHash], "contractAddresses": [contract]]
        let stored = try JSONDecoder().decode(Publish.Params.self, from: JSONSerialization.data(withJSONObject: object))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        for key in ["rpcMethods", "chainId", "txHashes", "contractAddresses"] {
            XCTAssertNil(encoded[key], "Optional transaction metadata must stay inside the encrypted session: \(key)")
        }
        XCTAssertEqual(encoded["message"] as? String, object["message"] as? String)
    }
}
