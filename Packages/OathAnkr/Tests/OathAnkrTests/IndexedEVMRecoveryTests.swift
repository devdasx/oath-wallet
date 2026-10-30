import XCTest
import OathDiagnostics
@testable import OathAnkr

private let recoveryOwner = "0x1111111111111111111111111111111111111111"
private let recoveryToken = "0x3333333333333333333333333333333333333333"
private let recoveryHash = "0x" + String(repeating: "a", count: 64)

private final class IndexedTLSFailure: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed)) }
    override func stopLoading() { }
}

private actor IndexedRecoveryTransport: AnkrTransport {
    enum Failure: Sendable { case tls, afterHead, http(Int), cancelled, malformed, both, wrongChain, badIDs, reorg }
    let chain: IndexedEVMChain
    let failure: Failure
    let tls: AnkrHTTPTransport
    var requests: [URLRequest] = []
    var secondaryBlocks = 0
    init(chain: IndexedEVMChain, failure: Failure = .tls) {
        self.chain = chain; self.failure = failure
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IndexedTLSFailure.self]
        tls = AnkrHTTPTransport(session: URLSession(configuration: config))
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if request.url?.host == "dev.iotexscan.io" { return (Data("{\"status\":\"1\",\"result\":[]}".utf8), 200) }
        if request.url?.host == "chainscan.0g.ai" { return (Data("{\"status\":\"1\",\"result\":{\"list\":[],\"total\":0}}".utf8), 200) }
        if request.url?.host == "api-v2.seistream.app" { return (Data("{\"items\":[],\"pagination\":{\"hasMore\":false}}".utf8), 200) }
        if ["unichain.blockscout.com", "celo.blockscout.com", "scan-api.chiliz.com", "filecoin.blockscout.com"].contains(request.url?.host ?? "") {
            return (Data("{\"items\":[],\"next_page_params\":null}".utf8), 200)
        }
        let json = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        if json["method"].string == "alchemy_getTokenBalances" {
            XCTAssertEqual(chain, .monad)
            return (try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0", "id":1,
                "result":["address":recoveryOwner, "tokenBalances":[]]]), 200)
        }
        let primary = request.url?.host == "rpc.ankr.com"
        let calls = try XCTUnwrap(json.array)
        if primary {
            switch failure {
            case .http(let status): return (Data(), status)
            case .cancelled: throw CancellationError()
            case .malformed: return (Data("{}".utf8), 200)
            case .afterHead where calls.first?["method"].string == "eth_chainId": break
            case .afterHead, .both: throw AnkrError.transport
            default: return try await tls.send(request)
            }
        } else {
            let fallbackHost = chain == .iotex ? "babel-api.mainnet.iotex.io" : chain == .zerog ? "evmrpc.0g.ai" : chain == .sei ? "evm-rpc.sei-apis.com" : chain == .filecoin ? "api.node.glif.io" : chain == .chiliz ? "chiliz-rpc.publicnode.com" : chain == .celo ? "forno.celo.org" : chain.rawValue + "-mainnet.g.alchemy.com"
            let allowedHosts = chain == .iotex ? [fallbackHost, "archive-mainnet.iotex.io"] : [fallbackHost]
            XCTAssertTrue(allowedHosts.contains(request.url?.host ?? ""), "Never route one chain to another chain's RPC")
            XCTAssertEqual(request.url?.scheme, "https")
            if case .both = failure { throw AnkrError.transport }
        }
        let rows = calls.map { call -> [String:Any] in
            let result: Any
            switch call["method"].string {
            case "eth_chainId":
                if case .wrongChain = failure { result = "0x1" }
                else { result = "0x" + String(chain.chainID, radix: 16) }
            case "eth_getBlockByNumber":
                if !primary { secondaryBlocks += 1 }
                let changed: Bool
                if case .reorg = failure { changed = secondaryBlocks > 1 } else { changed = false }
                let requested = call["params"].array?.first?.string
                let number = requested == "latest" ? (primary ? "0x64":"0x65") : requested!
                result = ["number":number, "hash":changed ? "0x" + String(repeating:"b",count:64):recoveryHash]
            case "eth_getBalance": result = "0x20000000000001"
            case "eth_call": result = call["params"].array?.first?["data"].string == "0x313ce567" ? "0x6":"0x2a"
            default: XCTFail("Unexpected inventory RPC"); result = NSNull()
            }
            let id: UInt64
            if case .badIDs = failure { id = 99 } else { id = call["id"].integer! }
            return ["jsonrpc":"2.0", "id":id, "result":result]
        }
        return (try JSONSerialization.data(withJSONObject: rows.reversed().map { $0 }),200)
    }
    func counts() -> (Int, Int) {
        let batches = requests.filter { (try? JSONDecoder().decode(SolanaJSON.self, from: $0.httpBody ?? Data()).array) != nil }
        return (batches.filter { $0.url?.host == "rpc.ankr.com" }.count, batches.filter { $0.url?.host != "rpc.ankr.com" }.count)
    }
}

