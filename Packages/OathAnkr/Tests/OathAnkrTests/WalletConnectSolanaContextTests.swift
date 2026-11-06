import XCTest
@testable import OathAnkr

/// Public SDK vectors and injected RPC only; no network or funded accounts.
final class WalletConnectSolanaContextTests: XCTestCase {
    private struct Vectors: Decodable { let vectors: [Vector] }
    private struct Vector: Decodable { let name: String, account: String, unsigned: String }
    private func request(lookup: Bool = false) throws -> WalletConnectSolanaRequest {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "solana", withExtension: "json", subdirectory: "Fixtures/WalletConnect"))
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url)).vectors
        let v = try XCTUnwrap(vectors.first { $0.name == (lookup ? "v0Lookup" : "legacy") })
        return try .init(method: "solana_signTransaction", chain: SolanaSendNetwork.devnet.walletConnectChain, account: v.account,
            params: JSONEncoder().encode(SolanaJSON.object(["transaction": .string(v.unsigned), "sendOptions": .object(["minContextSlot": .number("100")]) ])))
    }
    private var badContexts: [SolanaJSON?] { [nil, .null, .object([:]), .object(["slot": .string("123")]), .object(["slot": .number("-1")]), .object(["slot": .number("1.5")])] }
    private func rejects(_ input: WalletConnectSolanaRequest, method: String, context: SolanaJSON?) async throws {
        let transport = ContextRPC(input: input, overrideMethod: method, context: context)
        let client = try SolanaSendClient(network: .devnet, transport: transport)
        do { _ = try await client.walletConnectReview(input); XCTFail("Invalid response context accepted for \(method)") }
        catch { XCTAssertEqual(error as? SolanaSendError, .malformed) }
        let calls = await transport.calls
        XCTAssertEqual(calls.last?["method"].string, method, "No later review read may follow invalid context")
    }
    func testFreshContextsPreserveReviewAndFalseBlockhashRemainsExpired() async throws {
        let input = try request(), transport = ContextRPC(input: input)
        let client = try SolanaSendClient(network: .devnet, transport: transport)
        let review = try await client.walletConnectReview(input)
        XCTAssertEqual(review.count, 1); XCTAssertEqual(review[0].fee, 5000); XCTAssertEqual(review[0].slot, 123)
        XCTAssertTrue(review[0].changes.isEmpty)
        let expired = try SolanaSendClient(network: .devnet, transport: ContextRPC(input: input, blockhash: false))
        let valid = try await expired.walletConnectTransactionValid(input.transactions[0], minimumSlot: 100)
        XCTAssertFalse(valid)
    }
    func testStaleBlockhashCannotValidateOrExpirePendingTransaction() async throws {
        let input = try request()
        for valid in [true, false] {
            let transport = ContextRPC(input: input, overrideMethod: "isBlockhashValid", context: .object(["slot": .number("99")]), blockhash: valid)
            let client = try SolanaSendClient(network: .devnet, transport: transport)
            do { _ = try await client.walletConnectTransactionValid(input.transactions[0], minimumSlot: 100, finalized: true); XCTFail("Stale blockhash state accepted") }
            catch { XCTAssertEqual(error as? SolanaSendError, .malformed) }
        }
    }
    func testMissingAndMalformedBlockhashContextsAreRejected() async throws {
        for context in badContexts { try await rejects(request(), method: "isBlockhashValid", context: context) }
    }
    func testSimulationMustNotPredateObservedAccounts() async throws {
        for context in badContexts + [.object(["slot": .number("122")])] { try await rejects(request(), method: "simulateTransaction", context: context) }
    }
    func testFeeMustNotPredateObservedAccounts() async throws {
        for context in badContexts + [.object(["slot": .number("122")])] { try await rejects(request(), method: "getFeeForMessage", context: context) }
    }
    func testLookupContextsMustSatisfyRequestedMinimum() async throws {
        for context in badContexts + [.object(["slot": .number("99")])] { try await rejects(request(lookup: true), method: "getAccountInfo", context: context) }
    }
    func testAdvanceOfSimulationSlotCarriesIntoFeeRequestAndReview() async throws {
        let input = try request(), transport = ContextRPC(input: input, simulationSlot: 125)
        let result = try await SolanaSendClient(network: .devnet, transport: transport).walletConnectReview(input)[0]
        XCTAssertEqual(result.slot, 125, "Review position must reflect the simulated state")
        let calls = await transport.calls
        let fee = try XCTUnwrap(calls.first { $0["method"].string == "getFeeForMessage" })
        XCTAssertEqual(fee["params"].array?[1]["minContextSlot"].integer, 125, "Fee request must not regress below simulated state")
    }
    func testMintMetadataMustNotPredateSimulation() async throws {
        let input = try request()
        for context in badContexts + [.object(["slot": .number("124")])] {
            let transport = ContextRPC(input: input, overrideMethod: "getAccountInfo", context: context, simulationSlot: 125, tokens: true)
            do { _ = try await SolanaSendClient(network: .devnet, transport: transport).walletConnectReview(input); XCTFail("Stale mint metadata accepted") }
            catch { XCTAssertEqual(error as? SolanaSendError, .malformed) }
        }
    }
    func testFreshAbsentMintKeepsExactBaseUnitsWithoutInventedPrecision() async throws {
        let input = try request(), transport = ContextRPC(input: input, simulationSlot: 125, tokens: true)
        let review = try await SolanaSendClient(network: .devnet, transport: transport).walletConnectReview(input)[0]
        let change = try XCTUnwrap(review.changes.first { $0.reference != "native" })
        XCTAssertEqual(change.amount, 100); XCTAssertFalse(change.increase); XCTAssertNil(change.decimals)
    }
    func testStandaloneBlockhashHelperRejectsMalformedContext() async throws {
        let input = try request()
        for context in badContexts {
            let transport = ContextRPC(input: input, overrideMethod: "isBlockhashValid", context: context)
            do { _ = try await SolanaSendClient(network: .devnet, transport: transport).walletConnectBlockhashValid(input.transactions[0].blockhash); XCTFail("Malformed blockhash context accepted") }
            catch { XCTAssertEqual(error as? SolanaSendError, .malformed) }
        }
    }
    func testAccountSnapshotAlreadyRejectsStaleAndMalformedContexts() async throws {
        for context in badContexts + [.object(["slot": .number("99")])] { try await rejects(request(), method: "getMultipleAccounts", context: context) }
    }
}

