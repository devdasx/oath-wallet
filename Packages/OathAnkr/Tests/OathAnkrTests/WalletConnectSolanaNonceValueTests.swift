import XCTest
@testable import OathAnkr

/// Existing public SDK nonce vectors and injected RPC only.
final class WalletConnectSolanaNonceValueTests: XCTestCase {
    private struct Fixture: Decodable { let account: String, unsigned: String, unsignedV0: String, state: String }
    private func inputs() throws -> (Fixture, [WalletConnectSolanaRequest]) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "solana-nonce", withExtension: "json", subdirectory: "Fixtures/WalletConnect"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let requests = try [fixture.unsigned, fixture.unsignedV0].map {
            try WalletConnectSolanaRequest(method: "solana_signTransaction", chain: SolanaSendNetwork.devnet.walletConnectChain, account: fixture.account,
                params: JSONEncoder().encode(SolanaJSON.object(["transaction": .string($0)])))
        }
        return (fixture, requests)
    }
    private func response(_ value: SolanaJSON?) -> SolanaJSON {
        var fields: [String: SolanaJSON] = ["context": .object(["slot": .number("123")])]
        fields["value"] = value
        return .object(fields)
    }
    func testLiveNonceStillValidForLegacyAndVersionZero() async throws {
        let (fixture, requests) = try inputs()
        let account: SolanaJSON = .object(["owner": .string(SolanaSendCrypto.system), "executable": .bool(false), "data": .array([.string(fixture.state), .string("base64")])])
        for input in requests {
            let rpc = NonceValueRPC(result: response(account))
            let valid = try await SolanaSendClient(network: .devnet, transport: rpc).walletConnectTransactionValid(input.transactions[0], minimumSlot: 123, finalized: true)
            XCTAssertTrue(valid)
            let calls = await rpc.calls
            XCTAssertEqual(calls.last?["params"].array?[1]["commitment"].string, "finalized")
        }
    }
    func testExplicitNullStillMeansClosedNonce() async throws {
        for input in try inputs().1 {
            let valid = try await SolanaSendClient(network: .devnet, transport: NonceValueRPC(result: response(.null))).walletConnectTransactionValid(input.transactions[0], minimumSlot: 123, finalized: true)
            XCTAssertFalse(valid)
        }
    }
    func testMissingValueCannotBecomeRecoveryExpiry() async throws {
        for input in try inputs().1 {
            do {
                _ = try await SolanaSendClient(network: .devnet, transport: NonceValueRPC(result: response(nil))).walletConnectTransactionValid(input.transactions[0], minimumSlot: 123, finalized: true)
                XCTFail("Missing nonce value interpreted as expired")
            } catch { XCTAssertEqual(error as? SolanaSendError, .malformed) }
        }
    }
    func testMissingValueFailsReviewAsMalformedNotExpired() async throws {
        for input in try inputs().1 {
            let rpc = NonceValueRPC(result: response(nil))
            do { _ = try await SolanaSendClient(network: .devnet, transport: rpc).walletConnectReview(input); XCTFail("Missing nonce value accepted") }
            catch { XCTAssertEqual(error as? SolanaSendError, .malformed, "Missing nonce value is not expiration evidence") }
            let calls = await rpc.calls
            XCTAssertEqual(calls.map { $0["method"].string }, ["getGenesisHash", "getAccountInfo"])
        }
    }
    func testInvalidValueTypesRemainMalformed() async throws {
        for input in try inputs().1 {
            for value: SolanaJSON in [.bool(false), .number("0"), .string("null"), .array([]), .object([:])] {
                do { _ = try await SolanaSendClient(network: .devnet, transport: NonceValueRPC(result: response(value))).walletConnectTransactionValid(input.transactions[0]); XCTFail("Invalid nonce value accepted") }
                catch { XCTAssertEqual(error as? SolanaSendError, .malformed) }
            }
        }
    }
    func testInvalidContextStillCannotProveClosedNonce() async throws {
        for input in try inputs().1 {
            for context: SolanaJSON in [.null, .object([:]), .object(["slot": .number("122")]), .object(["slot": .string("123")])] {
                let result: SolanaJSON = .object(["context": context, "value": .null])
                do { _ = try await SolanaSendClient(network: .devnet, transport: NonceValueRPC(result: result)).walletConnectTransactionValid(input.transactions[0], minimumSlot: 123, finalized: true); XCTFail("Invalid context accepted") }
                catch { XCTAssertEqual(error as? SolanaSendError, .malformed) }
            }
        }
    }
}

private actor NonceValueRPC: AnkrTransport {
    let result: SolanaJSON
    var calls: [SolanaJSON] = []
    init(result: SolanaJSON) { self.result = result }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        XCTAssertEqual(request.url?.host, "api.devnet.solana.com")
        let call = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody)); calls.append(call)
        let value: SolanaJSON
        switch call["method"].string {
        case "getGenesisHash": value = .string(SolanaSendNetwork.devnet.genesis)
        case "getAccountInfo": value = result
        default: XCTFail("Unexpected nonce RPC"); throw SolanaSendError.malformed
        }
        return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": call["id"], "result": value])), 200)
    }
}
