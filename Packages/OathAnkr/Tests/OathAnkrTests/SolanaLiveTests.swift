import Foundation
import XCTest
@testable import OathAnkr

/// Explicit opt-in. Only public explorer accounts; never imports or signs a key.
final class SolanaLiveTests: XCTestCase, @unchecked Sendable {
    let addresses = ["H31vEBxSJk1nQdUN11qZgZyhScyShhscKhvhZZU3dQoU", "3yFwqXBfZY4jBVUafQ1YEXw189y2dN3V5KQq9uzBDy1E", "CutAG7TzyTq6BNECcvLjm2FCxL19pPPQDqV2em91Qeom"]
    func client() throws -> SolanaClient {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_SOLANA_KEY"], !key.isEmpty else { throw XCTSkip("Opt-in public Solana API test") }
        return try .init(apiKey:key)
    }
    func testLiveInventoriesMarketsAndIndependentBalances() async throws {
        let client = try client(), market = SolanaMarkets()
        let catalog = try SolanaMarkets.decodeCatalog(await market.catalog())
        let native = try await market.nativePrice()
        XCTAssertTrue((Decimal(string:native.usd) ?? 0) > 0)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("oath-solana-live-swift")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var total = 0, total2022 = 0, quotes = 0
        for address in addresses {
            let inventory = try await matchingInventory(client: client, owner: address)
            XCTAssertTrue((UInt64(inventory.lamports) ?? 0) > 0)
            XCTAssertFalse(inventory.accounts.isEmpty)
            total += inventory.accounts.count; total2022 += inventory.accounts.filter { $0.program == SolanaIdentity.token2022Program }.count
            let mints = Set(inventory.accounts.filter { $0.amount != "0" && catalog[$0.mint] != nil }.map(\.mint)).sorted()
            var prices: [SolanaPrice] = []
            for start in stride(from:0,to:mints.count,by:30) {
                prices += try await market.prices(mints:Array(mints[start..<min(start+30,mints.count)]))
            }
            quotes += prices.count
            XCTAssertGreaterThan(prices.count,0)
            XCTAssertEqual(Set(prices.map(\.mint)), Set(mints), "These public fixtures have quoted markets for every listed nonzero mint")
            XCTAssertTrue(prices.allSatisfy { mints.contains($0.mint) && (Decimal(string:$0.usd) ?? 0) > 0 })
            try JSONEncoder().encode(inventory).write(to:output.appendingPathComponent(address+"-inventory.json"))
            try JSONEncoder().encode(prices).write(to:output.appendingPathComponent(address+"-prices.json"))
            print("SOLANA_LIVE inventory accounts=\(inventory.accounts.count) token2022=\(inventory.accounts.filter { $0.program == SolanaIdentity.token2022Program }.count) listed=\(mints.count) priced=\(prices.count) nativeAndAllTokensMatchOfficial=true")
        }
        XCTAssertGreaterThan(total,100); XCTAssertGreaterThan(total2022,1); XCTAssertGreaterThan(quotes,6)
    }

    private func matchingInventory(client: SolanaClient, owner: String) async throws -> SolanaInventory {
        // Two RPC providers do not expose an atomic cross-provider snapshot.
        // A live wallet can receive tokens between reads. Retry the whole comparison
        // at most twice; every field must still match, or this test fails.
        for attempt in 0..<3 {
            let inventory = try await client.inventory(owner: owner)
            var values = [try await official("getBalance", params: [
                .string(owner), .object(["commitment": .string("confirmed")])])]
            for program in [SolanaIdentity.tokenProgram, SolanaIdentity.token2022Program] {
                values.append(try await official("getTokenAccountsByOwner", params: [
                    .string(owner), .object(["programId": .string(program)]),
                    .object(["commitment": .string("confirmed"), "encoding": .string("jsonParsed")])]))
            }
            let independent = try SolanaDecoding.inventory(owner: owner, values: values)
            if independent.lamports == inventory.lamports,
               independent.accounts.sorted(by: { $0.address < $1.address }) == inventory.accounts.sorted(by: { $0.address < $1.address }) {
                return inventory
            }
            print("SOLANA_LIVE snapshotChanged attempt=\(attempt + 1) ankrAccounts=\(inventory.accounts.count) officialAccounts=\(independent.accounts.count)")
        }
        XCTFail("Independent SOL and every token account/amount/precision/frozen flag failed to match in three bounded snapshots")
        throw SolanaError.staleSlot
    }

