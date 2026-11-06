import XCTest
@testable import OathAnkr

/// Public, synthetic SDK vectors; no network access or funded accounts.
final class WalletConnectSolanaBufferTests: XCTestCase {
    private struct Fixture: Decodable { let vectors: [Vector] }
    private struct Vector: Decodable { let account: String, unsigned: String, signed: String }
    private func vectors() throws -> [Vector] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "solana", withExtension: "json", subdirectory: "Fixtures/WalletConnect"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).vectors
    }
    private func slice(_ bytes: Data, offset: Int) -> Data {
        (Data(repeating: 0xA5, count: offset) + bytes).dropFirst(offset)
    }

    func testOrdinaryWireBuffersRetainTheirExactMessageAndSignatures() throws {
        for vector in try vectors() {
            let unsigned = try XCTUnwrap(Data(base64Encoded: vector.unsigned))
            let signed = try XCTUnwrap(Data(base64Encoded: vector.signed))
            let tx = try WalletConnectSolanaTransaction(bytes: unsigned, account: vector.account)
            let parsed = try WalletConnectSolanaTransaction(bytes: signed, account: vector.account)
            XCTAssertEqual(tx.message, parsed.message)
            try tx.verifySigned(signed, requireAll: true)
        }
    }

    func testSlicedUnsignedWireRetainsExactMessageAndNormalizedStorage() throws {
        for vector in try vectors() {
            let bytes = try XCTUnwrap(Data(base64Encoded: vector.unsigned))
            let ordinary = try WalletConnectSolanaTransaction(bytes: bytes, account: vector.account)
            for offset in [1, 128, 1024] {
                let sliced = slice(bytes, offset: offset)
                XCTAssertEqual(sliced.startIndex, offset)
                let parsed = try WalletConnectSolanaTransaction(bytes: sliced, account: vector.account)
                XCTAssertEqual(parsed.message, ordinary.message)
                XCTAssertEqual(parsed.bytes, bytes)
                XCTAssertEqual(parsed.bytes.startIndex, 0)
                XCTAssertEqual(parsed, ordinary)
            }
        }
    }

    func testSlicedSignedWireVerifiesAndTamperingStillFails() throws {
        for vector in try vectors() {
            let unsigned = try XCTUnwrap(Data(base64Encoded: vector.unsigned))
            let signed = try XCTUnwrap(Data(base64Encoded: vector.signed))
            let ordinary = try WalletConnectSolanaTransaction(bytes: unsigned, account: vector.account)
            for offset in [1, 128, 1024] {
                let sliced = slice(signed, offset: offset)
                XCTAssertEqual(sliced.startIndex, offset)
                let parsed = try WalletConnectSolanaTransaction(bytes: sliced, account: vector.account)
                XCTAssertEqual(parsed.message, ordinary.message)
                try ordinary.verifySigned(sliced, requireAll: true)
                var corrupt = signed; corrupt[2] ^= 1
                XCTAssertThrowsError(try ordinary.verifySigned(slice(corrupt, offset: offset), requireAll: true))
            }
        }
    }
    func testSlicedSubmissionPreservesExactWireSignatureAndPreflight() async throws {
        for vector in try vectors() {
            let request = try WalletConnectSolanaRequest(method: "solana_signAndSendTransaction",
                chain: SolanaSendNetwork.devnet.walletConnectChain, account: vector.account,
                params: JSONEncoder().encode(SolanaJSON.object(["transaction": .string(vector.unsigned)])))
            let signed = try XCTUnwrap(Data(base64Encoded: vector.signed))
            let expected = SolanaSendCrypto.encode(signed.subdata(in: 1..<65))
            for offset in [1, 128, 1024] {
                let transport = BufferResponses(signature: expected)
                let client = try SolanaSendClient(network: .devnet, transport: transport)
                let result = try await client.walletConnectSubmit(slice(signed, offset: offset), request: request)
                XCTAssertEqual(result, expected)
                let calls = await transport.requests
                XCTAssertEqual(calls.compactMap { $0["method"].string }, ["getGenesisHash", "sendTransaction"])
                let params = try XCTUnwrap(calls.last?["params"].array)
                XCTAssertEqual(params[0].string, vector.signed)
                XCTAssertEqual(params[1]["skipPreflight"], .bool(false))
                XCTAssertEqual(params[1]["preflightCommitment"].string, "confirmed")
                var corrupt = signed; corrupt[2] ^= 1
                do {
                    _ = try await client.walletConnectSubmit(slice(corrupt, offset: offset), request: request)
                    XCTFail("Invalid signatures must fail before transport")
                } catch { XCTAssertEqual(error as? SolanaSendError, .signing) }
                let callsAfterInvalid = await transport.requests
                XCTAssertEqual(callsAfterInvalid, calls)
            }
        }
    }

    func testMalformedSlicesRemainRejected() throws {
        for vector in try vectors() {
            let bytes = try XCTUnwrap(Data(base64Encoded: vector.unsigned))
            for offset in [1, 128, 1024] {
                for length in [0, 1, 64, 65, bytes.count - 1] {
                    XCTAssertThrowsError(try WalletConnectSolanaTransaction(
                        bytes: slice(Data(bytes.prefix(length)), offset: offset), account: vector.account))
                }
                XCTAssertThrowsError(try WalletConnectSolanaTransaction(
                    bytes: slice(bytes + Data([0]), offset: offset), account: vector.account))
                XCTAssertThrowsError(try WalletConnectSolanaTransaction(
                    bytes: slice(Data(repeating: 0, count: 1233), offset: offset), account: vector.account))
            }
        }
    }

}


private actor BufferResponses: AnkrTransport {
    let signature: String
    var requests: [SolanaJSON] = []
    init(signature: String) { self.signature = signature }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        XCTAssertEqual(request.url?.host, "api.devnet.solana.com")
        let json = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        let method = try XCTUnwrap(json["method"].string)
        requests.append(json)
        let result: SolanaJSON
        switch method {
        case "getGenesisHash": result = .string(SolanaSendNetwork.devnet.genesis)
        case "sendTransaction": result = .string(signature)
        default: throw SolanaSendError.malformed
        }
        return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"),
            "id": json["id"], "result": result])), 200)
    }
}