private actor ContextRPC: AnkrTransport {
    let input: WalletConnectSolanaRequest, overrideMethod: String?, context: SolanaJSON?, blockhash: Bool, simulationSlot: UInt64, tokens: Bool
    var calls: [SolanaJSON] = []
    init(input: WalletConnectSolanaRequest, overrideMethod: String? = nil, context: SolanaJSON? = nil, blockhash: Bool = true, simulationSlot: UInt64 = 123, tokens: Bool = false) {
        self.input=input; self.overrideMethod=overrideMethod; self.context=context; self.blockhash=blockhash; self.simulationSlot=simulationSlot; self.tokens=tokens
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        XCTAssertEqual(request.url?.host, "api.devnet.solana.com")
        let j = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody)), method = try XCTUnwrap(j["method"].string)
        calls.append(j)
        func balances(_ addresses: [SolanaJSON], after: Bool) throws -> [SolanaJSON] {
            try addresses.map { address in
                guard tokens else { return .null }
                if address.string == input.account { return .object(["lamports": .number(after ? "95000" : "100000")]) }
                var bytes = try SolanaSendCrypto.decode(input.transactions[0].keys[1]) + SolanaSendCrypto.decode(input.account)
                let amount: UInt64 = after ? 900 : 1000
                bytes += Data((0..<8).map { UInt8(truncatingIfNeeded: amount >> ($0*8)) })
                bytes += Data(repeating: 0, count: 93); bytes[108] = 1
                return .object(["owner": .string(SolanaIdentity.tokenProgram), "data": .array([.string(bytes.base64EncodedString()), .string("base64")])])
            }
        }
        let result: SolanaJSON
        if method == "getGenesisHash" { result = .string(SolanaSendNetwork.devnet.genesis) }
        else {
            let value: SolanaJSON
            switch method {
            case "isBlockhashValid": value = .bool(blockhash)
            case "getMultipleAccounts": value = .array(try balances(j["params"].array?[0].array ?? [], after: false))
            case "simulateTransaction": value = .object(["err": .null, "accounts": .array(try balances(j["params"].array?[1]["accounts"]["addresses"].array ?? [], after: true))])
            case "getFeeForMessage": value = .number("5000")
            case "getAccountInfo":
                if tokens { value = .null; break }
                // Enough lookup addresses for the public v0 vector; distinct from static keys.
                var bytes = Data([1,0,0,0]) + Data(repeating: 0, count: 52)
                for b: UInt8 in 20...30 { bytes += Data(repeating: b, count: 32) }
                value = .object(["owner": .string("AddressLookupTab1e1111111111111111111111111"), "data": .array([.string(bytes.base64EncodedString()), .string("base64")])])
            default: XCTFail("Unexpected method"); throw SolanaSendError.malformed
            }
            var fields: [String: SolanaJSON] = ["value": value]
            if overrideMethod == method { fields["context"] = context }
            else { fields["context"] = .object(["slot": .number(String(method == "simulateTransaction" || method == "getFeeForMessage" || (method == "getAccountInfo" && tokens) ? simulationSlot : 123))]) }
            result = .object(fields)
        }
        return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": j["id"], "result": result])),200)
    }
}
