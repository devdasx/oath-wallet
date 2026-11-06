import XCTest
import CryptoKit
@testable import OathAnkr

/// Public deterministic SDK fixtures and injected account snapshots only.
/// This suite never connects to a node or uses a funded account.
final class WalletConnectSolanaStakeReviewTests: XCTestCase {
    struct Corpus: Decodable {
        let owner, seed, stake, attacker, program, before, after: String
        let vectors: [Vector]
    }
    struct Vector: Decodable { let version, kind, unsigned, signed, message: String }
    func corpus() throws -> Corpus {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "solana-stake-authority", withExtension: "json", subdirectory: "Fixtures/WalletConnect"))
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }
    func request(_ c: Corpus, _ v: Vector, method: String = "solana_signTransaction") throws -> WalletConnectSolanaRequest {
        let params: SolanaJSON = method == "solana_signAllTransactions"
            ? .object(["transactions": .array([.string(v.unsigned)])]) : .object(["transaction": .string(v.unsigned)])
        return try .init(method: method, chain: SolanaSendNetwork.devnet.walletConnectChain, account: c.owner, params: JSONEncoder().encode(params))
    }
    func account(_ bytes: Data, program: String, lamports: UInt64 = 20_000_000_000) -> SolanaJSON {
        .object(["owner": .string(program), "lamports": .number(String(lamports)), "executable": .bool(false),
                 "data": .array([.string(bytes.base64EncodedString()), .string("base64")])])
    }
    func review(_ c: Corpus, _ v: Vector, before: SolanaJSON, after: SolanaJSON,
                method: String = "solana_signTransaction") async throws -> WalletConnectSolanaReview {
        try await SolanaSendClient(network: .devnet, transport: StakeReviewRPC(owner: c.owner, stake: c.stake, before: before, after: after))
            .walletConnectReview(request(c, v, method: method))[0]
    }
    func rejected(_ c: Corpus, _ v: Vector, before: SolanaJSON, after: SolanaJSON,
                  marker: String, method: String = "solana_signTransaction") async throws {
        do {
            let r = try await review(c, v, before: before, after: after, method: method)
            // These checks establish the original misleading presentation, not a node exploit.
            XCTAssertEqual(r.changes.count, 1)
            XCTAssertEqual(r.changes.first?.reference, "native")
            XCTAssertEqual(r.changes.first?.amount, 5_000)
            XCTAssertTrue(r.delegations.isEmpty)
            XCTAssertFalse(r.incomplete)
            XCTFail(marker)
        } catch { XCTAssertEqual(error as? SolanaSendError, .unsupportedToken) }
    }
    func testSDKTransactionsAndSignaturesRetainExactBytes() throws {
        let c = try corpus()
        XCTAssertEqual(c.vectors.count, 10)
        for v in c.vectors {
            let input = try request(c, v)
            XCTAssertEqual(input.transactions[0].message.base64EncodedString(), v.message)
            try input.transactions[0].verifySigned(XCTUnwrap(Data(base64Encoded: v.signed)), requireAll: true)
            let signed = try input.sign(privateKey: XCTUnwrap(Data(base64Encoded: c.seed)))
            // CryptoKit may randomize Ed25519 signatures. Verify both signatures
            // and the exact message; signature-byte equality is not a contract.
            try input.transactions[0].verifySigned(signed.transactions[0], requireAll: true)
            let reparsed = try WalletConnectSolanaTransaction(bytes: signed.transactions[0], account: c.owner)
            XCTAssertEqual(reparsed.message, input.transactions[0].message)
        }
    }
    func testUnchangedStakeSnapshotDoesNotBlockUnrelatedProgram() async throws {
        let c = try corpus(), a = try account(XCTUnwrap(Data(base64Encoded: c.before)), program: c.program)
        for v in c.vectors where v.kind == "cpi" {
            let r = try await review(c, v, before: a, after: a)
            XCTAssertEqual(r.fee, 5_000); XCTAssertEqual(r.changes.count, 1)
            XCTAssertEqual(r.changes[0].amount, 5_000); XCTAssertFalse(r.incomplete)
        }
    }
    func testDirectStakeAuthorityCannotBecomeFeeOnlyReview() async throws {
        let c = try corpus(), before = try XCTUnwrap(Data(base64Encoded: c.before))
        for v in c.vectors where ["withdraw-authority", "stake-authority"].contains(v.kind) {
            var after = before
            let offset = v.kind == "withdraw-authority" ? 44 : 12
            after.replaceSubrange(offset..<offset+32, with: try SolanaSendCrypto.decode(c.attacker))
            for method in ["solana_signTransaction", "solana_signAllTransactions", "solana_signAndSendTransaction"] {
                try await rejected(c, v, before: account(before, program: c.program), after: account(after, program: c.program),
                                   marker: "Stake authority hidden by fee-only review", method: method)
            }
        }
    }
    func testCPIStakeAuthorityCannotHideInSimulation() async throws {
        let c = try corpus()
        for v in c.vectors where v.kind == "cpi" {
            for state: UInt8 in [1, 2] { for offset in [12, 44] {
                var before = try XCTUnwrap(Data(base64Encoded: c.before)); before[0] = state
                var after = before; after.replaceSubrange(offset..<offset+32, with: try SolanaSendCrypto.decode(c.attacker))
                try await rejected(c, v, before: account(before, program: c.program), after: account(after, program: c.program),
                                   marker: "CPI stake authority hidden by fee-only review")
            } }
        }
    }
    func testStakeWithdrawalCannotDisappearFromReview() async throws {
        let c = try corpus(), bytes = try XCTUnwrap(Data(base64Encoded: c.before))
        for v in c.vectors where v.kind == "withdraw" {
            try await rejected(c, v, before: account(bytes, program: c.program), after: account(bytes, program: c.program, lamports: 10_000_000_000),
                               marker: "Stake withdrawal hidden by fee-only review")
        }
    }
    func testClosingStakeAccountCannotDisappearFromReview() async throws {
        let c = try corpus(), before = try account(XCTUnwrap(Data(base64Encoded: c.before)), program: c.program)
        for v in c.vectors where v.kind == "cpi" {
            try await rejected(c, v, before: before, after: .null, marker: "Stake closure hidden by fee-only review")
        }
    }
    func testDirectStakeProgramRequiresDedicatedReviewEvenWithoutSnapshotChange() async throws {
        let c = try corpus(), a = try account(XCTUnwrap(Data(base64Encoded: c.before)), program: c.program)
        for v in c.vectors where v.kind == "noop-authority" {
            try await rejected(c, v, before: a, after: a, marker: "Unreviewed stake instruction accepted")
        }
    }
    func testNewStakeAccountCannotEscapeStateGuard() async throws {
        let c = try corpus(), after = try account(XCTUnwrap(Data(base64Encoded: c.before)), program: c.program)
        for v in c.vectors where v.kind == "cpi" {
            try await rejected(c, v, before: .null, after: after, marker: "Unreviewed stake creation accepted")
        }
    }
    func testUnreviewableStakeSnapshotsCannotBeAccepted() async throws {
        let c = try corpus(), a = try account(XCTUnwrap(Data(base64Encoded: c.before)), program: c.program)
        guard case .object(let fields) = a else { return XCTFail("Invalid fixture") }
        let mutations: [(String, SolanaJSON?)] = [
            ("owner", .string(SolanaSendCrypto.system)), ("owner", nil),
            ("data", .null), ("data", .array([.string("!invalid!"), .string("base64")])),
            ("lamports", nil), ("lamports", .number("-1")), ("executable", .bool(true)), ("executable", nil)
        ]
        for v in c.vectors where v.kind == "cpi" {
            for (key, value) in mutations {
                var changed = fields; changed[key] = value
                try await rejected(c, v, before: a, after: .object(changed), marker: "Unreviewable stake snapshot accepted")
            }
        }
    }
}