final class IndexedEVMRecoveryTests: XCTestCase, @unchecked Sendable {
    private func inventory(_ transport: IndexedRecoveryTransport, chain: IndexedEVMChain, key: String? = "recoveryFixture") async throws -> IndexedEVMInventory {
        let token = try IndexedEVMToken(reference: recoveryToken, name: "Fixture", symbol: "FIX", decimals: 6)
        return try await IndexedEVMClient(chain: chain, apiKey: "primaryFixture", alchemyAPIKey: key, transport: transport)
            .inventory(owner: recoveryOwner, tracked: [token])
    }
    func testBothChainsRecoverTLSAndPreserveExactBalances() async throws {
        for chain in IndexedEVMChain.allCases {
            let transport = IndexedRecoveryTransport(chain: chain)
            let value = try await inventory(transport, chain: chain)
            XCTAssertEqual(value.chain, chain); XCTAssertEqual(value.block, 101); XCTAssertTrue(value.complete)
            XCTAssertEqual(value.holdings.first { $0.token.reference == "native" }?.amount, "9007199254740993")
            XCTAssertEqual(value.holdings.first { $0.token.reference == recoveryToken }?.amount, "42")
            let counts = await transport.counts(); XCTAssertEqual(counts.0, 3); XCTAssertEqual(counts.1, chain == .iotex ? 5 : 3)
            XCTAssertFalse(String(decoding: value.raw, as: UTF8.self).contains("Fixture"))
        }
    }
    func testFailureAfterHeadRestartsAndPinsAllNewBalances() async throws {
        for chain in IndexedEVMChain.allCases {
            let transport = IndexedRecoveryTransport(chain: chain, failure: .afterHead)
            let value = try await inventory(transport, chain: chain)
            XCTAssertEqual(value.block, 101)
            let requests = await transport.requests
            var restarted = false
            for request in requests where request.url?.host != "rpc.ankr.com" {
                if request.url?.host == "babel-api.mainnet.iotex.io" { restarted = true }
                guard let body = request.httpBody, let calls = try JSONDecoder().decode(SolanaJSON.self, from: body).array else { continue }
                for call in calls where ["eth_call","eth_getBalance"].contains(call["method"].string ?? "") {
                    let expected = chain == .iotex && !restarted ? "0x64" : "0x65"
                    XCTAssertEqual(call["params"].array?.last?.string, expected)
                }
            }
        }
    }
    func testRecoveryRejectsWrongChainMalformedIDsAndReorganization() async throws {
        for chain in IndexedEVMChain.allCases {
            for (failure, expected) in [(IndexedRecoveryTransport.Failure.wrongChain, AnkrError.wrongChain),(.badIDs,.invalidResponse),(.reorg,.invalidResponse)] {
                do { _ = try await inventory(IndexedRecoveryTransport(chain: chain, failure: failure), chain: chain); XCTFail() }
                catch { XCTAssertEqual(error as? AnkrError, expected) }
            }
        }
    }
    func testCancellationMalformedPrimaryAndAuthorizationDoNotFailOver() async throws {
        for chain in IndexedEVMChain.allCases {
            for failure in [IndexedRecoveryTransport.Failure.cancelled,.malformed,.http(401),.http(403)] {
                let transport = IndexedRecoveryTransport(chain: chain, failure: failure)
                do { _ = try await inventory(transport, chain: chain); XCTFail() }
                catch {
                    if case .cancelled = failure { XCTAssertTrue(error is CancellationError) }
                    else { XCTAssertNotNil(error as? AnkrError) }
                }
                let counts = await transport.counts(); XCTAssertEqual(counts.0,1); XCTAssertEqual(counts.1,0)
            }
        }
    }
    func testPersistentOutageAndMissingKeyRemainBoundedFailures() async throws {
        for chain in IndexedEVMChain.allCases {
            for key: String? in ["fixture",nil] {
                let transport = IndexedRecoveryTransport(chain: chain, failure: .both)
                do { _ = try await inventory(transport, chain: chain, key: key); XCTFail("Never fabricate a zero balance") }
                catch { XCTAssertEqual(error as? AnkrError,.transport) }
                let counts = await transport.counts(); XCTAssertEqual(counts.0,3); XCTAssertEqual(counts.1,key == nil && ![.celo, .chiliz, .filecoin, .sei, .zerog, .iotex].contains(chain) ? 0:3)
            }
        }
    }
    func testRateLimitsAndServerFailuresRecoverForBothChains() async throws {
        for chain in IndexedEVMChain.allCases {
            for status in [429,503] {
                let value = try await inventory(IndexedRecoveryTransport(chain: chain, failure: .http(status)), chain: chain)
                XCTAssertTrue(value.complete); XCTAssertEqual(value.chain,chain)
            }
        }
    }
}