    func testLiveTokenAccountHistoryAcrossThreeWallets() async throws {
        let client = try client()
        let fixtures = [
            (addresses[0], "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"),
            (addresses[1], "kinXdEcpDQeHPEuQnqmUgtYykqKGVFq6CeVX5iAHJq6"),
            (addresses[2], "CQbXk942c6GPcRwtZ2WMFP5JcQ9NqbXtb8jUewBi7GoT")
        ]
        var depositsWithoutOwnerKey = 0, tokenChanges = 0
        for (owner, mint) in fixtures {
            let inventory = try await client.inventory(owner: owner)
            let account = try XCTUnwrap(inventory.accounts.first { $0.mint == mint && $0.amount != "0" })
            let page = try await client.signatures(address: account.address, limit: 3)
            XCTAssertTrue(page.archival)
            XCTAssertFalse(page.signatures.isEmpty)
            let transactions = try await client.transactions(signatures: page.signatures.map(\.signature), owner: owner)
            for transaction in transactions {
                let raw = try JSONDecoder().decode(SolanaJSON.self, from: transaction.raw)
                let hasOwnerKey = raw["transaction"]["message"]["accountKeys"].array?.contains { $0["pubkey"].string == owner } == true
                if transaction.changes.contains(where: { $0.mint == mint }) {
                    tokenChanges += 1
                    if !hasOwnerKey { depositsWithoutOwnerKey += 1 }
                }
            }
        }
        XCTAssertGreaterThan(tokenChanges, 0)
        // Whether a current transaction includes the owner varies. The
        // owner-omitted deposit case is pinned separately by a deterministic test.
        print("SOLANA_LIVE tokenHistory changes=\(tokenChanges) depositsWithoutOwnerKey=\(depositsWithoutOwnerKey)")
    }
    func testLiveOldHistoryArchiveAndTransactionBatches() async throws {
        let client = try client()
        let owner = addresses[2]
        let page = try await client.signatures(address:owner,limit:5)
        XCTAssertTrue(page.archival); XCTAssertEqual(page.signatures.count,5)
        let next = try await client.signatures(address:owner,before:page.signatures.last!.signature,limit:5)
        XCTAssertTrue(next.archival)
        XCTAssertTrue(Set(page.signatures.map(\.signature)).isDisjoint(with:Set(next.signatures.map(\.signature))))
        let tx = try await client.transactions(signatures:page.signatures.map(\.signature),owner:owner)
        XCTAssertEqual(tx.count,5)
        XCTAssertTrue(tx.contains { !$0.changes.isEmpty })
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("oath-solana-live-swift")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        try JSONEncoder().encode(tx).write(to:output.appendingPathComponent("archive-transactions.json"))
        print("SOLANA_LIVE archive transactions=\(tx.count) assetChanges=\(tx.flatMap(\.changes).count) paginationDistinct=true")
    }
    private func official(_ method: String, params: [SolanaJSON]) async throws -> SolanaJSON {
        try await Task.sleep(for: .milliseconds(1300))
        let transport = AnkrHTTPTransport()
        for attempt in 0..<4 {
            var request = URLRequest(url:URL(string:"https://api.mainnet-beta.solana.com")!)
            request.httpMethod="POST";request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.httpBody=try JSONEncoder().encode(SolanaJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string(method),"params":.array(params)]))
            let (data,status)=try await transport.send(request)
            if status == 429 && attempt < 3 { try await Task.sleep(for:.seconds(5)); continue }
            guard status == 200 else { throw SolanaError.http(status) }
            let value=try JSONDecoder().decode(SolanaJSON.self,from:data)
            guard value["error"].isNull else { throw SolanaError.malformed }
            return value["result"]
        }
        throw SolanaError.transport
    }
}
