import Foundation
import XCTest
@testable import OathAnkr

final class SolanaTransactionVersionTests: XCTestCase, @unchecked Sendable {
    func testMixedHistoryVersionsOnPrimary() async throws {
        try await readMixedHistory(useArchive: false)
    }

    func testMixedHistoryVersionsOnArchiveFallback() async throws {
        try await readMixedHistory(useArchive: true)
    }

    private func readMixedHistory(useArchive: Bool) async throws {
        let fixture = SolanaTests()
        let versions: [SolanaJSON] = [.string("legacy"), .number("0"), .number("1")]
        let signatures = (0..<3).map { String(repeating: "1", count: 63) + String($0 + 1) }
        let transactions = try zip(versions, signatures).map { version, signature in
            try transaction(version: version, signature: signature)
        }
        let transport = SolanaFixtureTransport { request in
            let root = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
            let calls = root.array ?? [root]
            let replies = try calls.map { call -> SolanaJSON in
                var reply: [String: SolanaJSON] = ["jsonrpc": .string("2.0"), "id": call["id"]]
                if call["method"].string == "getGenesisHash" {
                    reply["result"] = .string(SolanaIdentity.genesis)
                } else {
                    XCTAssertEqual(call["method"].string, "getTransaction")
                    let params = try XCTUnwrap(call["params"].array)
                    XCTAssertEqual(params[1]["encoding"].string, "jsonParsed")
                    XCTAssertEqual(params[1]["commitment"].string, "finalized")
                    // Reproduce the real RPC rejection, including the fallback provider.
                    if params[1]["maxSupportedTransactionVersion"] != .number("1") {
                        reply["error"] = .object(["code": .number("-32015"), "message": .string("Unsupported transaction version")])
                    } else if useArchive && request.url?.host == "rpc.ankr.com" {
                        reply["result"] = .null
                    } else {
                        let index = try XCTUnwrap(signatures.firstIndex(of: try XCTUnwrap(params[0].string)))
                        reply["result"] = transactions[index]
                    }
                }
                return .object(reply)
            }
            // Batch order is deliberately reversed; identity must come from the reply ID.
            return root.array == nil ? replies[0] : .array(replies.reversed())
        }
        let client = try SolanaClient(apiKey: "fixture", transport: transport)
        let result = try await client.transactions(signatures: signatures, owner: fixture.owner)
        XCTAssertEqual(result.map(\.signature), signatures)
        for (index, tx) in result.enumerated() {
            XCTAssertEqual(tx.fee, "5000")
            XCTAssertEqual(tx.changes.first { $0.mint == "native" }?.amount, "20000000")
            XCTAssertEqual(tx.changes.first { $0.mint == fixture.mint }?.amount, "100000")
            XCTAssertEqual(try JSONDecoder().decode(SolanaJSON.self, from: tx.raw), transactions[index])
        }
    }

    func testFailedV1RetainsFeeWithoutInventingTransfers() throws {
        let fixture = SolanaTests()
        let tx = try transaction(version: .number("1"), signature: fixture.signature, failed: true)
        let result = try SolanaDecoding.transaction(tx, signature: fixture.signature, owner: fixture.owner)
        XCTAssertTrue(result.failed)
        XCTAssertEqual(result.fee, "5000")
        XCTAssertTrue(result.changes.allSatisfy { $0.amount == "0" && $0.direction == "self" })
    }

    func testPublicV1FixtureUsesActualFeeAndPreservesConfiguration() throws {
        let value = try publicV1()
        let signature = try XCTUnwrap(value["transaction"]["signatures"].array?.first?.string)
        let owner = try XCTUnwrap(value["transaction"]["message"]["accountKeys"].array?.first?["pubkey"].string)
        let tx = try SolanaDecoding.transaction(value, signature: signature, owner: owner)
        XCTAssertEqual(value["version"], .number("1"))
        XCTAssertEqual(tx.fee, "5001") // Actual fee includes base fee and the v1 priority fee of 1.
        XCTAssertFalse(tx.failed)
        XCTAssertEqual(tx.changes.first { $0.mint == "native" }?.amount, "0")
        XCTAssertEqual(tx.changes.first { $0.mint == "native" }?.direction, "self")
        XCTAssertEqual(try JSONDecoder().decode(SolanaJSON.self, from: tx.raw), value)
    }

    /// Public finalized mainnet data, read only. No wallet import, key, signing or broadcast.
    func testLivePublicV1ThroughProductionReader() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_SOLANA_KEY"], !key.isEmpty else {
            throw XCTSkip("Opt-in public Solana v1 read")
        }
        let value = try publicV1()
        let signature = try XCTUnwrap(value["transaction"]["signatures"].array?.first?.string)
        let owner = try XCTUnwrap(value["transaction"]["message"]["accountKeys"].array?.first?["pubkey"].string)
        let client = try SolanaClient(apiKey: key)
        let results = try await client.transactions(signatures: [signature], owner: owner)
        let tx = try XCTUnwrap(results.first)
        let actual = try JSONDecoder().decode(SolanaJSON.self, from: tx.raw)
        XCTAssertEqual(actual["version"], .number("1"))
        XCTAssertEqual(actual["transaction"], value["transaction"])
        XCTAssertEqual(actual["meta"], value["meta"])
        XCTAssertEqual(tx.slot, value["slot"].integer)
        XCTAssertEqual(tx.fee, "5001")
    }

    private func publicV1() throws -> SolanaJSON {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "public-v1", withExtension: "json", subdirectory: "Fixtures/SolanaHistory"))
        return try JSONDecoder().decode(SolanaJSON.self, from: Data(contentsOf: url))
    }

    private func transaction(version: SolanaJSON, signature: String, failed: Bool = false) throws -> SolanaJSON {
        guard case .object(var value) = try SolanaTests().tx(failed: failed),
              case .object(var tx) = value["transaction"], case .object(var message) = tx["message"] else {
            throw SolanaError.malformed
        }
        value["version"] = version
        tx["signatures"] = .array([.string(signature)])
        if version == .number("1") {
            message["transactionConfig"] = .object([
                "computeUnitLimit": .number("30000"), "heapSize": .null,
                "loadedAccountsDataSizeLimit": .number("200000"), "priorityFee": .number("1")
            ])
        }
        tx["message"] = .object(message)
        value["transaction"] = .object(tx)
        return .object(value)
    }
}