private actor IndexedRecoveryReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}
final class IndexedEVMRecoveryDiagnosticsTests: XCTestCase, @unchecked Sendable {
    func testRecoveryAvailabilityExclusionsAndValidationPrivacyForEveryChain() async throws {
        let reports = IndexedRecoveryReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at:file) }
        OathDiagnostics.configure(file:file,transport:reports)
        for chain in IndexedEVMChain.allCases {
            let operation = UUID()
            let value = try await OathDiagnostics.$operationID.withValue(operation) {
                try await OathDiagnostics.$chain.withValue(chain.rawValue) {
                    try await IndexedEVMClient(chain:chain,apiKey:"privatePrimaryFixture",alchemyAPIKey:"privateRecoveryFixture",
                        transport:IndexedRecoveryTransport(chain:chain)).inventory(owner:recoveryOwner)
                }
            }
            XCTAssertEqual(value.chain,chain)
            // Availability failures are excluded by the shared policy; malformed
            // RPC replies must still retain chain context and privacy filtering.
            do {
                _ = try await OathDiagnostics.$operationID.withValue(operation) {
                    try await OathDiagnostics.$chain.withValue(chain.rawValue) {
                        try await IndexedEVMClient(chain:chain,apiKey:"privatePrimaryFixture",alchemyAPIKey:"privateRecoveryFixture",
                            transport:IndexedRecoveryTransport(chain:chain, failure:.badIDs)).inventory(owner:recoveryOwner)
                    }
                }
                XCTFail("Malformed fallback replies must fail validation")
            } catch { XCTAssertEqual(error as? AnkrError, .invalidResponse) }
            for _ in 0..<100 {
                await OathDiagnostics.flush()
                if await reports.events.contains(where: { $0.operationID == operation && $0.error.message == "invalidResponse" }) { break }
                try await Task.sleep(for:.milliseconds(10))
            }
            let events = await reports.events.filter { $0.operationID == operation }
            XCTAssertTrue(events.contains { $0.error.message == "invalidResponse" })
            XCTAssertFalse(events.contains { $0.error.domain == NSURLErrorDomain && $0.error.code == -1200 })
            XCTAssertFalse(events.contains { $0.operation == "inventory_rpc_recovery" })
            XCTAssertTrue(events.allSatisfy { $0.privacyFiltered && $0.context["chain"] == chain.rawValue })
            let encoded = String(decoding:try JSONEncoder().encode(events),as:UTF8.self)
            for secret in ["privatePrimaryFixture","privateRecoveryFixture",recoveryOwner,recoveryToken] { XCTAssertFalse(encoded.contains(secret)) }
        }
    }
}

