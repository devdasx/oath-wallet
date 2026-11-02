import XCTest
@testable import WalletConnectSigner
import WalletConnectNetworking
import HTTPClient

private final class SignatureCryptoProbe: CryptoProvider {
    var recoveryCalls = 0
    var hash = Data(repeating: 0xab, count: 32)

    func recoverPubKey(signature: EthereumSignature, message: Data) throws -> Data {
        recoveryCalls += 1
        return Data(repeating: 1, count: 64)
    }

    func keccak256(_ data: Data) -> Data { hash }
}

private final class ContractResponseProbe: HTTPClient {
    var result = "0x1626ba7e" + String(repeating: "0", count: 56)
    var requests: [Data] = []

    func request<T: Decodable>(_ type: T.Type, at service: HTTPService) async throws -> T {
        requests.append(try XCTUnwrap(service.body))
        let response = RPCResponse(id: 1, result: result)
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(response))
    }
    func request(service: HTTPService) async throws { XCTFail("Unexpected HTTP operation") }
    func updateHost(host: String) async { XCTFail("Unexpected host change") }
}

final class SignatureBoundaryTests: XCTestCase {
    private let message = Data(repeating: 0, count: 32)
    private let address = "0x" + String(repeating: "ab", count: 20)
    private let r = [UInt8](repeating: 1, count: 32)
    private let s = [UInt8](repeating: 2, count: 32)

    func testEmptySignatureIsRejected() {
        XCTAssertThrowsError(try EthereumSignature(serialized: Data()))
    }

    func testShortSignatureIsRejected() {
        XCTAssertThrowsError(try EthereumSignature(serialized: Data(repeating: 0, count: 32)))
    }

    func testNon65ByteSignaturesAreRejected() {
        for length in [64, 66, 128, 1024] {
            XCTAssertThrowsError(try EthereumSignature(serialized: Data(repeating: 0, count: length)))
        }
    }

    func testRawComponentSizesAreRejected() {
        for length in [0, 1, 31, 33, 65] {
            XCTAssertThrowsError(try EthereumSignature(v: 0, r: [UInt8](repeating: 1, count: length), s: s))
            XCTAssertThrowsError(try EthereumSignature(v: 0, r: r, s: [UInt8](repeating: 2, count: length)))
        }
    }

    func testInvalidRawRecoveryByteCannotTrapSerialization() {
        XCTAssertThrowsError(try EthereumSignature(v: 255, r: r, s: s).serialized)
    }

    func testAllRawRecoveryBytesHaveExplicitAdmission() throws {
        for raw in UInt8.min...UInt8.max {
            if raw <= 3 {
                let sig = try EthereumSignature(v: raw, r: r, s: s)
                XCTAssertEqual(sig.serialized, Data(r + s + [raw + 27]))
            } else {
                XCTAssertThrowsError(try EthereumSignature(v: raw, r: r, s: s))
            }
        }
    }

    func testAllWireRecoveryBytesHaveExplicitAdmission() throws {
        for raw in UInt8.min...UInt8.max {
            let input = Data(r + s + [raw])
            if raw <= 3 || (27...38).contains(raw) {
                let signature = try EthereumSignature(serialized: input)
                let normalized = raw <= 3 ? raw : (raw - 27) % 4
                XCTAssertEqual(signature.v, normalized)
                XCTAssertEqual(signature.r, r)
                XCTAssertEqual(signature.s, s)
                XCTAssertEqual(signature.serialized, Data(r + s + [normalized + 27]))
            } else {
                XCTAssertThrowsError(try EthereumSignature(serialized: input))
            }
        }
    }

    func testSlicedSignaturePreservesByteBoundaries() throws {
        let input = Data([9, 8, 7] + r + s + [28]).dropFirst(3)
        XCTAssertNotEqual(input.startIndex, 0)
        let signature = try EthereumSignature(serialized: input)
        XCTAssertEqual(signature.v, 1)
        XCTAssertEqual(signature.r, r)
        XCTAssertEqual(signature.s, s)
    }

    func testEmptyVerifierInputNeverReachesRecovery() async {
        let crypto = SignatureCryptoProbe()
        do {
            try await EIP191Verifier(crypto: crypto).verify(signature: Data(), message: message, address: address)
            XCTFail("Malformed signature must fail")
        } catch { }
        XCTAssertEqual(crypto.recoveryCalls, 0)
    }

    func testMalformedVerifierInputsNeverReachRecovery() async {
        for signature in [Data(repeating: 0, count: 64), Data(repeating: 0, count: 66),
                          Data(r + s + [255])] {
            let crypto = SignatureCryptoProbe()
            do {
                try await EIP191Verifier(crypto: crypto).verify(signature: signature, message: message, address: address)
                XCTFail("Malformed signature must fail")
            } catch { }
            XCTAssertEqual(crypto.recoveryCalls, 0)
        }
    }

