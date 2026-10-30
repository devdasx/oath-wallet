import Foundation
import XCTest
@testable import OathAnkr

private let pinnedOwner = "0x1111111111111111111111111111111111111111"
private let pinnedToken = "0x3333333333333333333333333333333333333333"
private let pinnedHash = "0x" + String(repeating:"a",count:64)

private actor IoTeXPinnedTransport: AnkrTransport {
    enum Mode: Sendable { case good, wrongChain, wrongBlock, wrongHeight, archiveReorg, primaryReorg, unavailable, cancelled, wrongDecimals }
    let mode: Mode
    var requests: [URLRequest] = []
    var archiveBlocks = 0, primaryBlocks = 0
    init(_ mode: Mode = .good) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if request.url?.host == "dev.iotexscan.io" { return (Data(#"{"status":"1","result":[]}"#.utf8),200) }
        let calls = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self,from:request.httpBody!).array)
        let archive = request.url?.host == "archive-mainnet.iotex.io"
        if archive && mode == .cancelled { throw CancellationError() }
        let replies = calls.map { call -> SolanaJSON in
            let method = call["method"].string!, params = call["params"].array!
            var result: SolanaJSON = .null
            switch method {
            case "eth_chainId": result = .string(archive && mode == .wrongChain ? "0x1":"0x1251")
            case "eth_getBlockByNumber":
                if archive { archiveBlocks += 1 } else { primaryBlocks += 1 }
                let changed = archive && (mode == .wrongBlock || (mode == .archiveReorg && archiveBlocks > 1))
                    || !archive && mode == .primaryReorg && primaryBlocks > 1
                result = .object(["number":.string(archive && mode == .wrongHeight ? "0x65":"0x64"),
                    "hash":.string(changed ? "0x"+String(repeating:"b",count:64):pinnedHash)])
            case "eth_getBalance", "eth_call":
                XCTAssertEqual(params.last?.string,"0x64", "Every balance/decimals read must stay pinned")
                if !archive || mode == .unavailable {
                    return .object(["jsonrpc":.string("2.0"),"id":call["id"],"error":.object([
                        "code":.number("13"),"message":.string("historical state at height 100 is not available on a non-archive node (current tip 101); use an archive node: not supported")])])
                }
                if method == "eth_getBalance" { result = .string("0x20000000000001") }
                else if params[0]["data"].string == "0x313ce567" { result = .string(mode == .wrongDecimals ? "0x12":"0x6") }
                else { result = .string("0x2a") }
            default: XCTFail("Unexpected RPC method")
            }
            return .object(["jsonrpc":.string("2.0"),"id":call["id"],"result":result])
        }
        return (try JSONEncoder().encode(SolanaJSON.array(replies.reversed())),200)
    }
}

final class IoTeXPinnedInventoryTests: XCTestCase, @unchecked Sendable {
    private func inventory(_ transport: IoTeXPinnedTransport) async throws -> IndexedEVMInventory {
        let token = try IndexedEVMToken(reference:pinnedToken,name:"Fixture",symbol:"FIX",decimals:6)
        return try await IndexedEVMClient(chain:.iotex,apiKey:"fixture",transport:transport).inventory(owner:pinnedOwner,tracked:[token])
    }
    func testAdvancingNonArchiveTipStillReturnsOneExactVerifiedSnapshot() async throws {
        let transport = IoTeXPinnedTransport()
        let value = try await inventory(transport)
        XCTAssertEqual(value.block,100); XCTAssertEqual(value.blockHash,pinnedHash)
        XCTAssertEqual(value.holdings.first{$0.token.reference=="native"}?.amount,"9007199254740993")
        XCTAssertEqual(value.holdings.first{$0.token.reference==pinnedToken}?.amount,"42")
        XCTAssertTrue(value.complete)
        let requests = await transport.requests
        XCTAssertTrue(requests.contains{$0.url?.host=="rpc.ankr.com"})
        for request in requests where request.httpBody != nil {
            let calls = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self,from:request.httpBody!).array)
            if calls.contains(where:{["eth_call","eth_getBalance"].contains($0["method"].string ?? "")}) {
                XCTAssertEqual(request.url?.host,"archive-mainnet.iotex.io")
                XCTAssertEqual(request.url?.path, "")
            }
        }
    }
    func testWrongNetworkHeightHashReorgAndUnavailableStateNeverBecomeBalances() async throws {
        for mode in [IoTeXPinnedTransport.Mode.wrongChain,.wrongHeight,.wrongBlock,.archiveReorg,.primaryReorg,.unavailable] {
            do { _ = try await inventory(IoTeXPinnedTransport(mode)); XCTFail("Unverified snapshot accepted: \(mode)") }
            catch { XCTAssertTrue(error is AnkrError) }
        }
    }
    func testCancellationStopsAndConflictingDecimalsRemainUnavailable() async throws {
        do { _ = try await inventory(IoTeXPinnedTransport(.cancelled)); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        let value = try await inventory(IoTeXPinnedTransport(.wrongDecimals))
        XCTAssertFalse(value.complete)
        XCTAssertNil(value.holdings.first{$0.token.reference==pinnedToken}?.amount)
        XCTAssertEqual(value.holdings.first{$0.token.reference=="native"}?.amount,"9007199254740993")
    }
}
