import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private let readOwner = String(repeating: "1", count: 32)
private let readSignature = String(repeating: "1", count: 64)

private enum ReadAction: CaseIterable {
    case inventory, signatures, transactions
    var method: String {
        switch self {
        case .inventory: "getBalance"
        case .signatures: "getSignaturesForAddress"
        case .transactions: "getTransaction"
        }
    }
    var primary: Bool { self != .signatures }
    func run(_ client: SolanaClient) async throws {
        switch self {
        case .inventory:
            let value = try await client.inventory(owner: readOwner)
            XCTAssertEqual(value.lamports, "10000"); XCTAssertTrue(value.accounts.isEmpty)
        case .signatures:
            let value = try await client.signatures(address: readOwner)
            XCTAssertTrue(value.signatures.isEmpty)
        case .transactions:
            let value = try await client.transactions(signatures: [readSignature], owner: readOwner)
            XCTAssertEqual(value.count, 1)
        }
    }
}

private actor InterruptedSolanaRead: AnkrTransport {
    enum Mode { case cancelled, timeout, held }
    struct Request: Sendable { let primary: Bool; let method: String }
    let method: String
    let primary: Bool
    let mode: Mode
    var remaining: Int
    var released = false
    var pending: CheckedContinuation<Void, Never>?
    var requests: [Request] = []
    init(method: String, primary: Bool = true, mode: Mode, remaining: Int = 1) {
        self.method = method; self.primary = primary; self.mode = mode; self.remaining = remaining
    }
    func release() { released = true; pending?.resume(); pending = nil }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let root = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
        let rows = root.array ?? [root]
        let isPrimary = request.url!.host == "rpc.ankr.com"
        let name = rows[0]["method"].string!
        requests.append(.init(primary: isPrimary, method: name))
        if name == method, primary == isPrimary, remaining > 0 {
            remaining -= 1
            switch mode {
            case .cancelled: throw URLError(.cancelled)
            case .timeout: throw URLError(.timedOut)
            case .held: if !released { await withCheckedContinuation { pending = $0 } }
            }
        }
        let replies = rows.map { row -> SolanaJSON in
            let result: SolanaJSON
            switch row["method"].string! {
            case "getGenesisHash": result = .string(SolanaIdentity.genesis)
            case "getBalance": result = .object(["context": .object(["slot": .number("123")]), "value": .number("10000")])
            case "getTokenAccountsByOwner": result = .object(["context": .object(["slot": .number("123")]), "value": .array([])])
            case "getSignaturesForAddress": result = .array([])
            default:
                result = .object([
                    "slot": .number("123"),
                    "transaction": .object(["signatures": .array([.string(readSignature)]),
                        "message": .object(["accountKeys": .array([.string(readOwner)])])]),
                    "meta": .object(["err": .null, "fee": .number("5000"),
                        "preBalances": .array([.number("10000")]), "postBalances": .array([.number("5000")])])])
            }
            return .object(["jsonrpc": .string("2.0"), "id": row["id"], "result": result])
        }
        return (try JSONEncoder().encode(root.array == nil ? replies[0] : .array(replies)), 200)
    }
}

@MainActor final class SolanaReadCancellationTests: XCTestCase {
    func testIndependentURLCancellationStopsInventoryAndBothHistoryPaths() async throws {
        for action in ReadAction.allCases {
            let feed = InterruptedSolanaRead(method: action.method, primary: action.primary, mode: .cancelled)
            let client = try SolanaClient(apiKey: "fixture", transport: feed)
            do { try await action.run(client); XCTFail("Cancellation became success or started another provider") }
            catch { XCTAssertTrue(error is CancellationError) }
            let requests = await feed.requests
            XCTAssertEqual(requests.count, 2, "Only genesis verification and the cancelled read")
            XCTAssertTrue(requests.allSatisfy { $0.primary == action.primary })
            XCTAssertFalse(Task.isCancelled, "URL cancellation is independent of caller task cancellation")
        }
    }

