import Foundation
import XCTest
@testable import OathAnkr

private let alchemyOwner = "0x1111111111111111111111111111111111111111"
private let alchemyPeer = "0x2222222222222222222222222222222222222222"
private let alchemyHash = "0x" + String(repeating: "a", count: 64)
private let alchemyBlock = "0x" + String(repeating: "b", count: 64)

private actor AlchemyReceiptTransport: AnkrTransport {
    enum Fault: Sendable { case none, wrongChain, wrongOwner, wrongAmount, wrongBlock, duplicateID, loop, crowded, rpcError }
    let network: AlchemyHistoryClient.Network
    let fault: Fault
    var requests: [URLRequest] = []
    init(_ network: AlchemyHistoryClient.Network, fault: Fault = .none) { self.network = network; self.fault = fault }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let calls = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody)).array!
        let rows = try calls.map { call -> SolanaJSON in
            let params = call["params"].array!, method = call["method"].string!
            let value: SolanaJSON
            switch method {
            case "eth_chainId": value = .string("0x" + String(fault == .wrongChain ? 1 : network.chainID, radix: 16))
            case "alchemy_getAssetTransfers":
                if fault == .rpcError { return .object(["jsonrpc": .string("2.0"), "id": call["id"], "error": .object(["code": .number("-32602"), "message": .string("invalid page key")])]) }
                let p = params[0], incoming = !p["toAddress"].isNull
                let isArc = network == .arc
                let transfer: SolanaJSON = .object(["hash": .string(alchemyHash), "blockNum": .string("0x64"),
                    "category": .string(isArc ? "internal" : "external"), "uniqueId": .string(alchemyHash + ":external"),
                    "from": .string(fault == .wrongOwner ? alchemyPeer : alchemyOwner), "to": .string(alchemyPeer),
                    "rawContract": .object(["value": .string(fault == .wrongAmount ? "0x2" : "0x1")]),
                    "metadata": .object(["blockTimestamp": .string("2026-10-12T00:00:00Z")])])
                var object: [String: SolanaJSON] = ["transfers": .array(incoming ? [] : [transfer])]
                if !incoming && (fault == .loop || (fault == .crowded && p["pageKey"].isNull)) { object["pageKey"] = .string("page-two") }
                value = .object(object)
            case "eth_getTransactionByHash":
                value = .object(["hash": .string(alchemyHash), "blockHash": .string(alchemyBlock), "blockNumber": .string("0x64"),
                    "from": .string(alchemyOwner), "to": .string(alchemyPeer), "value": .string("0x1")])
            case "eth_getBlockByNumber":
                value = .object(["number": .string("0x64"), "hash": .string(alchemyBlock), "timestamp": .string("0x6553f100")])
            case "eth_getTransactionReceipt":
                let topic: (String) -> SolanaJSON = { .string("0x" + String(repeating: "0", count: 24) + $0.dropFirst(2)) }
                let log: SolanaJSON = .object(["address": .string(ArcIdentity.systemEmitter), "topics": .array([.string(ArcIdentity.transferTopic), topic(alchemyOwner), topic(alchemyPeer)]),
                    "data": .string("0x" + String(repeating: "0", count: 63) + "1"), "logIndex": .string("0x0"),
                    "blockNumber": .string("0x64"), "transactionHash": .string(alchemyHash), "blockHash": .string(alchemyBlock), "removed": .bool(false)])
                value = .object(["transactionHash": .string(alchemyHash), "blockHash": .string(alchemyBlock), "blockNumber": .string(fault == .wrongBlock ? "0x65" : "0x64"),
                    "from": .string(alchemyOwner), "to": .string(alchemyPeer), "status": .string("0x1"), "gasUsed": .string("0x5208"),
                    "effectiveGasPrice": .string("0x1"), "logs": .array(network == .arc ? [log] : [])])
            case "alchemy_getTokenBalances": value = .object(["address": .string(alchemyOwner), "tokenBalances": .array([])])
            default: throw AnkrError.invalidResponse
            }
            return .object(["jsonrpc": .string("2.0"), "id": fault == .duplicateID ? .number("0") : call["id"], "result": value])
        }
        return (try JSONEncoder().encode(SolanaJSON.array(rows.reversed())), 200)
    }
}

