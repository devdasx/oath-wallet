import XCTest
import OathDiagnostics
@testable import OathAnkr

private let monOwner = "0x1111111111111111111111111111111111111111"
private let monOther = "0x2222222222222222222222222222222222222222"
private let monToken = "0x3333333333333333333333333333333333333333"
private let monHash = "0x" + String(repeating: "a", count: 64)

private actor HistoryRecoveryReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

private actor MonadIndexFeed: AnkrTransport {
    enum Fault: Sendable { case none, wrongOwner, wrongChain, wrongAmount, invalidPage, repeatedPage,
        missingHashIndex, missingTransactionHashIndex, missingReceiptResult, archiveWrongBlock, archiveWrongReceipt, archiveWrongPosition, archiveDuplicateReceipt,
        creation, failedCreation, missingRecipient, creationWrongRPCRecipient, creationMissingRPCRecipient,
        creationMissingReceiptRecipient, creationMissingContract, creationWrongCreator }
    let fault: Fault
    let chain: IndexedEVMChain
    var directions: [String] = []
    var discoveryPages = 0
    var archiveReads = 0
    init(_ fault: Fault = .none, chain: IndexedEVMChain = .monad) { self.fault = fault; self.chain = chain }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if chain == .celo, request.url?.host == "celo.blockscout.com" {
            let row: [String: Any] = ["transaction_hash": monHash, "block_number": 100,
                "timestamp": "2026-10-12T00:00:00Z", "log_index": 7,
                "from": ["hash": monOwner], "to": ["hash": monOther],
                "token": ["type": "ERC-20", "address_hash": monToken, "decimals": "6", "name": "Fixture", "symbol": "T"],
                "total": ["value": "9007199254740993", "decimals": "6"]]
            return (try JSONSerialization.data(withJSONObject: ["items": [row], "next_page_params": NSNull()]), 200)
        }
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))
        if let call = body as? [String: Any] {
            XCTAssertEqual(request.url?.host, "monad-mainnet.g.alchemy.com")
            let method = call["method"] as! String, params = call["params"] as! [Any]
            let result: [String: Any]
            if method == "alchemy_getTokenBalances" {
                discoveryPages += 1
                result = ["address": fault == .wrongOwner ? monOther : monOwner,
                    "tokenBalances": [["contractAddress": monToken, "tokenBalance": "0x999"]],
                    "pageKey": fault == .invalidPage ? 1 : (discoveryPages == 1 || fault == .repeatedPage ? "next" as Any : NSNull())]
            } else {
                XCTAssertEqual(method, "alchemy_getAssetTransfers")
                let options = params[0] as! [String: Any]
                let incoming = options["toAddress"] != nil, category = (options["category"] as! [String])[0]
                directions.append(incoming ? "in" : "out")
                XCTAssertEqual(options["order"] as? String, "desc")
                let from = incoming ? monOther : monOwner, to = incoming ? monOwner : monOther
                var transfer: [String: Any] = ["hash": monHash, "uniqueId": monHash + ":log:7", "blockNum": "0x64",
                    "from": fault == .wrongOwner ? monToken : from, "to": to, "category": category,
                    "metadata": ["blockTimestamp": "2026-10-12T00:00:00Z"],
                    "rawContract": ["value": "0x20000000000001", "address": monToken]]
                if isCreation { transfer["to"] = NSNull() }
                if fault == .missingRecipient { transfer.removeValue(forKey: "to") }
                result = ["transfers": [transfer],
                    "pageKey": fault == .invalidPage ? 1 : NSNull()]
            }
            return (try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": call["id"]!, "result": result]), 200)
        }
        XCTAssertTrue(["rpc.ankr.com", "forno.celo.org"].contains(request.url?.host ?? ""))
        if request.url?.host == "forno.celo.org" { XCTAssertEqual(request.url?.path, "") }
        let rows = (body as! [[String: Any]]).map { call -> [String: Any] in
            let method = call["method"] as! String
            let incoming = directions.last == "in"
            let from = incoming ? monOther : monOwner, to = incoming ? monOwner : monOther
            let result: Any
            switch method {
            case "eth_chainId": result = fault == .wrongChain ? "0x1" : "0x" + String(chain.chainID, radix: 16)
            case "eth_getBlockByNumber": result = ["number": "0x64", "hash": monHash]
            case "eth_getBalance": result = "0x20000000000001"
            case "eth_getTransactionByHash", "eth_getTransactionByBlockHashAndIndex":
                var tx: [String: Any] = ["hash": monHash, "blockHash": monHash, "from": from, "to": to, "value": "0x20000000000001"]
                if method == "eth_getTransactionByBlockHashAndIndex" { tx["blockNumber"] = "0x64"; tx["transactionIndex"] = "0x0" }
                if isCreation && fault != .creationWrongRPCRecipient { tx["to"] = NSNull() }
                if fault == .creationMissingRPCRecipient { tx.removeValue(forKey: "to") }
                result = tx
            case "eth_getBlockReceipts":
                archiveReads += 1
                var receipt: [String: Any] = ["transactionHash": fault == .archiveWrongReceipt ? "0x" + String(repeating: "b", count: 64) : monHash,
                    "blockHash": fault == .archiveWrongBlock ? "0x" + String(repeating: "b", count: 64) : monHash,
                    "blockNumber": "0x64", "transactionIndex": fault == .archiveWrongPosition ? "0x1" : "0x0",
                    "status": "0x1", "gasUsed": "0x5208", "effectiveGasPrice": "0x1",
                    "logs": [["address": monToken, "logIndex": "0x7", "data": "0x20000000000001",
                        "topics": ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef", "0x" + String(repeating: "0", count: 24) + from.dropFirst(2), "0x" + String(repeating: "0", count: 24) + to.dropFirst(2)]]]]
                receipt["from"] = from; receipt["to"] = to
                result = fault == .archiveDuplicateReceipt ? [receipt, receipt] : [receipt]
            case "eth_getTransactionReceipt":
                var receipt: [String: Any] = ["transactionHash": monHash, "blockHash": monHash, "blockNumber": "0x64", "status": "0x1", "gasUsed": "0x5208", "effectiveGasPrice": "0x1",
                    "logs": [["address": monToken, "logIndex": "0x7", "data": fault == .wrongAmount ? "0x1" : "0x20000000000001",
                        "topics": ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef", "0x" + String(repeating: "0", count: 24) + from.dropFirst(2), "0x" + String(repeating: "0", count: 24) + to.dropFirst(2)]]]]
                if isCreation {
                    receipt["to"] = NSNull(); receipt["from"] = fault == .creationWrongCreator ? monOther : from
                    receipt["contractAddress"] = fault == .creationMissingContract ? NSNull() : monToken
                    if fault == .failedCreation { receipt["status"] = "0x0"; receipt["contractAddress"] = NSNull() }
                }
                if fault == .creationMissingReceiptRecipient { receipt.removeValue(forKey: "to") }
                result = receipt
            case "eth_call":
                let params = call["params"] as! [Any], selector = (params[0] as! [String: Any])["data"] as! String
                result = selector == "0x313ce567" ? "0x6" : (selector.hasPrefix("0x70a08231") ? "0x2dc6c0" : "0x")
            default: result = NSNull()
            }
            if fault == .missingReceiptResult && method == "eth_getTransactionReceipt" {
                return ["jsonrpc": "2.0", "id": call["id"]!]
            }
            if isMissingHashIndex && method == "eth_getTransactionReceipt" {
                return ["jsonrpc": "2.0", "id": call["id"]!, "result": NSNull()]
            }
            if fault == .missingTransactionHashIndex && method == "eth_getTransactionByHash" {
                return ["jsonrpc": "2.0", "id": call["id"]!, "result": NSNull()]
            }
            if isMissingHashIndex && method == "eth_getBlockByNumber" {
                return ["jsonrpc": "2.0", "id": call["id"]!, "result": ["number": "0x64", "hash": monHash, "transactions": [monHash]]]
            }
            return ["jsonrpc": "2.0", "id": call["id"]!, "result": result]
        }
        return (try JSONSerialization.data(withJSONObject: rows.reversed().map { $0 }), 200)
    }
    private var isMissingHashIndex: Bool {
        [.missingHashIndex, .missingTransactionHashIndex, .archiveWrongBlock, .archiveWrongReceipt, .archiveWrongPosition, .archiveDuplicateReceipt].contains(fault)
    }
    private var isCreation: Bool {
        switch fault {
        case .creation, .failedCreation, .creationWrongRPCRecipient, .creationMissingRPCRecipient,
             .creationMissingReceiptRecipient, .creationMissingContract, .creationWrongCreator: return true
        default: return false
        }
    }
}

final class MonadIndexTests: XCTestCase, @unchecked Sendable {
    func testUnavailableRecordIsExcludedButMissingVerificationEvidenceIsReported() async throws {
        let reports = HistoryRecoveryReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        OathDiagnostics.record(IndexedEVMClient.HistoryAvailability.missingRPCRecord, operation: "history_rpc_recovery", context: ["chain": "celo"])
        OathDiagnostics.record(IndexedEVMClient.HistoryAvailability.filecoinWrappingEvidenceRequired, operation: "history_rpc_recovery", context: ["chain": "filecoin"])
        for _ in 0..<100 {
            if await reports.events.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await OathDiagnostics.flush()
        let events = await reports.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.context["chain"], "filecoin")
        XCTAssertEqual(events.first?.operation, "history_rpc_recovery")
    }
    func testMalformedReceiptEnvelopeDoesNotTriggerBlockRecovery() async throws {
        let feed = MonadIndexFeed(.missingReceiptResult)
        let client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: feed)
        do { _ = try await client.history(owner: monOwner, stream: .transfers); XCTFail("Absent result is malformed, not a null lookup") }
        catch { XCTAssertEqual(error as? AnkrError, .invalidResponse) }
        let reads = await feed.archiveReads; XCTAssertEqual(reads, 0)
    }
    func testCeloMissingArchiveUsesExistingFallbackAndVerifiedBlockReceipt() async throws {
        let client = try IndexedEVMClient(chain: .celo, apiKey: "fixture", transport: MonadIndexFeed(.missingHashIndex, chain: .celo))
        let page = try await client.history(owner: monOwner, stream: .transfers)
        XCTAssertEqual(page.events.count, 1)
        XCTAssertEqual(page.events.first?.amount, "9007199254740993")
        XCTAssertEqual(page.events.first?.id, monHash + ":log:7")
    }
    func testCeloArchiveCannotAcceptWrongBlockReceipt() async throws {
        let client = try IndexedEVMClient(chain: .celo, apiKey: "fixture", transport: MonadIndexFeed(.archiveWrongBlock, chain: .celo))
        do { _ = try await client.history(owner: monOwner, stream: .transfers); XCTFail("Wrong block must remain rejected") }
        catch { XCTAssertTrue(error is AnkrError) }
    }
    func testMissingReceiptHashIndexRecoversFromSameAnkrBlock() async throws {
        let client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: MonadIndexFeed(.missingHashIndex))
        let page = try await client.history(owner: monOwner, stream: .transfers)
        XCTAssertEqual(page.events.count, 1)
        XCTAssertEqual(page.events.first?.hash, monHash)
        XCTAssertEqual(page.events.first?.amount, "9007199254740993")
        XCTAssertEqual(page.events.first?.id, monHash + ":log:7")
    }
    func testBlockRecoveryRejectsUncorroboratedReceipts() async throws {
        for fault in [MonadIndexFeed.Fault.archiveWrongBlock, .archiveWrongReceipt, .archiveWrongPosition, .archiveDuplicateReceipt] {
            let client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: MonadIndexFeed(fault))
            do { _ = try await client.history(owner: monOwner, stream: .transfers); XCTFail("Unverified receipt: \(fault)") }
            catch { XCTAssertTrue(error is AnkrError) }
        }
    }
    func testMissingTransactionHashIndexRecoversExactBlockPosition() async throws {
        let client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: MonadIndexFeed(.missingTransactionHashIndex))
        let page = try await client.history(owner: monOwner, stream: .transactions)
        XCTAssertEqual(page.events.count, 1)
        XCTAssertEqual(page.events.first?.hash, monHash)
        XCTAssertEqual(page.events.first?.amount, "9007199254740993")
        XCTAssertEqual(page.events.first?.fee, "21000")
    }
    func testContractCreationUsesReceiptAddressWithoutRejectingHistoryPage() async throws {
        let client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: MonadIndexFeed(.creation))
        let page = try await client.history(owner: monOwner, stream: .transactions, through: 2_000_000_000)
        let event = try XCTUnwrap(page.events.first)
        XCTAssertEqual(event.from, monOwner); XCTAssertEqual(event.to, monToken)
        XCTAssertEqual(event.amount, "9007199254740993"); XCTAssertEqual(event.fee, "21000")
        XCTAssertFalse(event.failed); XCTAssertNotNil(page.next)
    }
    func testContractCreationCannotTurnMissingOrMismatchedRecipientsIntoValidTransfers() async throws {
        for fault in [MonadIndexFeed.Fault.missingRecipient, .creationWrongRPCRecipient,
                      .creationMissingRPCRecipient, .creationMissingReceiptRecipient,
                      .creationMissingContract, .creationWrongCreator] {
            let client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: MonadIndexFeed(fault))
            do { _ = try await client.history(owner: monOwner, stream: .transactions); XCTFail("Must reject unverified contract creation: \(fault)") }
            catch { XCTAssertTrue(error is AnkrError) }
        }
        let client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: MonadIndexFeed(.creation))
        do { _ = try await client.history(owner: monOwner, stream: .transfers); XCTFail("ERC-20 transfers require a recipient") }
        catch { XCTAssertTrue(error is AnkrError) }
        let incoming = Data(#"{"direction":"in"}"#.utf8).base64EncodedString()
        do { _ = try await client.history(owner: monOwner, stream: .transactions, cursor: incoming); XCTFail("Creation must not be accepted as an incoming transfer") }
        catch { XCTAssertTrue(error is AnkrError) }
    }
    func testFailedContractCreationRetainsFeeWithoutInventingCreatedContract() async throws {
        let client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: MonadIndexFeed(.failedCreation))
        let page = try await client.history(owner: monOwner, stream: .transactions, through: 2_000_000_000)
        let event = try XCTUnwrap(page.events.first)
        XCTAssertTrue(event.failed); XCTAssertEqual(event.amount, "0"); XCTAssertEqual(event.fee, "21000")
        let raw = try JSONDecoder().decode(SolanaJSON.self, from: event.raw)
        XCTAssertTrue(raw["created_contract"].isNull)
    }
    func testExpiredCursorRecoveryDoesNotTreatOutagesAsBadCursors() throws {
        let monad = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture")
        let unichain = try IndexedEVMClient(chain: .unichain, apiKey: "fixture")
        XCTAssertTrue(monad.canRestartHistory(after: AnkrError.rpc(-32602)))
        XCTAssertFalse(unichain.canRestartHistory(after: AnkrError.rpc(-32602)))
        for error in [AnkrError.http(429), .http(503), .wrongAccount, .invalidResponse, .transport] {
            XCTAssertFalse(monad.canRestartHistory(after: error))
        }
    }
    func testDiscoveryPaginatesAndUsesPinnedANKRBalanceInsteadOfIndexBalance() async throws {
        let feed = MonadIndexFeed(), client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: feed)
        let inventory = try await client.inventory(owner: monOwner)
        XCTAssertTrue(inventory.complete)
        XCTAssertEqual(inventory.holdings.first { $0.token.reference == monToken }?.amount, "3000000")
        XCTAssertEqual(inventory.holdings.first { $0.token.reference == "native" }?.amount, "9007199254740993")
        let pages = await feed.discoveryPages; XCTAssertEqual(pages, 2)
    }
    func testNativeAndTokenHistoryVerifyReceiptsAndVisitBothDirections() async throws {
        for stream in IndexedEVMChain.monad.historyStreams {
            let feed = MonadIndexFeed(), client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: feed)
            let outgoing = try await client.history(owner: monOwner, stream: stream, through: 2_000_000_000)
            XCTAssertEqual(outgoing.events.first?.amount, "9007199254740993")
            let incoming = try await client.history(owner: monOwner, stream: stream, cursor: XCTUnwrap(outgoing.next), through: 2_000_000_000)
            XCTAssertEqual(incoming.events.first?.amount, "9007199254740993"); XCTAssertNil(incoming.next)
            let directions = await feed.directions; XCTAssertEqual(directions, ["out", "in"])
            if stream == .transactions { XCTAssertEqual(outgoing.events.first?.fee, "21000") }
            else { XCTAssertEqual(outgoing.events.first?.token?.reference, monToken) }
        }
        XCTAssertFalse(IndexedEVMChain.monad.historyStreams.contains(.internalTransactions))
    }
    func testOutgoingWindowBoundaryStillVisitsIncoming() async throws {
        let client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: MonadIndexFeed())
        let page = try await client.history(owner: monOwner, stream: .transactions, from: 2_000_000_000, through: 2_000_001_000)
        XCTAssertTrue(page.events.isEmpty); XCTAssertNotNil(page.next)
        let incoming = try await client.history(owner: monOwner, stream: .transactions, cursor: page.next, from: 2_000_000_000, through: 2_000_001_000)
        XCTAssertNil(incoming.next)
    }
    func testRejectsWrongOwnerWrongChainAmountAndMalformedPagination() async throws {
        for fault in [MonadIndexFeed.Fault.wrongOwner, .wrongChain, .wrongAmount, .invalidPage] {
            let client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: MonadIndexFeed(fault))
            do { _ = try await client.history(owner: monOwner, stream: .transfers); XCTFail("Must reject mismatched or incomplete history") }
            catch { XCTAssertTrue(error is AnkrError) }
        }
        for fault in [MonadIndexFeed.Fault.wrongOwner, .invalidPage, .repeatedPage] {
            let client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: MonadIndexFeed(fault))
            let inventory = try await client.inventory(owner: monOwner)
            XCTAssertFalse(inventory.complete, "A bad index must not clear cached tokens")
        }
    }
    func testLiveLatestMonadHistoryReadOnly() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let ankr = env["OATH_TEST_ANKR_KEY"], let alchemy = env["OATH_TEST_ALCHEMY_KEY"], let owner = env["OATH_TEST_MONAD_OWNER"] else { throw XCTSkip("Opt-in public mainnet reads only") }
        let client = try IndexedEVMClient(chain: .monad, apiKey: ankr, alchemyAPIKey: alchemy)
        let result = try await client.history(owner: owner, stream: .transactions)
        XCTAssertFalse(result.events.isEmpty)
        XCTAssertTrue(result.events.allSatisfy { $0.block > 0 })
    }
    func testLiveLatestMonadTokenHistoryReadOnly() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let ankr = env["OATH_TEST_ANKR_KEY"], let alchemy = env["OATH_TEST_ALCHEMY_KEY"] else { throw XCTSkip("Opt-in public mainnet reads only") }
        let client = try IndexedEVMClient(chain: .monad, apiKey: ankr, alchemyAPIKey: alchemy)
        let cursor = Data(#"{"direction":"in"}"#.utf8).base64EncodedString()
        let result = try await client.history(owner: monOwner, stream: .transfers, cursor: cursor)
        XCTAssertFalse(result.events.isEmpty)
        XCTAssertTrue(result.events.allSatisfy { $0.block > 0 })
    }
}
