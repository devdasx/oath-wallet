import XCTest
@testable import OathAnkr

final class WalletConnectSolanaNonceTests: XCTestCase {
    struct Fixture: Decodable { let account: String, unsigned: String, signed: String, unsignedV0: String, signedV0: String, nonceAccount: String, nonce: String, state: String }
    func fixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Bundle.module.url(forResource: "solana-nonce", withExtension: "json", subdirectory: "Fixtures/WalletConnect")!))
    }
    func request(_ f: Fixture) throws -> WalletConnectSolanaRequest {
        try .init(method: "solana_signTransaction", chain: SolanaSendNetwork.devnet.walletConnectChain, account: f.account,
            params: JSONEncoder().encode(SolanaJSON.object(["transaction": .string(f.unsigned)])))
    }
    func account(_ state: String, owner: String = SolanaSendCrypto.system) -> SolanaJSON {
        .object(["owner": .string(owner), "executable": .bool(false), "data": .array([.string(state), .string("base64")])])
    }
    func testDurableNonceReviewAndSignaturesPreserveWireMessage() async throws {
        let f = try fixture(), input = try request(f), tx = input.transactions[0]
        XCTAssertEqual(try tx.durableNonce()?.address, f.nonceAccount)
        XCTAssertEqual(try tx.durableNonce()?.authority, f.account)
        try tx.verifySigned(Data(base64Encoded: f.signed)!, requireAll: true)
        let transport = NonceResponses(account: account(f.state))
        let client = try SolanaSendClient(network: .devnet, transport: transport)
        let reviews = try await client.walletConnectReview(input)
        XCTAssertEqual(reviews.count, 1)
        XCTAssertEqual(reviews[0].fee, 5000)
        let signed = try input.sign(privateKey: Data(repeating: 1, count: 32))
        try tx.verifySigned(signed.transactions[0], requireAll: true)
        let calls = await transport.calls
        XCTAssertFalse(calls.contains { $0["method"].string == "isBlockhashValid" })
        let sim = try XCTUnwrap(calls.first { $0["method"].string == "simulateTransaction" })
        XCTAssertEqual(sim["params"].array?[0].string, f.unsigned)
        XCTAssertEqual(sim["params"].array?[1]["replaceRecentBlockhash"], .bool(false))
    }
    func testConsumedRevokedClosedAndUninitializedNonceAreInvalid() async throws {
        let f = try fixture(), tx = try request(f).transactions[0], original = Data(base64Encoded: f.state)!
        for offset in [4, 8, 40] {
            var changed = original; changed[offset] ^= 1
            let client = try SolanaSendClient(network: .devnet, transport: NonceResponses(account: account(changed.base64EncodedString())))
            let valid = try await client.walletConnectTransactionValid(tx, finalized: true)
            XCTAssertFalse(valid)
        }
        let client = try SolanaSendClient(network: .devnet, transport: NonceResponses(account: .null))
        let valid = try await client.walletConnectTransactionValid(tx, finalized: true)
        XCTAssertFalse(valid)
    }
    func testVersionZeroDurableNonceReviewAndSignatures() async throws {
        let f = try fixture()
        let input = try WalletConnectSolanaRequest(method: "solana_signTransaction", chain: SolanaSendNetwork.devnet.walletConnectChain,
            account: f.account, params: JSONEncoder().encode(SolanaJSON.object(["transaction": .string(f.unsignedV0)])))
        let tx = input.transactions[0]
        XCTAssertEqual(tx.version, 0)
        XCTAssertEqual(try tx.durableNonce()?.address, f.nonceAccount)
        try tx.verifySigned(Data(base64Encoded: f.signedV0)!, requireAll: true)
        let client = try SolanaSendClient(network: .devnet, transport: NonceResponses(account: account(f.state)))
        let review = try await client.walletConnectReview(input)
        XCTAssertEqual(review.count, 1)
        let signed = try input.sign(privateKey: Data(repeating: 1, count: 32))
        try tx.verifySigned(signed.transactions[0], requireAll: true)
    }
    func testMalformedOrStaleProviderDataDoesNotMeanExpired() async throws {
        let f = try fixture(), tx = try request(f).transactions[0]
        for state in [account("AA=="), account(f.state, owner: f.account)] {
            let client = try SolanaSendClient(network: .devnet, transport: NonceResponses(account: state))
            do { _ = try await client.walletConnectTransactionValid(tx); XCTFail() }
            catch { XCTAssertEqual(error as? SolanaSendError, .malformed) }
        }
        let client = try SolanaSendClient(network: .devnet, transport: NonceResponses(account: account(f.state)))
        do { _ = try await client.walletConnectTransactionValid(tx, minimumSlot: 999); XCTFail() }
        catch { XCTAssertEqual(error as? SolanaSendError, .malformed) }
    }
    func testRecoveryUsesFinalizedNonceStateWithoutRecentBlockhashExpiry() async throws {
        let f = try fixture(), tx = try request(f).transactions[0]
        let transport = NonceResponses(account: account(f.state))
        let client = try SolanaSendClient(network: .devnet, transport: transport)
        let valid = try await client.walletConnectTransactionValid(tx, minimumSlot: 123, finalized: true)
        XCTAssertTrue(valid)
        let calls = await transport.calls
        XCTAssertEqual(calls.last?["params"].array?[1]["commitment"].string, "finalized")
        XCTAssertEqual(calls.last?["params"].array?[1]["minContextSlot"].integer, 123)
    }
    func testPaidDevnetUsesDevnetEndpointAndChecksGenesis() async throws {
        let f = try fixture(), transport = NonceResponses(account: account(f.state), ankr: true)
        let client = try SolanaSendClient(network: .devnet, apiKey: "publictestfixture", transport: transport)
        _ = try await client.walletConnectReview(request(f))
        XCTAssertThrowsError(try SolanaSendClient(network: .testnet, apiKey: "publictestfixture"))
    }
    func testMalformedNonceInstructionCannotReachSigning() throws {
        let f = try fixture(), tx = try request(f).transactions[0]
        // Legacy vector has one-byte compact lengths and an unsigned signature.
        let instruction = tx.signatureOffset + tx.signatureCount * 64 + 4 + tx.keys.count * 32 + 32 + 1
        for (offset, value) in [(instruction + 2, UInt8(tx.keys.count - 1)),
                                (instruction + 3, UInt8(0)),
                                (instruction + 4, UInt8(tx.signatureCount))] {
            var bytes = tx.bytes; bytes[offset] = value
            XCTAssertThrowsError(try WalletConnectSolanaTransaction(bytes: bytes, account: f.account))
        }
    }
    func testConsumedNonceFailsBeforeSimulationOrSigning() async throws {
        let f = try fixture(); var state = Data(base64Encoded: f.state)!; state[40] ^= 1
        let transport = NonceResponses(account: account(state.base64EncodedString()))
        let client = try SolanaSendClient(network: .devnet, transport: transport)
        do { _ = try await client.walletConnectReview(request(f)); XCTFail() }
        catch { XCTAssertEqual(error as? SolanaSendError, .expired) }
        let calls = await transport.calls
        XCTAssertFalse(calls.contains { $0["method"].string == "simulateTransaction" })
    }
}