private actor StakeReviewRPC: AnkrTransport {
    let owner: String, stake: String, before: SolanaJSON, after: SolanaJSON
    init(owner: String, stake: String, before: SolanaJSON, after: SolanaJSON) {
        self.owner=owner; self.stake=stake; self.before=before; self.after=after
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        XCTAssertEqual(request.url?.host, "api.devnet.solana.com")
        let j = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        let method = try XCTUnwrap(j["method"].string), p = j["params"].array ?? []
        func snapshot(_ address: String?, post: Bool) -> SolanaJSON {
            if address == owner { return .object(["owner": .string(SolanaSendCrypto.system), "lamports": .number(post ? "995000" : "1000000"), "data": .array([.string(""),.string("base64")]), "executable": .bool(false)]) }
            if address == stake { return post ? after : before }; return .null
        }
        func context(_ value: SolanaJSON) -> SolanaJSON { .object(["context": .object(["slot": .number("123")]), "value": value]) }
        let result: SolanaJSON
        switch method {
        case "getGenesisHash": result = .string(SolanaSendNetwork.devnet.genesis)
        case "isBlockhashValid": result = context(.bool(true))
        case "getMultipleAccounts": result = context(.array((p[0].array ?? []).map { snapshot($0.string, post: false) }))
        case "simulateTransaction": result = context(.object(["err": .null, "accounts": .array((p[1]["accounts"]["addresses"].array ?? []).map { snapshot($0.string, post: true) })]))
        case "getFeeForMessage": result = context(.number("5000"))
        default: XCTFail("Unexpected request \(method)"); throw SolanaSendError.malformed
        }
        return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": j["id"], "result": result])), 200)
    }
}
