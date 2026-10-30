import XCTest
import CryptoKit
@testable import OathAnkr

final class WalletConnectSolanaTests: XCTestCase {
    struct Vectors: Decodable { let vectors: [Vector] }
    struct Vector: Decodable { let name: String, account: String, unsigned: String, signed: String }
    func vectors() throws -> [Vector] {
        try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: Bundle.module.url(forResource: "solana", withExtension: "json", subdirectory: "Fixtures/WalletConnect")!)).vectors
    }
    func input(_ vector: Vector, method: String = "solana_signTransaction", network: SolanaSendNetwork = .devnet) throws -> WalletConnectSolanaRequest {
        try .init(method: method, chain: network.walletConnectChain, account: vector.account,
                  params: JSONEncoder().encode(SolanaJSON.object(["transaction": .string(vector.unsigned)])))
    }
    func testIndependentLegacyVersionedLookupAndPartialMultisigSignatures() throws {
        for v in try vectors() {
            let request = try input(v), signed = try request.sign(privateKey: Data(repeating: 1, count: 32))
            try request.transactions[0].verifySigned(Data(base64Encoded: v.signed)!, requireAll: true)
            try request.transactions[0].verifySigned(signed.transactions[0], requireAll: true)
            XCTAssertNotNil(signed.response["signature"].string)
            XCTAssertEqual(signed.response["transaction"].string, signed.transactions[0].base64EncodedString())
            XCTAssertThrowsError(try request.sign(privateKey: Data(repeating: 2, count: 32)))
        }
    }
    func testAllThreeClustersHaveExactCAIPIdentity() throws {
        let v = try vectors()[0]
        let chains = ["solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp", "solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1", "solana:4uhcVJyU9pJkvQyS88uRDiswHXSCkY3z"]
        for chain in chains { XCTAssertNotNil(SolanaSendNetwork(walletConnectChain: chain)); XCTAssertNil(SolanaSendNetwork(walletConnectChain: chain.lowercased())) }
        XCTAssertNil(SolanaSendNetwork(walletConnectChain: "solana:mainnet"))
        XCTAssertNil(SolanaSendNetwork(walletConnectChain: "eip155:1"))
        XCTAssertEqual(Set(try [SolanaSendNetwork.mainnet, .devnet, .testnet].map { try input(v, network: $0).fingerprint }).count, 3)
    }
    func testExactCaseAccountAndPubkeyAreRequired() throws {
        let v = try vectors()[0], params = try JSONEncoder().encode(SolanaJSON.object(["transaction": .string(v.unsigned), "pubkey": .string(v.account.lowercased())]))
        XCTAssertThrowsError(try WalletConnectSolanaRequest(method: "solana_signTransaction", chain: SolanaSendNetwork.devnet.walletConnectChain, account: v.account, params: params))
        XCTAssertThrowsError(try WalletConnectSolanaTransaction(bytes: Data(base64Encoded: v.unsigned)!, account: v.account.lowercased()))
    }
    func testHistoricalClusterIdentifiersPreserveNetworkSigningAndFingerprint() throws {
        let vector = try vectors()[0]
        let params = try JSONEncoder().encode(SolanaJSON.object(["transaction": .string(vector.unsigned)]))
        for network in [SolanaSendNetwork.mainnet, .devnet, .testnet] {
            let canonical = try input(vector, network: network)
            for chain in network.walletConnectChains {
                XCTAssertEqual(SolanaSendNetwork(walletConnectChain: chain), network)
                XCTAssertNil(SolanaSendNetwork(walletConnectChain: chain.lowercased()))
                let request = try WalletConnectSolanaRequest(method: canonical.method, chain: chain, account: vector.account, params: params)
                XCTAssertEqual(request.fingerprint, canonical.fingerprint)
                let signed = try request.sign(privateKey: Data(repeating: 1, count: 32))
                try canonical.transactions[0].verifySigned(signed.transactions[0], requireAll: true)
                XCTAssertEqual(request.transactions[0].message, canonical.transactions[0].message)
            }
        }
        for chain in ["solana:mainnet-beta", "solana:devnet", "solana:8E9rvCKLFQia2Y35HXjjpWzj8weVo44X"] {
            XCTAssertNil(SolanaSendNetwork(walletConnectChain: chain))
        }
    }
    func testBatchIsAtomicOrderedAndBounded() throws {
        let vectors = try vectors(), params = try JSONEncoder().encode(SolanaJSON.object(["transactions": .array(vectors.map { .string($0.unsigned) })]))
        let input = try WalletConnectSolanaRequest(method: "solana_signAllTransactions", chain: SolanaSendNetwork.devnet.walletConnectChain, account: vectors[0].account, params: params)
        let signed = try input.sign(privateKey: Data(repeating: 1, count: 32))
        XCTAssertEqual(signed.response["transactions"].array?.count, vectors.count)
        for index in vectors.indices {
            try input.transactions[index].verifySigned(signed.transactions[index], requireAll: true)
            XCTAssertEqual(try WalletConnectSolanaTransaction(bytes: signed.transactions[index], account: vectors[index].account).message, input.transactions[index].message)
        }
        for count in [0,9] {
            let params = try JSONEncoder().encode(SolanaJSON.object(["transactions": .array(Array(repeating: .string(vectors[0].unsigned), count: count))]))
            XCTAssertThrowsError(try WalletConnectSolanaRequest(method: "solana_signAllTransactions", chain: SolanaSendNetwork.devnet.walletConnectChain, account: vectors[0].account, params: params))
        }
    }
    func testTextChallengesUseBase58AndCannotSignTransactionMessages() throws {
        let v = try vectors()[0], message = Data("Sign in to Oath\nمرحبا".utf8)
        let params = try JSONEncoder().encode(SolanaJSON.object(["pubkey": .string(v.account), "message": .string(SolanaSendCrypto.encode(message))]))
        let request = try WalletConnectSolanaRequest(method: "solana_signMessage", chain: SolanaSendNetwork.testnet.walletConnectChain, account: v.account, params: params)
        let signed = try request.sign(privateKey: Data(repeating: 1, count: 32)), signature = try SolanaSendCrypto.decode(XCTUnwrap(signed.response["signature"].string))
        XCTAssertTrue(try Curve25519.Signing.PublicKey(rawRepresentation: SolanaSendCrypto.decode(v.account)).isValidSignature(signature, for: message))
        let tx = try input(v).transactions[0]
        for bytes in [tx.message, Data([0,1,2]), Data("evil\u{202e}text".utf8)] {
            let params = try JSONEncoder().encode(SolanaJSON.object(["pubkey": .string(v.account), "message": .string(SolanaSendCrypto.encode(bytes))]))
            XCTAssertThrowsError(try WalletConnectSolanaRequest(method: "solana_signMessage", chain: SolanaSendNetwork.devnet.walletConnectChain, account: v.account, params: params))
        }
    }
    func testMalformedTruncatedNoncanonicalAndAlteredSignaturesFailClosed() throws {
        let v = try vectors()[0], bytes = Data(base64Encoded: v.unsigned)!
        for length in [0,1,64,65,bytes.count-1] {
            XCTAssertThrowsError(try WalletConnectSolanaTransaction(bytes: Data(bytes.prefix(length)), account: v.account))
        }
        XCTAssertThrowsError(try WalletConnectSolanaTransaction(bytes: bytes + Data([0]), account: v.account))
        XCTAssertThrowsError(try WalletConnectSolanaTransaction(bytes: Data([129,0])+bytes.dropFirst(), account: v.account))
        var invalid = Data(base64Encoded: v.signed)!; invalid[2] ^= 1
        XCTAssertThrowsError(try WalletConnectSolanaTransaction(bytes: invalid, account: v.account))
        var wrongVersion = bytes; wrongVersion[65] = 129
        XCTAssertThrowsError(try WalletConnectSolanaTransaction(bytes: wrongVersion, account: v.account))
        let duplicate = Data("{\"transaction\":\"x\",\"transaction\":\"y\"}".utf8)
        XCTAssertThrowsError(try WalletConnectSolanaRequest(method: "solana_signTransaction", chain: SolanaSendNetwork.devnet.walletConnectChain, account: v.account, params: duplicate))
    }
    func testSignedBytesMustMatchExactReviewAndPreserveCosigner() throws {
        let v = try vectors()[2], request = try input(v), signed = try request.sign(privateKey: Data(repeating: 1, count: 32))
        var corrupt = signed.transactions[0]; corrupt[1] ^= 1
        XCTAssertThrowsError(try request.transactions[0].verifySigned(corrupt, requireAll: true))
        var unsigned = Data(base64Encoded: v.unsigned)!; unsigned.replaceSubrange(1..<65, with: Data(repeating: 0, count: 64))
        let missing = try WalletConnectSolanaTransaction(bytes: unsigned, account: v.account)
        XCTAssertThrowsError(try missing.verifySigned(unsigned, requireAll: true))
    }
    func testSimulationShowsNativeAndTokenChangesFromSelectedCluster() async throws {
        let request = try input(vectors()[0]), mint = request.transactions[0].keys[1]
        func native(_ amount: UInt64) -> SolanaJSON { .object(["lamports": .number(String(amount))]) }
        func token(_ amount: UInt64) throws -> SolanaJSON {
            var bytes = try SolanaSendCrypto.decode(mint) + SolanaSendCrypto.decode(request.account)
            bytes += Data((0..<8).map { UInt8(truncatingIfNeeded: amount >> ($0 * 8)) })
            bytes += Data(repeating: 0, count: 165 - bytes.count)
            return .object(["owner": .string(SolanaIdentity.token2022Program), "data": .array([.string(bytes.base64EncodedString()), .string("base64")])])
        }
        var mintBytes = Data(repeating: 0, count: 82); mintBytes[44] = 6
        let transport = SolanaWCResponses([
            "isBlockhashValid": .object(["value": .bool(true)]),
            "getMultipleAccounts": .object(["context": .object(["slot": .number("123")]), "value": .array([native(100_000), try token(3_000_000)])]),
            "simulateTransaction": .object(["value": .object(["err": .null, "accounts": .array([native(95_000), try token(2_000_000)])])]),
            "getFeeForMessage": .object(["value": .number("5000")]),
            "getAccountInfo": .object(["value": .object(["owner": .string(SolanaIdentity.token2022Program), "data": .array([.string(mintBytes.base64EncodedString()), .string("base64")])])])
        ])
        let review = try await SolanaSendClient(network: .devnet, transport: transport).walletConnectReview(request)[0]
        XCTAssertEqual(review.fee, 5000); XCTAssertFalse(review.incomplete)
        XCTAssertEqual(review.changes.first { $0.reference == "native" }?.amount, 5000)
        let change = try XCTUnwrap(review.changes.first { $0.reference == mint })
        XCTAssertEqual(change.amount, 1_000_000); XCTAssertFalse(change.increase); XCTAssertEqual(change.decimals, 6)
        let calls = await transport.requests
        let config = try XCTUnwrap(calls.first { $0["method"].string == "simulateTransaction" }?["params"].array?[1])
        XCTAssertEqual(config["replaceRecentBlockhash"], .bool(false))
        XCTAssertEqual(config["minContextSlot"].integer, 123)
    }
    func testSponsoredSignerMayHaveNoNativeAccountAndSimulationFailureStopsReview() async throws {
        let request = try input(vectors()[0])
        let responses: [String: SolanaJSON] = [
            "isBlockhashValid": .object(["value": .bool(true)]),
            "getMultipleAccounts": .object(["context": .object(["slot": .number("1")]), "value": .array([.null, .null])]),
            "simulateTransaction": .object(["value": .object(["err": .null, "accounts": .array([.null, .null])])]),
            "getFeeForMessage": .object(["value": .number("5000")])
        ]
        let review = try await SolanaSendClient(network: .devnet, transport: SolanaWCResponses(responses)).walletConnectReview(request)[0]
        XCTAssertTrue(review.changes.isEmpty)
        var failed = responses
        failed["simulateTransaction"] = .object(["value": .object(["err": .string("InstructionError")])])
        let transport = SolanaWCResponses(failed)
        do { _ = try await SolanaSendClient(network: .devnet, transport: transport).walletConnectReview(request); XCTFail() }
        catch { XCTAssertEqual(error as? SolanaSendError, .simulationFailed) }
        let calls = await transport.requests
        XCTAssertFalse(calls.contains { $0["method"].string == "getFeeForMessage" })
    }
    func testSubmissionPreservesBytesAndForcesPreflightAndExactSignature() async throws {
        let request = try input(vectors()[0], method: "solana_signAndSendTransaction")
        let bytes = try request.sign(privateKey: Data(repeating: 1, count: 32)).transactions[0]
        let signature = SolanaSendCrypto.encode(bytes.subdata(in: 1..<65))
        let transport = SolanaWCResponses(["sendTransaction": .string(signature)])
        let result = try await SolanaSendClient(network: .devnet, transport: transport).walletConnectSubmit(bytes, request: request)
        XCTAssertEqual(result, signature)
        let calls = await transport.requests, params = try XCTUnwrap(calls.last?["params"].array)
        XCTAssertEqual(params[0].string, bytes.base64EncodedString())
        XCTAssertEqual(params[1]["skipPreflight"], .bool(false))
        XCTAssertEqual(params[1]["preflightCommitment"].string, "confirmed")
        let bad = SolanaWCResponses(["sendTransaction": .string("different-signature")])
        do { _ = try await SolanaSendClient(network: .devnet, transport: bad).walletConnectSubmit(bytes, request: request); XCTFail() }
        catch { XCTAssertEqual(error as? SolanaSendError, .malformed) }
    }
    func testStatusSeparatesUnknownAcceptedFailedAndConfirmed() async throws {
        let request = try input(vectors()[0]), bytes = try request.sign(privateKey: Data(repeating: 1, count: 32)).transactions[0]
        let signature = SolanaSendCrypto.encode(bytes.subdata(in: 1..<65))
        let cases: [(SolanaJSON, SolanaSendReceipt.Outcome)] = [(.null, .unknown),
            (.object(["err": .null, "confirmationStatus": .string("processed")]), .accepted),
            (.object(["err": .null, "confirmationStatus": .string("confirmed")]), .confirmed),
            (.object(["err": .null, "confirmationStatus": .string("finalized")]), .confirmed),
            (.object(["err": .string("InstructionError")]), .failed)]
        for (value, expected) in cases {
            let transport = SolanaWCResponses(["getSignatureStatuses": .object(["value": .array([value])])])
            let observed = try await SolanaSendClient(network: .devnet, transport: transport).walletConnectStatus(signature)
            XCTAssertEqual(observed, expected)
        }
    }
    func testWrongClusterClientNeverUsesTransport() async throws {
        let input = try input(vectors()[0], network: .testnet)
        let transport = SolanaWCTransport(genesis: SolanaSendNetwork.mainnet.genesis)
        let client = try SolanaSendClient(network: .devnet, transport: transport)
        do { _ = try await client.walletConnectReview(input); XCTFail() } catch { XCTAssertEqual(error as? SolanaSendError, .wrongNetwork) }
        let calls = await transport.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testProviderGenesisMismatchCannotSimulateOrSend() async throws {
        let input = try input(vectors()[0]), transport = SolanaWCTransport(genesis: SolanaSendNetwork.mainnet.genesis)
        let client = try SolanaSendClient(network: .devnet, transport: transport)
        do { _ = try await client.walletConnectReview(input); XCTFail() } catch { XCTAssertEqual(error as? SolanaSendError, .wrongNetwork) }
        let calls = await transport.calls; XCTAssertEqual(calls, ["getGenesisHash"])
    }
    func testForeignOrExpiredBlockhashCannotSimulateOrSign() async throws {
        let input = try input(vectors()[0]), transport = SolanaWCTransport(genesis: SolanaSendNetwork.devnet.genesis)
        let client = try SolanaSendClient(network: .devnet, transport: transport)
        do { _ = try await client.walletConnectReview(input); XCTFail() } catch { XCTAssertEqual(error as? SolanaSendError, .expired) }
        let calls = await transport.calls; XCTAssertEqual(calls, ["getGenesisHash", "isBlockhashValid"])
    }
}
private actor SolanaWCTransport: AnkrTransport {
    let genesis: String
    var calls: [String] = []
    init(genesis: String) { self.genesis = genesis }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let json = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!), method = json["method"].string!
        calls.append(method)
        XCTAssertEqual(request.url?.host, "api.devnet.solana.com")
        let result: SolanaJSON = method == "getGenesisHash" ? .string(genesis) : .object(["value": .bool(false)])
        return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": .number("1"), "result": result])), 200)
    }
}

private actor SolanaWCResponses: AnkrTransport {
    let responses: [String: SolanaJSON]
    var requests: [SolanaJSON] = []
    init(_ responses: [String: SolanaJSON]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        XCTAssertEqual(request.url?.host, "api.devnet.solana.com")
        let json = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!), method = json["method"].string!
        requests.append(json)
        let result = method == "getGenesisHash" ? SolanaJSON.string(SolanaSendNetwork.devnet.genesis) : responses[method]
        return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": .number("1"), "result": try XCTUnwrap(result, method)])), 200)
    }
}
