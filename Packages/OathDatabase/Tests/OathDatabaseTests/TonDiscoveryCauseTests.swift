import XCTest
import Foundation
@testable import OathAnkr
@testable import OathDatabase

private struct TonDiscoveryCauseFeed: AnkrTransport {
    enum Failure: Sendable { case timeout, denied, malformed, cancelled, tokenTimeout, tokenDenied }
    let failure: Failure
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "api.coinbase.com" {
            return (Data(#"{"data":{"base":"TON","currency":"USD","amount":"2"}}"#.utf8), 200)
        }
        if request.url?.host == "tonapi.io" {
            if request.url!.path.hasSuffix("/jettons") {
                switch failure {
                case .timeout: return (Data(), 408)
                case .denied: return (Data(), 403)
                case .malformed: return (Data(#"{"balances":{}}"#.utf8), 200)
                case .cancelled: throw CancellationError()
                case .tokenTimeout, .tokenDenied:
                    let row: TonJSON = .object(["jetton": .object(["address": .string(TonIdentity.usdt), "name": .string("Tether"), "symbol": .string("USDT"), "decimals": .number("6"), "verification": .string("whitelist")]), "wallet_address": .object(["address": .string(TonIdentity.usdt)])])
                    return (try JSONEncoder().encode(TonJSON.object(["balances": .array([row])])), 200)
                }
            }
            return (Data(#"{"transactions":[],"operations":[]}"#.utf8), 200)
        }
        let call = try JSONDecoder().decode(TonJSON.self, from: XCTUnwrap(request.httpBody))
        let result: TonJSON
        switch call["method"].string {
        case "getMasterchainInfo": result = .object(["init": .object(["root_hash": .string(TonIdentity.genesis)])])
        case "getAddressInformation": result = .object(["state": .string("active"), "balance": .string("42")])
        case "runGetMethod", "getTokenData": return (Data(), failure == .tokenTimeout ? 408 : 403)
        default: throw TonError.malformed
        }
        return (try JSONEncoder().encode(TonJSON.object(["jsonrpc": .string("2.0"), "id": .string("1"), "result": result])), 200)
    }
}

extension TonLedgerTests {
    func testTokenFailureKeepsOriginalCauseAndPreservesCachedTokens() async throws {
        for (failure, expected) in [(TonDiscoveryCauseFeed.Failure.tokenTimeout, TonError.http(408)), (.tokenDenied, .http(403))] {
            let (db, folder) = try await fixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            let ticket = try await db.beginTonSync(accountID: "a1")
            try await db.commitTonInventory(inventory(), ticket: ticket)
            let feed = TonDiscoveryCauseFeed(failure: failure)
            let sync = TonSynchronizer(database: db, client: TonClient(testTransport: feed), markets: TonMarkets(transport: feed))
            do { try await sync.refresh(accountID: "a1"); XCTFail("Failed token reads must not become successful refreshes") }
            catch { XCTAssertEqual(error as? TonError, expected) }
            await sync.cancel()
            let native = try await db.balance(accountID: "a1", assetID: "ton:native")
            let token = try await db.balance(accountID: "a1", assetID: "ton:" + TonIdentity.usdt)
            XCTAssertEqual(native?.amountAtomic, "42")
            XCTAssertEqual(token?.amountAtomic, "879187990649145")
        }
    }
    func testDiscoveryFailureKeepsOriginalCauseAndPreservesCachedTokens() async throws {
        for (failure, expected) in [(TonDiscoveryCauseFeed.Failure.timeout, TonError.http(408)), (.denied, .http(403)), (.malformed, .malformed)] {
            let (db, folder) = try await fixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            let ticket = try await db.beginTonSync(accountID: "a1")
            try await db.commitTonInventory(inventory(), ticket: ticket)
            let feed = TonDiscoveryCauseFeed(failure: failure)
            let sync = TonSynchronizer(database: db, client: TonClient(testTransport: feed), markets: TonMarkets(transport: feed))
            do { try await sync.refresh(accountID: "a1"); XCTFail("Partial discovery must still fail the refresh") }
            catch { XCTAssertEqual(error as? TonError, expected) }
            await sync.cancel()
            let native = try await db.balance(accountID: "a1", assetID: "ton:native")
            let token = try await db.balance(accountID: "a1", assetID: "ton:" + TonIdentity.usdt)
            XCTAssertEqual(native?.amountAtomic, "42", "Valid native balance must survive an index outage")
            XCTAssertEqual(token?.amountAtomic, "879187990649145", "Undiscovered tokens must never become zero")
        }
    }
    func testDiscoveryCancellationNeverBecomesIncompleteOrCommitsPartialInventory() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginTonSync(accountID: "a1")
        try await db.commitTonInventory(inventory(), ticket: ticket)
        let feed = TonDiscoveryCauseFeed(failure: .cancelled)
        let sync = TonSynchronizer(database: db, client: TonClient(testTransport: feed), markets: TonMarkets(transport: feed))
        do { try await sync.refresh(accountID: "a1"); XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        await sync.cancel()
        let native = try await db.balance(accountID: "a1", assetID: "ton:native")
        XCTAssertEqual(native?.amountAtomic, "59570010157331145")
    }
}