    func testValidVerifierShapeReachesCryptoProvider() async throws {
        let crypto = SignatureCryptoProbe()
        try await EIP191Verifier(crypto: crypto).verify(signature: Data(r + s + [28]), message: message, address: address)
        XCTAssertEqual(crypto.recoveryCalls, 1)
    }

    func testContractEncodingMatchesIndependentVectors() throws {
        for (length, expected) in ContractSignatureVectors.calldata {
            let signature = Data((0..<length).map { UInt8($0 % 251) })
            let method = ValidSignatureMethod(signature: signature, messageHash: Data(repeating: 0xab, count: 32))
            XCTAssertEqual(try method.encode(), expected, "signature bytes \(length)")
        }
    }

    func testContractHashMustBeExactly32Bytes() {
        for length in [0, 1, 31, 33, 64] {
            let method = ValidSignatureMethod(signature: Data([1]), messageHash: Data(repeating: 0, count: length))
            XCTAssertThrowsError(try method.encode())
        }
    }

    func testFixedHashEncodingRejectsOversize() {
        XCTAssertThrowsError(try ContractEncoder.bytes(Data(repeating: 0, count: 33)))
    }

    func testFixedHashEncodingRejectsShortInputs() {
        for length in [0, 1, 31] {
            XCTAssertThrowsError(try ContractEncoder.bytes(Data(repeating: 0, count: length)))
        }
    }

    func testENSMethodsPreserveValidSelectors() throws {
        let hash = Data(repeating: 0xab, count: 32)
        let word = String(repeating: "ab", count: 32)
        XCTAssertEqual(try ENSResolverMethod(namehash: hash).encode(), "0x0178b8bf" + word)
        XCTAssertEqual(try ENSAddressMethod(namehash: hash).encode(), "0x3b3b57de" + word)
        XCTAssertEqual(try ENSNameMethod(namehash: hash).encode(), "0x691f3431" + word)
    }

    func testContractVerifierSendsCompleteVariableSignature() async throws {
        let http = ContractResponseProbe()
        let crypto = SignatureCryptoProbe()
        let verifier = EIP1271Verifier(projectId: "synthetic", httpClient: http, crypto: crypto)
        for length in [0, 1, 32, 64, 65, 130] {
            let signature = Data((0..<length).map { UInt8($0 % 251) })
            try await verifier.verify(signature: signature, message: message, address: address, chainId: "eip155:1")
            let body = try XCTUnwrap(http.requests.last)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["method"] as? String, "eth_call")
            let params = try XCTUnwrap(object["params"] as? [Any])
            let call = try XCTUnwrap(params.first as? [String: String])
            XCTAssertEqual(call["to"], address)
            XCTAssertEqual(call["data"], ContractSignatureVectors.calldata[length])
            XCTAssertEqual(params.last as? String, "latest")
        }
        XCTAssertEqual(http.requests.count, 6)
    }

    func testContractVerifierRejectsInvalidHashBeforeHTTP() async {
        let http = ContractResponseProbe()
        let crypto = SignatureCryptoProbe()
        crypto.hash = Data(repeating: 0, count: 31)
        do {
            try await EIP1271Verifier(projectId: "synthetic", httpClient: http, crypto: crypto)
                .verify(signature: Data(), message: message, address: address, chainId: "eip155:1")
            XCTFail("Invalid hash must fail before RPC")
        } catch { }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testContractVerifierRejectsMagicPrefixWithGarbage() async {
        let magic = "0x1626ba7e"
        let values = [magic + "garbage", magic + "0", magic + String(repeating: "0", count: 55) + "1",
                      magic + String(repeating: "0", count: 120), magic + " ", "0xffffffff",
                      "0x" + String(repeating: "0", count: 64), "", "1626ba7e"]
        for result in values {
            let http = ContractResponseProbe()
            http.result = result
            do {
                try await EIP1271Verifier(projectId: "synthetic", httpClient: http, crypto: SignatureCryptoProbe())
                    .verify(signature: Data(), message: message, address: address, chainId: "eip155:1")
                XCTFail("Malformed contract return must fail")
            } catch { }
            XCTAssertEqual(http.requests.count, 1)
        }
    }

    func testContractVerifierAcceptsCanonicalAndLegacyReturns() async throws {
        let magic = "0x1626ba7e"
        for result in [magic, magic + String(repeating: "0", count: 56),
                       "0x1626BA7E", "0x1626BA7E" + String(repeating: "0", count: 56)] {
            let http = ContractResponseProbe()
            http.result = result
            try await EIP1271Verifier(projectId: "synthetic", httpClient: http, crypto: SignatureCryptoProbe())
                .verify(signature: Data(), message: message, address: address, chainId: "eip155:1")
            XCTAssertEqual(http.requests.count, 1)
        }
    }
}