    func testRepeatedCancelledReadsReleasePermitsAndAllowHealthyRetry() async throws {
        let feed = InterruptedSolanaRead(method: "getBalance", mode: .cancelled, remaining: 4)
        let client = try SolanaClient(apiKey: "fixture", transport: feed)
        for _ in 0..<4 {
            do { try await ReadAction.inventory.run(client); XCTFail("Cancelled inventory was accepted") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        try await ReadAction.inventory.run(client)
        let requests = await feed.requests
        XCTAssertEqual(requests.count, 6)
        XCTAssertTrue(requests.allSatisfy(\.primary))
    }

    func testLateSuccessCannotPublishAfterCancellation() async throws {
        for action in ReadAction.allCases {
            let feed = InterruptedSolanaRead(method: action.method, primary: action.primary, mode: .held)
            let client = try SolanaClient(apiKey: "fixture", transport: feed)
            let work = Task { try await action.run(client) }
            for _ in 0..<400 {
                if await feed.pending != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let held = await feed.pending != nil
            XCTAssertTrue(held)
            work.cancel(); await feed.release()
            do { try await work.value; XCTFail("Late response escaped a cancelled task") }
            catch { XCTAssertTrue(error is CancellationError) }
            let requests = await feed.requests
            XCTAssertEqual(requests.count, 2)
            try await action.run(client)
        }
    }

    func testCancelledGenesisResponseIsNotCachedAsVerified() async throws {
        let feed = InterruptedSolanaRead(method: "getGenesisHash", mode: .held)
        let client = try SolanaClient(apiKey: "fixture", transport: feed)
        let work = Task { try await ReadAction.inventory.run(client) }
        for _ in 0..<200 {
            if await feed.pending != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let held = await feed.pending != nil
        XCTAssertTrue(held)
        work.cancel(); await feed.release()
        do { try await work.value; XCTFail("Cancelled verification was accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await ReadAction.inventory.run(client)
        let requests = await feed.requests
        XCTAssertEqual(requests.filter { $0.method == "getGenesisHash" }.count, 2)
        XCTAssertTrue(requests.allSatisfy(\.primary))
    }

    func testRealTimeoutStillUsesIndependentProvider() async throws {
        let feed = InterruptedSolanaRead(method: "getBalance", mode: .timeout)
        let client = try SolanaClient(apiKey: "fixture", transport: feed)
        try await ReadAction.inventory.run(client)
        let requests = await feed.requests
        XCTAssertEqual(requests.filter(\.primary).count, 2)
        XCTAssertEqual(requests.filter { !$0.primary }.map(\.method),
                       ["getGenesisHash", "getBalance", "getTokenAccountsByOwner", "getTokenAccountsByOwner"])
    }
}

private actor SolanaReadReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class SolanaReadCancellationDiagnosticsTests: XCTestCase, @unchecked Sendable {
    // The shared outbox configures once. Run this class in its own process.
    func testCancellationQuietAndActualOutageKeepsCanonicalChainAndCorrelation() async throws {
        let reports = SolanaReadReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let cancelled = try SolanaClient(apiKey: "fixture", transport: InterruptedSolanaRead(method: "getBalance", mode: .cancelled))
        do { _ = try await cancelled.inventory(owner: readOwner); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(for: .milliseconds(50)); await OathDiagnostics.flush()
        let afterCancellation = await reports.events
        XCTAssertTrue(afterCancellation.isEmpty)

        let identifier = UUID()
        let outage = try SolanaClient(apiKey: "fixture", transport: InterruptedSolanaRead(method: "getBalance", mode: .timeout))
        try await OathDiagnostics.$operationID.withValue(identifier) {
            try await OathDiagnostics.$chain.withValue("ethereum") {
                _ = try await outage.inventory(owner: readOwner)
                XCTAssertEqual(OathDiagnostics.chain, "ethereum")
            }
        }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await reports.events.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.contains { $0.error.domain == NSURLErrorDomain && $0.error.code == -1001 })
        XCTAssertTrue(events.allSatisfy { $0.operationID == identifier && $0.context["chain"] == "solana" && $0.privacyFiltered })
        let payload = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(payload.contains(readOwner)); XCTAssertFalse(payload.contains("https://"))
        XCTAssertFalse(payload.contains("getTokenAccountsByOwner"))
        XCTAssertNil(OathDiagnostics.chain); XCTAssertNil(OathDiagnostics.operationID)
    }
}