private struct IndexedLiveRecoveryTransport: AnkrTransport {
    let tls: AnkrHTTPTransport
    let live = AnkrHTTPTransport()
    init() {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IndexedTLSFailure.self]
        tls = AnkrHTTPTransport(session:URLSession(configuration:config))
    }
    func send(_ request: URLRequest) async throws -> (Data,Int) {
        if request.url?.host == "rpc.ankr.com" { return try await tls.send(request) }
        // Isolate live RPC recovery from optional public index availability.
        if request.url?.host == "chainscan.0g.ai" { return (Data("{\"status\":\"1\",\"result\":{\"list\":[],\"total\":0}}".utf8), 200) }
        if request.url?.host == "api-v2.seistream.app" { return (Data("{\"items\":[],\"pagination\":{\"hasMore\":false}}".utf8), 200) }
        if ["unichain.blockscout.com", "celo.blockscout.com", "scan-api.chiliz.com", "filecoin.blockscout.com"].contains(request.url?.host ?? "") { return (Data("{\"items\":[],\"next_page_params\":null}".utf8),200) }
        if let body = request.httpBody {
            let json = try JSONDecoder().decode(SolanaJSON.self,from:body)
            if json["method"].string == "alchemy_getTokenBalances" {
                let owner = try XCTUnwrap(json["params"].array?.first?.string)
                return (try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":1,"result":["address":owner,"tokenBalances":[]]]),200)
            }
        }
        return try await live.send(request)
    }
}
final class IndexedEVMLiveRecoveryTests: XCTestCase, @unchecked Sendable {
    func testBothLiveRecoveriesMatchIndependentPinnedBalances() async throws {
        guard ProcessInfo.processInfo.environment["OATH_INDEXED_RECOVERY_LIVE"] == "1" else { throw XCTSkip("Opt-in public mainnet read check") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let keys = try PropertyListDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let primary = try XCTUnwrap(keys["AnkrAPIKey"]), secondary = try XCTUnwrap(keys["AlchemyAPIKey"])
        for chain in [IndexedEVMChain.unichain, .monad] {
            // Public contract/account fixtures, never a user's wallet.
            let owner = chain == .monad ? chain.wrappedNative : "0xb5a2a236581dbd6bcecd8a25eebff140595f138c"
            let token = try IndexedEVMToken(reference:chain.wrappedNative,name:"Wrapped",symbol:"W",decimals:18)
            let value = try await IndexedEVMClient(chain:chain,apiKey:primary,alchemyAPIKey:secondary,transport:IndexedLiveRecoveryTransport())
                .inventory(owner:owner,tracked:[token])
            XCTAssertEqual(value.chain,chain); XCTAssertTrue(value.complete); XCTAssertEqual(value.holdings.count,2)
            let block = "0x" + String(value.block,radix:16)
            let calls: [[String:Any]] = [
                ["jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]],
                ["jsonrpc":"2.0","id":2,"method":"eth_getBlockByNumber","params":[block,false]],
                ["jsonrpc":"2.0","id":3,"method":"eth_getBalance","params":[owner,block]],
                ["jsonrpc":"2.0","id":4,"method":"eth_call","params":[["to":token.reference,"data":"0x70a08231" + String(repeating:"0",count:24) + owner.dropFirst(2)],block]]]
            var request = URLRequest(url:URL(string:"https://rpc.ankr.com")!.appendingPathComponent(chain.rpcPath).appendingPathComponent(primary))
            request.httpMethod = "POST"; request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject:calls)
            let (data,status) = try await AnkrHTTPTransport().send(request); XCTAssertEqual(status,200)
            let rows = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self,from:data).array)
            func result(_ id:UInt64) throws -> SolanaJSON { try XCTUnwrap(rows.first { $0["id"].integer == id })["result"] }
            XCTAssertEqual(try IndexedEVMIdentity.amount(result(1)),String(chain.chainID))
            XCTAssertEqual(try result(2)["hash"].string,value.blockHash)
            XCTAssertEqual(try IndexedEVMIdentity.amount(result(3)),value.holdings.first { $0.token.reference == "native" }?.amount)
            XCTAssertEqual(try IndexedEVMIdentity.amount(result(4)),value.holdings.first { $0.token.reference == token.reference }?.amount)
            print("Live " + chain.rawValue + " recovery: chain, block hash, native and wrapped balances match independent RPC")
        }
    }
}
