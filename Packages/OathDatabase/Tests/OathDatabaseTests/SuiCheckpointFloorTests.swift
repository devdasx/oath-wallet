import Foundation
import XCTest
@testable import OathAnkr
@testable import OathDatabase

private actor SuiCheckpointFloorFeed: AnkrTransport {
    let owner: String
    let head: Int64
    let mode: String
    private(set) var balanceCheckpoints: [UInt64] = []
    init(owner: String, head: Int64, mode: String = "") {
        self.owner = owner; self.head = head; self.mode = mode
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "api.coinbase.com" {
            return (Data(#"{"data":{"base":"SUI","currency":"USD","amount":"2"}}"#.utf8), 200)
        }
        if request.url?.host == "api.coingecko.com", request.url?.path == "/api/v3/coins/list" {
            return (Data(#"[{"id":"example","platforms":{"sui":"0xab::coin::COIN"}}]"#.utf8), 200)
        }
        guard let body = request.httpBody else { throw SuiError.malformed }
        let call = try JSONDecoder().decode(SuiJSON.self, from: body)
        let query = try XCTUnwrap(call["query"].string)
        var value: [String: SuiJSON] = ["chainIdentifier": .string(mode == "wrongChain" ? "wrong-chain" : SuiIdentity.mainnet)]
        if query.contains("balances(first") {
            let checkpoint = try XCTUnwrap(call["variables"]["checkpoint"].integer)
            balanceCheckpoints.append(checkpoint)
            if checkpoint > UInt64(head), mode == "unavailable" || (mode == "fallback" && request.url?.host == "rpc.ankr.com") {
                return (try JSONEncoder().encode(SuiJSON.object(["errors": .array([.object([
                    "message": .string("Checkpoint \(checkpoint) in the future")])])])), 200)
            }
            value["address"] = .object([
                "address": .string(mode == "wrongOwner" ? "0x9999" : owner),
                "balances": .object([
                    "nodes": .array([.object(["coinType": .object(["repr": .string(SuiIdentity.coin)]),
                                              "totalBalance": .string("42"), "coinBalance": .string("42"), "addressBalance": .string("0")])]),
                    "pageInfo": .object(["hasNextPage": .bool(false), "endCursor": .null])])])
        } else if query.contains("transactions") {
            value["transactions"] = .object(["edges": .array([]), "pageInfo": .object([
                "hasPreviousPage": .bool(false), "startCursor": .null])])
        } else if query.contains("checkpoint") {
            value["checkpoint"] = .object(["sequenceNumber": .number(String(head))])
        } else { throw SuiError.malformed }
        return (try JSONEncoder().encode(SuiJSON.object(["data": .object(value)])), 200)
    }
}

extension SuiLedgerTests {
    func testRefreshCannotGoBehindPersistedCheckpointWhenProviderHeadRegresses() async throws {
        for (head, mode): (Int64, String) in [(50, ""), (50, "fallback"), (150, "")] {
            let (db, folder) = try await fixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            let saved = try await db.beginSuiSync(accountID: "a1")
            try await db.commitSuiInventory(inventory(time: 100), ticket: saved, catalog: catalog)
            let feed = SuiCheckpointFloorFeed(owner: owner, head: head, mode: mode)
            let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
            let sync = SuiSynchronizer(database: reopened, client: try SuiClient(apiKey: "fixture", transport: feed), markets: SuiMarkets(transport: feed))
            do { try await sync.refresh(accountID: "a1") }
            catch { XCTFail("A lagging head must recover at the saved checkpoint: \(error)") }
            await sync.cancel()
            let result = try await db.suiInventory(accountID: "a1")
            XCTAssertEqual(result?.checkpoint, max(100, head))
            XCTAssertEqual(result?.holdings.first?.amount, "42")
            let requested = await feed.balanceCheckpoints
            XCTAssertEqual(requested, Array(repeating: UInt64(max(100, head)), count: mode == "fallback" ? 2 : 1))
        }
    }

    func testCheckpointFloorIsAccountScopedAndRejectsSupersededTickets() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try await db.beginSuiSync(accountID: "a1")
        let empty = try await db.suiInventoryCheckpoint(first)
        XCTAssertEqual(empty, 0)
        try await db.commitSuiInventory(inventory(time: 100), ticket: first, catalog: catalog)
        let replacement = try await db.beginSuiSync(accountID: "a1")
        do { _ = try await db.suiInventoryCheckpoint(first); XCTFail("Superseded ticket must remain rejected") }
        catch { XCTAssertEqual(error as? StoreError, .staleSync) }
        let current = try await db.suiInventoryCheckpoint(replacement)
        XCTAssertEqual(current, 100)
        let other = try await db.beginSuiSync(accountID: "a2")
        let otherCheckpoint = try await db.suiInventoryCheckpoint(other)
        XCTAssertEqual(otherCheckpoint, 0)
    }

    func testUnavailablePinnedCheckpointDoesNotFallBackToOlderBalances() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = try await db.beginSuiSync(accountID: "a1")
        try await db.commitSuiInventory(inventory(time: 100), ticket: saved, catalog: catalog)
        let feed = SuiCheckpointFloorFeed(owner: owner, head: 50, mode: "unavailable")
        let sync = SuiSynchronizer(database: db, client: try SuiClient(apiKey: "fixture", transport: feed), markets: SuiMarkets(transport: feed))
        do { try await sync.refresh(accountID: "a1"); XCTFail("Unavailable snapshot must remain a failure") }
        catch { XCTAssertEqual(error as? SuiError, .checkpointUnavailable) }
        await sync.cancel()
        let result = try await db.suiInventory(accountID: "a1")
        XCTAssertEqual(result?.checkpoint, 100)
        XCTAssertEqual(result?.holdings.first?.amount, "9007199254740993")
        let requested = await feed.balanceCheckpoints
        XCTAssertEqual(requested, [100, 100], "Both configured providers must use the same saved floor")
    }

    func testCheckpointFloorNeverRelaxesNetworkOrOwnerValidation() async throws {
        for mode in ["wrongOwner", "wrongChain"] {
            let (db, folder) = try await fixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            let saved = try await db.beginSuiSync(accountID: "a1")
            try await db.commitSuiInventory(inventory(time: 100), ticket: saved, catalog: catalog)
            let feed = SuiCheckpointFloorFeed(owner: owner, head: 150, mode: mode)
            let sync = SuiSynchronizer(database: db, client: try SuiClient(apiKey: "fixture", transport: feed), markets: SuiMarkets(transport: feed))
            do { try await sync.refresh(accountID: "a1"); XCTFail("Identity failure must remain rejected") }
            catch { XCTAssertEqual(error as? SuiError, mode == "wrongOwner" ? .wrongOwner : .wrongNetwork) }
            await sync.cancel()
            let result = try await db.suiInventory(accountID: "a1")
            XCTAssertEqual(result?.checkpoint, 100)
            XCTAssertEqual(result?.holdings.first?.amount, "9007199254740993")
        }
    }
}
