import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

private actor CronosBalanceFixture: AnkrTransport {
    var failToken = false, reorg = false, pause = false, entered = false
    var nativeReads = 0
    func configure(failToken: Bool = false, reorg: Bool = false, pause: Bool = false) {
        self.failToken = failToken; self.reorg = reorg; self.pause = pause; entered = false
    }
    func release() { pause = false }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let input = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
        var rows: [SolanaJSON] = []
        for call in input.array ?? [input] {
            let method = call["method"].string!, params = call["params"].array ?? []
            var result: SolanaJSON = .null
            switch method {
            case "eth_chainId": result = .string("0x19")
            case "eth_getBlockByNumber":
                result = .object(["number": .string("0x64"), "timestamp": .string("0x" + String(UInt64(Date.now.timeIntervalSince1970), radix: 16)), "hash": .string("0x" + String(repeating: reorg && params[0].string != "latest" ? "b" : "a", count: 64))])
            case "eth_getBalance":
                nativeReads += 1; entered = true
                while pause { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertEqual(params.last?.string, "0x64"); result = .string("0x64")
            case "eth_call":
                XCTAssertEqual(params.last?.string, "0x64")
                result = .string(params[0]["data"].string == "0x313ce567" ? (failToken ? "0x12" : "0x6") : "0x2a")
            default: throw EVMSendError.malformed
            }
            rows.append(.object(["jsonrpc": .string("2.0"), "id": call["id"], "result": result]))
        }
        return (try JSONEncoder().encode(input.array == nil ? rows[0] : .array(rows)), 200)
    }
}

@MainActor final class CronosBalanceTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL, CronosBalanceFixture, CronosBalanceSynchronizer, String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        try await db.seed(networks: [.init(id: "cronos", name: "Cronos", family: "evm", symbol: "CRO", decimals: 18, derivationPath: "fixture", logo: "cronos", sortOrder: 0)], assets: [.init(id: "cronos:native", networkID: "cronos", reference: "native", name: "Cronos", symbol: "CRO", decimals: 18)])
        try await db.importWalletIfNeeded(.init(id: "wallet", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1), accounts: [.init(id: "account", walletID: "wallet", networkID: "cronos", address: "0x" + String(repeating: "1", count: 40), derivationPath: "fixture")])
        let ref = "0x" + String(repeating: "3", count: 40)
        let token = try await db.trackAsset(.init(id: "cronos:" + ref, networkID: "cronos", reference: ref, name: "Fixture", symbol: "TEST", decimals: 6), walletID: "wallet")
        let transport = CronosBalanceFixture()
        let client = try EVMSendClient(network: .cronos, endpoints: [URL(string: "https://fixture.example")!], transport: transport)
        return (db, folder, transport, try CronosBalanceSynchronizer(database: db, client: client), token.id)
    }
    func testPinnedNativeAndTrackedTokensPreserveFailedTokenObservation() async throws {
        let (db, folder, transport, sync, token) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await sync.refresh(walletID: "wallet")
        let native = try await db.balance(accountID: "account", assetID: "cronos:native")
        let first = try await db.balance(accountID: "account", assetID: token)
        XCTAssertEqual(native?.amountAtomic, "100"); XCTAssertEqual(first?.amountAtomic, "42")
        await transport.configure(failToken: true)
        try await sync.refresh(walletID: "wallet")
        let preserved = try await db.balance(accountID: "account", assetID: token)
        XCTAssertEqual(preserved?.observedAt, first?.observedAt); XCTAssertEqual(preserved?.amountAtomic, "42")
    }
    func testSlowPinnedRefreshCannotOverwriteNewerPostSendBalance() async throws {
        let (db, folder, transport, sync, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        await transport.configure(pause: true)
        let task = Task { try await sync.refresh(walletID: "wallet") }
        for _ in 0..<200 {
            if await transport.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard await transport.entered else { try await task.value; return XCTFail("Fixture read did not start") }
        try await db.saveBalances([.init(accountID: "account", assetID: "cronos:native", networkID: "cronos", amountAtomic: "5", observedAt: Date.now.timeIntervalSince1970, blockHeight: 101, source: "rpc")])
        await transport.release()
        try await task.value
        let balance = try await db.balance(accountID: "account", assetID: "cronos:native")
        XCTAssertEqual(balance?.amountAtomic, "5"); XCTAssertEqual(balance?.blockHeight, 101)
    }
    func testReorgRejectsWholeSnapshot() async throws {
        let (db, folder, transport, sync, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        await transport.configure(reorg: true)
        do { try await sync.refresh(walletID: "wallet"); XCTFail("Reorg must reject") }
        catch { XCTAssertEqual(error as? EVMSendError, .changed) }
        let balance = try await db.balance(accountID: "account", assetID: "cronos:native")
        XCTAssertNil(balance)
    }
    func testConcurrentRefreshCoalescesAndStaleGenerationCannotWrite() async throws {
        let (db, folder, transport, sync, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        await transport.configure(pause: true)
        let first = Task { try await sync.refresh(walletID: "wallet") }
        for _ in 0..<200 {
            if await transport.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard await transport.entered else { try await first.value; return XCTFail("Fixture read did not start") }
        let follower = Task { try await sync.refresh(walletID: "wallet") }
        try await Task.sleep(for: .milliseconds(20))
        try await db.invalidate(networkID: "cronos", fromBlock: 0)
        await transport.release()
        for task in [first, follower] {
            do { try await task.value; XCTFail("Stale generation must reject") }
            catch { XCTAssertEqual(error as? StoreError, .staleSync) }
        }
        let reads = await transport.nativeReads
        let balance = try await db.balance(accountID: "account", assetID: "cronos:native")
        XCTAssertEqual(reads, 1); XCTAssertNil(balance)
    }
    func testCancellationNeverWritesPartialBalances() async throws {
        let (db, folder, transport, sync, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        await transport.configure(pause: true)
        let task = Task { try await sync.refresh(walletID: "wallet") }
        for _ in 0..<200 {
            if await transport.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard await transport.entered else { try await task.value; return XCTFail("Fixture read did not start") }
        await sync.cancel()
        do { try await task.value; XCTFail("Cancelled refresh must reject") } catch { XCTAssertTrue(error is CancellationError) }
        let balance = try await db.balance(accountID: "account", assetID: "cronos:native")
        XCTAssertNil(balance)
    }
}
