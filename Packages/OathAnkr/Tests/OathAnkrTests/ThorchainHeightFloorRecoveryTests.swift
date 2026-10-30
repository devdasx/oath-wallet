import Foundation
import XCTest
@testable import OathAnkr

private actor HeightFloorProvider: AnkrTransport {
    enum Mode { case available, absent, wrongChain, wrongHeight, cancelled }
    let mode: Mode
    private(set) var paths: [String] = []
    init(_ mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let path = request.url!.lastPathComponent
        paths.append(path)
        if path == "latest" { return (Data(#"{"block":{"header":{"chain_id":"thorchain-1","height":"199"}}}"#.utf8), 200) }
        XCTAssertEqual(path, "200")
        XCTAssertEqual(request.httpMethod, "GET")
        if mode == .cancelled { throw CancellationError() }
        if mode == .absent { return (Data(#"{"code":5,"message":"block unavailable"}"#.utf8), 404) }
        let chain = mode == .wrongChain ? "stagenet" : "thorchain-1"
        let height = mode == .wrongHeight ? "201" : "200"
        return (Data("{\"block\":{\"header\":{\"chain_id\":\"\(chain)\",\"height\":\"\(height)\"}}}".utf8), 200)
    }
}

final class ThorchainHeightFloorRecoveryTests: XCTestCase, @unchecked Sendable {
    func testLaggingLatestCannotBlockAnAvailablePinnedBlock() async throws {
        let provider = HeightFloorProvider(.available)
        let height = try await ThorchainClient(transport: provider).latestHeight(atLeast: 200)
        XCTAssertEqual(height, 200)
        let paths = await provider.paths
        XCTAssertEqual(paths, ["latest", "latest", "latest", "200"])
    }
    func testAbsentPinnedBlockStillFailsWithoutLoweringFloor() async throws {
        let provider = HeightFloorProvider(.absent)
        do { _ = try await ThorchainClient(transport: provider).latestHeight(atLeast: 200); XCTFail() }
        catch { XCTAssertEqual(error as? ThorchainError, .staleHeight) }
        let paths = await provider.paths
        XCTAssertEqual(paths, ["latest", "latest", "latest", "200"])
    }
    func testRecoveryRejectsWrongNetworkHeightAndCancellation() async throws {
        for mode in [HeightFloorProvider.Mode.wrongChain, .wrongHeight, .cancelled] {
            let provider = HeightFloorProvider(mode)
            do { _ = try await ThorchainClient(transport: provider).latestHeight(atLeast: 200); XCTFail() }
            catch {
                if mode == .cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ThorchainError, .malformed) }
            }
        }
    }
    func testLiveNamedBlockRecoveryWithPersistentlyLaggingLatest() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THORCHAIN_HEIGHT_LIVE"] == "1" else { throw XCTSkip("Opt-in public read, no wallet or transaction") }
        let baseline = try await ThorchainClient().latestHeight()
        let provider = NamedBlockLiveProvider(baseline: baseline)
        let recovered = try await ThorchainClient(transport: provider).latestHeight(atLeast: baseline)
        XCTAssertEqual(recovered, baseline)
        let named = await provider.namedReads
        XCTAssertEqual(named, 1)
    }
}
private actor NamedBlockLiveProvider: AnkrTransport {
    let baseline: Int64
    let live = AnkrHTTPTransport()
    private(set) var namedReads = 0
    init(baseline: Int64) { self.baseline = baseline }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.lastPathComponent == "latest" {
            return (Data("{\"block\":{\"header\":{\"chain_id\":\"thorchain-1\",\"height\":\"\(baseline-1)\"}}}".utf8), 200)
        }
        XCTAssertEqual(request.url?.lastPathComponent, String(baseline))
        namedReads += 1
        return try await live.send(request)
    }
}