private actor NonceResponses: AnkrTransport {
    let account: SolanaJSON, ankr: Bool
    var calls: [SolanaJSON] = []
    init(account: SolanaJSON, ankr: Bool = false) { self.account = account; self.ankr = ankr }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        XCTAssertEqual(request.url?.host, ankr ? "rpc.ankr.com" : "api.devnet.solana.com")
        if ankr { XCTAssertTrue(request.url!.path.hasPrefix("/solana_devnet/")) }
        let call = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
        calls.append(call)
        let native: SolanaJSON = .object(["lamports": .number("1000000")])
        let result: SolanaJSON
        switch call["method"].string {
        case "getGenesisHash": result = .string(SolanaSendNetwork.devnet.genesis)
        case "getAccountInfo": result = .object(["context": .object(["slot": .number("123")]), "value": account])
        case "getMultipleAccounts": result = .object(["context": .object(["slot": .number("123")]), "value": .array([native, .null, .null])])
        case "simulateTransaction": result = .object(["value": .object(["err": .null, "accounts": .array([native, .null, .null])])])
        case "getFeeForMessage": result = .object(["value": .number("5000")])
        default: XCTFail("Unexpected nonce RPC"); throw SolanaSendError.malformed
        }
        return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": .number("1"), "result": result])), 200)
    }
}