final class AlchemyHistoryTests: XCTestCase, @unchecked Sendable {
    func testRobinhoodVerifiesNativeUnitsAndPreservesIncomingAfterOutgoingCutoff() async throws {
        let transport = AlchemyReceiptTransport(.robinhood)
        let client = try RobinhoodClient(apiKey: "fixture", alchemyAPIKey: "local_fixture", transport: transport)
        let page = try await client.history(owner: alchemyOwner, stream: .transactions, through: 2_000_000_000)
        XCTAssertEqual(page.events.first?.from, alchemyOwner); XCTAssertEqual(page.events.first?.to, alchemyPeer)
        XCTAssertEqual(page.events.first?.amount, "1"); XCTAssertEqual(page.events.first?.fee, "21000")
        XCTAssertNotNil(page.next)
        let incoming = try await client.history(owner: alchemyOwner, stream: .transactions, cursor: page.next, through: 2_000_000_000)
        XCTAssertNil(incoming.next)
        let cutoff = try await client.history(owner: alchemyOwner, stream: .transactions, from: 1_999_999_999, through: 2_000_000_000)
        XCTAssertTrue(cutoff.events.isEmpty)
        XCTAssertNotNil(cutoff.next, "Old outgoing transfers must not skip incoming history")
        let raw = try JSONDecoder().decode([String: [Data]].self, from: page.raw)
        XCTAssertFalse(raw.values.flatMap { $0 }.contains { String(decoding: $0, as: UTF8.self).contains("local_fixture") })
    }
    func testUnsupportedRobinhoodInternalHistoryNeverSendsARequest() async throws {
        let transport = AlchemyReceiptTransport(.robinhood)
        let client = try RobinhoodClient(apiKey: "fixture", alchemyAPIKey: "fixture", transport: transport)
        XCTAssertEqual(client.historyStreams, [.transactions, .transfers])
        do { _ = try await client.history(owner: alchemyOwner, stream: .internalTransactions); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError, .configurationMissing) }
        let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testRobinhoodRejectsWrongReceiptAmountAndBlock() async throws {
        for fault in [AlchemyReceiptTransport.Fault.wrongAmount, .wrongBlock] {
            let client = try RobinhoodClient(apiKey: "fixture", alchemyAPIKey: "fixture", transport: AlchemyReceiptTransport(.robinhood, fault: fault))
            do { _ = try await client.history(owner: alchemyOwner, stream: .transactions); XCTFail() }
            catch { XCTAssertEqual(error as? AnkrError, .invalidResponse) }
        }
    }
    func testIndexRejectsWrongChainOwnerIDsAndPaginationLoop() async throws {
        for (fault, expected) in [(AlchemyReceiptTransport.Fault.wrongChain, AnkrError.wrongChain), (.wrongOwner, .wrongAccount), (.duplicateID, .invalidResponse), (.loop, .paginationLoop)] {
            let index = try AlchemyHistoryClient(network: .robinhood, apiKey: "fixture", transport: AlchemyReceiptTransport(.robinhood, fault: fault))
            do { _ = try await index.transfers(owner: alchemyOwner, incoming: false, categories: ["external"], cursor: fault == .loop ? "page-two" : nil); XCTFail() }
            catch { XCTAssertEqual(error as? AnkrError, expected) }
        }
    }
    func testNegativeProviderCodeIsPreservedAndExpiredCursorCanRestart() async throws {
        let index = try AlchemyHistoryClient(network: .robinhood, apiKey: "fixture", transport: AlchemyReceiptTransport(.robinhood, fault: .rpcError))
        do { _ = try await index.transfers(owner: alchemyOwner, incoming: false, categories: ["external"]); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError, .rpc(-32602)) }
        do { _ = try await index.transfers(owner: alchemyOwner, incoming: false, categories: ["external"], cursor: "expired"); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError, .http(422)) }
    }
    func testProviderCursorCannotBeForwardedToAlchemy() async throws {
        let transport = AlchemyReceiptTransport(.robinhood)
        let client = try RobinhoodClient(apiKey: "fixture", alchemyAPIKey: "fixture", transport: transport)
        let oldCursor = try JSONEncoder().encode(SolanaJSON.object(["block_number": .number("100")])).base64EncodedString()
        do { _ = try await client.history(owner: alchemyOwner, stream: .transactions, cursor: oldCursor); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError, .http(422)) }
        let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testArcUsesReceiptLogsAndDoesNotDoubleCountRepeatedDiscovery() async throws {
        let client = try ArcClient(alchemyAPIKey: "fixture", transport: AlchemyReceiptTransport(.arc, fault: .crowded))
        let page = try await client.history(owner: alchemyOwner, from: 100, through: 102)
        XCTAssertEqual(page.nextBlock, 101, "Incomplete boundary blocks are retried and completely drained")
        XCTAssertEqual(page.transactions.count, 1); XCTAssertEqual(page.events.count, 1)
        XCTAssertEqual(page.events.first?.token.reference, "native")
        XCTAssertEqual(page.events.first?.amount, "1")
        XCTAssertEqual(page.events.first?.from, alchemyOwner); XCTAssertEqual(page.events.first?.to, alchemyPeer)
    }
    func testArcRejectsReceiptFromAnotherBlock() async throws {
        let client = try ArcClient(alchemyAPIKey: "fixture", transport: AlchemyReceiptTransport(.arc, fault: .wrongBlock))
        do { _ = try await client.history(owner: alchemyOwner, from: 100, through: 101); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError, .invalidResponse) }
    }
}
