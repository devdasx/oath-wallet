import XCTest
@testable import OathAnkr

private let publicAddress = "0xF977814e90dA44bFA03b6295A0616a897441aceC"

private actor FixtureTransport: AnkrTransport {
    var requests: [Data] = []
    var statuses: [Int]
    let data: Data
    var rpcErrors: [Int] = []
    init(_ data: Data, statuses: [Int] = [200]) { self.data = data; self.statuses = statuses }
    init(_ data: Data, rpcErrors: [Int]) { self.data = data; self.statuses = [200]; self.rpcErrors = rpcErrors }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request.httpBody!)
        if !rpcErrors.isEmpty {
            return (try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":1,
                "error":["code":rpcErrors.removeFirst(),"message":"Provider failure"]]),200)
        }
        let status = statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        return (data,status)
    }
}

final class AnkrTests: XCTestCase, @unchecked Sendable {
    private func fixture(_ chain: AnkrChain, _ method: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: chain.rawValue + "-" + method,
                                                        withExtension: "json", subdirectory: "Fixtures")))
    }
    func testAllSeventeenActualResponseShapesDecodeAndKeepEveryOriginalByte() async throws {
        XCTAssertEqual(AnkrChain.allCases.count,17)
        for chain in AnkrChain.allCases {
            for method in ["ankr_getAccountBalance","ankr_getTransactionsByAddress","ankr_getTokenTransfers"] {
                let raw = try fixture(chain,method)
                let transport = FixtureTransport(raw)
                let client = try AnkrClient(apiKey: "fixture",transport: transport)
                switch method {
                case "ankr_getAccountBalance":
                    let page = try await client.balances(chain: chain,address: publicAddress)
                    XCTAssertEqual(page.raw,raw)
                    XCTAssertEqual(page.value.totalCount,page.value.assets.count)
                case "ankr_getTransactionsByAddress":
                    let page = try await client.transactions(chain: chain,address: publicAddress)
                    XCTAssertEqual(page.raw,raw)
                default:
                    let page = try await client.transfers(chain: chain,address: publicAddress)
                    XCTAssertEqual(page.raw,raw)
                }
                let request = try JSONSerialization.jsonObject(with: await transport.requests[0]) as! [String:Any]
                let params = request["params"] as! [String:Any]
                XCTAssertEqual(params["blockchain"] as? [String],[chain.rawValue])
                if method == "ankr_getAccountBalance" {
                    XCTAssertEqual(params["onlyWhitelisted"] as? Bool,true,chain.rawValue)
                }
            }
        }
    }
    func testCursorWindowAndWhitelistOnEveryBalancePageAreExplicit() async throws {
        let transport = FixtureTransport(try fixture(.eth,"ankr_getTransactionsByAddress"))
        let client = try AnkrClient(apiKey:"fixture",transport:transport)
        _ = try await client.transactions(chain:.eth,address:publicAddress,cursor:"opaque+/=",fromTimestamp:100,toTimestamp:200,pageSize:2)
        let request = try JSONSerialization.jsonObject(with: await transport.requests[0]) as! [String:Any]
        let params = request["params"] as! [String:Any]
        XCTAssertEqual(params["pageToken"] as? String,"opaque+/=")
        XCTAssertEqual(params["fromTimestamp"] as? Int,100); XCTAssertEqual(params["toTimestamp"] as? Int,200)
        XCTAssertEqual(params["includeLogs"] as? Bool,true)
        let balances = FixtureTransport(try fixture(.eth,"ankr_getAccountBalance"))
        let balanceClient = try AnkrClient(apiKey:"fixture",transport:balances)
        for cursor in [nil,"opaque-next-page"] as [String?] {
            _ = try await balanceClient.balances(chain:.eth,address:publicAddress,cursor:cursor)
            let b = try JSONSerialization.jsonObject(with: await balances.requests.last!) as! [String:Any]
            let balanceParams = b["params"] as! [String:Any]
            XCTAssertEqual(balanceParams["onlyWhitelisted"] as? Bool,true)
            XCTAssertEqual(balanceParams["pageToken"] as? String,cursor)
        }
    }
    func testExplicitUnfilteredBalancesOnEveryPageAndSupportedChain() async throws {
        for chain in AnkrChain.allCases {
            let transport = FixtureTransport(try fixture(chain, "ankr_getAccountBalance"))
            let client = try AnkrClient(apiKey: "fixture", transport: transport)
            for cursor in [nil, "next-inventory-page"] as [String?] {
                _ = try await client.balances(chain: chain, address: publicAddress, cursor: cursor, onlyWhitelisted: false)
                let request = try JSONSerialization.jsonObject(with: await transport.requests.last!) as! [String: Any]
                let params = request["params"] as! [String: Any]
                XCTAssertEqual(params["onlyWhitelisted"] as? Bool, false, chain.rawValue)
                XCTAssertEqual(params["blockchain"] as? [String], [chain.rawValue])
                XCTAssertEqual(params["pageToken"] as? String, cursor)
            }
        }
    }
    func testExactIntegerConversionBeyondFloatingPointAndMaxUint256() throws {
        XCTAssertEqual(try AnkrQuantity.decimal("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
                       "115792089237316195423570985008687907853269984665640564039457584007913129639935")
        XCTAssertEqual(try AnkrQuantity.decimal("0x20000000000001"),"9007199254740993")
        XCTAssertEqual(try AnkrQuantity.multiply("0x5208","0x3b9aca00"),"21000000000000")
        XCTAssertEqual(try AnkrQuantity.decimal("000"),"0")
        for value in ["", "-1", "0x", "0xg1", "0x１２", "1e18", "1.5", String(repeating:"1",count:79)] {
            XCTAssertThrowsError(try AnkrQuantity.decimal(value))
        }
        XCTAssertFalse(AnkrQuantity.address("0x" + String(repeating:"１",count:40)))
    }
    func testRejectsCrossChainCrossAccountMalformedAndRPCFailures() async throws {
        let transport = FixtureTransport(try fixture(.eth,"ankr_getAccountBalance"))
        let client = try AnkrClient(apiKey:"fixture",transport:transport)
        do { _ = try await client.balances(chain:.bsc,address:publicAddress); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError,.wrongChain) }
        do { _ = try await client.balances(chain:.eth,address:"0x"+String(repeating:"1",count:40)); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError,.wrongAccount) }
        do { _ = try await client.balances(chain:.eth,address:"invalid"); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError,.invalidAddress) }
        for (raw,expected) in [
            (#"{"jsonrpc":"2.0","id":1,"error":{"code":-32075,"message":"private URL must never become a user error"}}"#,.rpc(-32075)),
            (#"{"jsonrpc":"2.0","id":99,"result":{"assets":[],"totalBalanceUsd":"0"}}"#,.invalidResponse),
            ("not json",.invalidResponse)
        ] as [(String,AnkrError)] {
            do { _ = try await AnkrClient(apiKey:"fixture",transport:FixtureTransport(Data(raw.utf8))).balances(chain:.eth,address:publicAddress); XCTFail() }
            catch { XCTAssertEqual(error as? AnkrError,expected) }
        }
    }
    func testTransientHTTPFailureRetriesAndPermanentFailureDoesNot() async throws {
        let transport = FixtureTransport(try fixture(.story,"ankr_getAccountBalance"),statuses:[429,503,200])
        let page = try await AnkrClient(apiKey:"fixture",transport:transport).balances(chain:.story,address:publicAddress)
        XCTAssertTrue(page.value.assets.isEmpty)
        let requests = await transport.requests.count; XCTAssertEqual(requests,3)
        let denied = FixtureTransport(Data(),statuses:[401])
        do { _ = try await AnkrClient(apiKey:"fixture",transport:denied).balances(chain:.eth,address:publicAddress); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError,.http(401)) }
        let attempts = await denied.requests.count; XCTAssertEqual(attempts,1)
    }
    func testHTTP200TransientRPCErrorsRetryButAccessFailuresDoNot() async throws {
        let data = try fixture(.story,"ankr_getAccountBalance")
        let transient = FixtureTransport(data,rpcErrors:[-32090,-32055])
        _ = try await AnkrClient(apiKey:"fixture",transport:transient).balances(chain:.story,address:publicAddress)
        let recovered = await transient.requests.count
        XCTAssertEqual(recovered,3)
        let denied = FixtureTransport(data,rpcErrors:[-32075])
        do { _ = try await AnkrClient(apiKey:"fixture",transport:denied).balances(chain:.story,address:publicAddress); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError,.rpc(-32075)) }
        let failed = await denied.requests.count
        XCTAssertEqual(failed,1)
    }
    func testLiveWhitelistedBalancesAcrossAllMainnets() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ANKR_LIVE"] == "1" else { throw XCTSkip("Opt-in public read-only API test") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath:path)),format:nil) as! [String:Any]
        let client = try AnkrClient(apiKey: XCTUnwrap(config["AnkrAPIKey"] as? String))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for chain in AnkrChain.allCases {
                group.addTask {
                    var cursor: String?
                    var visited: Set<String> = []
                    var references: Set<String> = []
                    var count = 0
                    repeat {
                        let page = try await client.balances(chain:chain,address:publicAddress,cursor:cursor)
                        for asset in page.value.assets {
                            XCTAssertTrue(references.insert(asset.reference).inserted,chain.rawValue)
                        }
                        count += page.value.assets.count
                        cursor = page.value.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
                        if let cursor {
                            guard visited.insert(cursor).inserted else { throw AnkrError.paginationLoop }
                        } else if let total = page.value.totalCount {
                            XCTAssertEqual(count,total,chain.rawValue)
                        }
                    } while cursor != nil
                    print("Ankr whitelist \(chain.rawValue): \(count) assets, complete inventory checked")
                }
            }
            try await group.waitForAll()
        }
    }
    func testLivePublicMainnetsAndPagination() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ANKR_LIVE"] == "1" else { throw XCTSkip("Opt-in public read-only API test") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath:path)),format:nil) as! [String:Any]
        let client = try AnkrClient(apiKey: XCTUnwrap(config["AnkrAPIKey"] as? String))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for chain in AnkrChain.allCases {
                group.addTask {
                    async let balance = client.balances(chain:chain,address:publicAddress)
                    async let transactions = client.transactions(chain:chain,address:publicAddress,pageSize:2)
                    async let transfers = client.transfers(chain:chain,address:publicAddress,pageSize:2)
                    let (b,t,x) = try await (balance,transactions,transfers)
                    XCTAssertEqual(b.value.totalCount,b.value.assets.count,chain.rawValue)
                    if let cursor = t.value.nextPageToken, !cursor.isEmpty {
                        let second = try await client.transactions(chain:chain,address:publicAddress,cursor:cursor,pageSize:2)
                        XCTAssertTrue(Set(t.value.transactions.map(\.hash)).isDisjoint(with:second.value.transactions.map(\.hash)),chain.rawValue)
                    }
                    if let cursor = x.value.nextPageToken, !cursor.isEmpty {
                        let second = try await client.transfers(chain:chain,address:publicAddress,cursor:cursor,pageSize:2)
                        let keys: (AnkrTransfer) -> String = { $0.transactionHash + ":" + String($0.logIndex) + ":" + $0.contractAddress }
                        XCTAssertTrue(Set(x.value.transfers.map(keys)).isDisjoint(with:second.value.transfers.map(keys)),chain.rawValue)
                    }
                    print("Ankr live \(chain.rawValue): \(b.value.assets.count) balances; history and continuation checked")
                }
            }
            try await group.waitForAll()
        }
        for address in ["0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", "0x76215604Ee770533c307e122933Bf183b1C0d6C0"] {
            for chain in [AnkrChain.eth,.bsc,.base,.arbitrum,.polygon] {
                async let b = client.balances(chain:chain,address:address)
                async let t = client.transactions(chain:chain,address:address,pageSize:2)
                async let x = client.transfers(chain:chain,address:address,pageSize:2)
                _ = try await (b,t,x)
            }
        }
        // Addresses from public recent blocks, plus a public Telos WETH
        // contract. Exercise active accounts on less common networks too.
        let recent: [(AnkrChain,String)] = [
            (.flare,"0x85d134f68c3c564bb935479490e5c8df5f4f1124"),
            (.somnia,"0xf47b84e40c13b6bbd35721f458c98f4fdf96a9b8"),
            (.story,"0xd2f6a17b5842f783039247b038cbc1294c4facf4"),
            (.linea,"0xb01caea8c6c47bbf4f4b4c5080ca642043359c2e"),
            (.taiko,"0x0000777735367b36bc9b61c50022d9d0700db4ec"),
            (.telos,"0xBAb93B7ad7fE8692A878B95a8e689423437cc500")
        ]
        try await withThrowingTaskGroup(of:Void.self) { group in
            for (chain,address) in recent {
                group.addTask {
                    async let balance = client.balances(chain:chain,address:address)
                    async let transactions = client.transactions(chain:chain,address:address,pageSize:3)
                    async let transfers = client.transfers(chain:chain,address:address,pageSize:3)
                    let (b,t,x) = try await (balance,transactions,transfers)
                    XCTAssertFalse(t.value.transactions.isEmpty,chain.rawValue)
                    XCTAssertTrue(b.value.assets.allSatisfy { $0.holderAddress.lowercased() == address.lowercased() })
                    print("Ankr active public \(chain.rawValue): \(b.value.assets.count) balances, \(t.value.transactions.count) transactions, \(x.value.transfers.count) token events")
                }
            }
            try await group.waitForAll()
        }
    }
}
