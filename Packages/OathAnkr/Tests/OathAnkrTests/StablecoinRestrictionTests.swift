import Foundation
import XCTest
@testable import OathAnkr

@MainActor final class StablecoinRestrictionTests: XCTestCase {
    func testHTTPFailureIsNotDecodedAsCorruptChainData() async throws {
        for status in [400,403,404,429,503] {
            let checker = StablecoinRestrictionCheck(endpoints:[:],transport:RestrictionHTTPFailureFixture(status:status))
            do {
                _ = try await checker.request(URL(string:"https://fixture.invalid")!)
                XCTFail("Accepted HTTP failure")
            } catch StablecoinRestrictionCheck.Failure.http(let actual) {
                XCTAssertEqual(actual,status)
            } catch { XCTFail("HTTP \(status) was replaced with \(type(of:error))") }
        }
        let invalidSuccess = StablecoinRestrictionCheck(endpoints:[:],transport:RestrictionHTTPFailureFixture(status:200))
        do {
            _ = try await invalidSuccess.request(URL(string:"https://fixture.invalid")!)
            XCTFail("Malformed successful response became valid data")
        } catch { XCTAssertTrue(error is DecodingError) }
        let absent = StablecoinRestrictionCheck(endpoints:[:],transport:RestrictionHTTPFailureFixture(status:404,
            body:Data(#"{"status":404,"type":"https://stellar.org/horizon-errors/not_found"}"#.utf8)))
        let result = try await absent.request(URL(string:"https://fixture.invalid")!)
        XCTAssertEqual(result,.null)
    }
    func testDeniedNetworkIdentityRemainsUnavailableForAptosAndSui() async {
        for chain in ["aptos", "sui"] {
            let tokens = StablecoinRestrictionRegistry.tokens(network: chain)
            XCTAssertFalse(tokens.isEmpty)
            let checker = StablecoinRestrictionCheck(endpoints: [chain: endpoint],
                transport: RestrictionHTTPFailureFixture(status: 403))
            let results = await checker.check(.init(network: chain,
                address: "0x" + String(repeating: "0", count: 63) + "1"), tokens: tokens)
            XCTAssertEqual(results.count, tokens.count)
            XCTAssertTrue(results.allSatisfy { $0.outcome == .unavailable })
        }
    }
    typealias J = SolanaJSON
    private let owner = "0x0000000000000000000000000000000000000001"
    private let endpoint = URL(string: "https://fixture.example/rpc")!
    private func token(_ chain: String, _ symbol: String) -> StablecoinRestrictionToken {
        StablecoinRestrictionRegistry.tokens.first { $0.network == chain && $0.symbol == symbol }!
    }
    private func word(_ flag: Bool) -> J { .string("0x" + String(repeating: "0", count: 63) + (flag ? "1" : "0")) }
    private func rpc(_ result: J) -> J { .object(["jsonrpc": .string("2.0"), "id": .number("1"), "result": result]) }

    func testRegistryUsesDistinctPinnedIssuerIdentities() {
        let tokens = StablecoinRestrictionRegistry.tokens
        XCTAssertEqual(tokens.count, Set(tokens.map(\.id)).count)
        XCTAssertEqual(Set(tokens.map(\.network)).count, 22)
        for token in tokens where StablecoinRestrictionRegistry.evmIDs[token.network] != nil {
            XCTAssertEqual(token.reference.count, 42, token.id)
            XCTAssertTrue(token.reference.dropFirst(2).allSatisfy(\.isHexDigit))
        }
        for chain in ["bitcoin", "bitcoincash", "bnb", "fantom", "somnia", "story", "gnosis", "robinhood", "scroll", "taiko", "telos", "thorchain"] {
            XCTAssertTrue(StablecoinRestrictionRegistry.tokens(network: chain).isEmpty, "Do not invent issuer support from a token symbol")
        }
        XCTAssertEqual(token("arbitrum", "USDT0").method, "isBlocked(address)")
        XCTAssertEqual(token("ethereum", "USDT").method, "isBlackListed(address)")
        XCTAssertEqual(token("ethereum", "USDC").method, "isBlacklisted(address)")
        XCTAssertEqual(token("celo", "USDT").method, "isBlocked(address)")
        XCTAssertEqual(token("celo", "USDC").method, "isBlacklisted(address)")
    }
    func testABIBoolStrictlyRequiresACompleteBooleanWord() throws {
        XCTAssertTrue(try StablecoinRestrictionCheck.abiBool(word(true)))
        XCTAssertFalse(try StablecoinRestrictionCheck.abiBool(word(false)))
        for value: J in [.null, .bool(true), .string("0x"), .string("0x1"), .string(String(repeating: "0", count: 64)),
                         .string("0x" + String(repeating: "0", count: 63) + "2"), .string("0x1" + String(repeating: "0", count: 63))] {
            XCTAssertThrowsError(try StablecoinRestrictionCheck.abiBool(value))
        }
    }
    func testEVMChecksBothContractsWithTheirCorrectSelectors() async throws {
        let tether = token("ethereum", "USDT")
        let circle = token("ethereum", "USDC")
        let transport = RestrictionFixtureTransport { request in
            let body = try JSONDecoder().decode(J.self, from: request.httpBody!)
            if body["method"].string == "eth_chainId" { return (self.rpc(.string("0x1")), 200) }
            XCTAssertEqual(body["method"].string, "eth_call")
            let params = body["params"].array!
            XCTAssertEqual(params[1], .string("latest"))
            let contract = params[0]["to"].string!
            let signature = contract == tether.reference ? tether.method : circle.method
            let expected = "0x" + TronSendCrypto.hex(Data(TronSendCrypto.keccak(Data(signature.utf8)).prefix(4)))
                + String(repeating: "0", count: 63) + "1"
            XCTAssertEqual(params[0]["data"].string, expected)
            return (self.rpc(self.word(contract == tether.reference)), 200)
        }
        let checker = StablecoinRestrictionCheck(endpoints: ["ethereum": endpoint], transport: transport)
        let results = await checker.check(.init(network: "ethereum", address: owner), tokens: [tether, circle])
        XCTAssertEqual(results.first { $0.token == tether }?.outcome, .restricted)
        XCTAssertEqual(results.first { $0.token == circle }?.outcome, .notDetected)
        let count = await transport.count
        XCTAssertEqual(count, 3)
    }
    func testWrongNetworkDoesNotProbeContracts() async {
        let transport = RestrictionFixtureTransport { _ in (self.rpc(.string("0xaa36a7")), 200) }
        let checker = StablecoinRestrictionCheck(endpoints: ["ethereum": endpoint], transport: transport)
        let results = await checker.check(.init(network: "ethereum", address: owner), tokens: [token("ethereum", "USDT")])
        XCTAssertEqual(results.map(\.outcome), [.unavailable])
        let count = await transport.count
        XCTAssertEqual(count, 1)
    }
    func testRPCAndHTTPFailuresNeverMeanRestrictedOrClear() async {
        for response in [(J.object(["jsonrpc": .string("2.0"), "id": .number("1"),
                                   "error": .object(["code": .number("-32000"), "message": .string("fixture failure")])]), 200),
                         (J.object([:]), 429), (rpc(.string("0x")), 200)] {
            let transport = RestrictionFixtureTransport { request in
                let body = try JSONDecoder().decode(J.self, from: request.httpBody!)
                return body["method"].string == "eth_chainId" ? (self.rpc(.string("0x1")), 200) : response
            }
            let checker = StablecoinRestrictionCheck(endpoints: ["ethereum": endpoint], transport: transport)
            let results = await checker.check(.init(network: "ethereum", address: owner), tokens: [token("ethereum", "USDT")])
            XCTAssertEqual(results.map(\.outcome), [.unavailable])
        }
    }
    func testSolanaChecksAllAccountsIncludingZeroAndRejectsWrongMint() throws {
        let owner = SolanaIdentity.wrappedSOL, mint = token("solana", "USDT").reference
        func row(_ state: String, _ mint: String) -> J {
            .object(["pubkey": .string(SolanaIdentity.tokenProgram), "account": .object([
                "owner": .string(SolanaIdentity.tokenProgram), "data": .object(["parsed": .object([
                    "type": .string("account"), "info": .object(["owner": .string(owner), "mint": .string(mint),
                    "state": .string(state), "tokenAmount": .object(["amount": .string("0")])])])])])])
        }
        func inventory(_ rows: [J]) -> J { .object(["context": .object(["slot": .number("10")]), "value": .array(rows)]) }
        XCTAssertTrue(try StablecoinRestrictionCheck.solanaFrozen(inventory([row("frozen", mint)]), owner: owner, mint: mint))
        XCTAssertFalse(try StablecoinRestrictionCheck.solanaFrozen(inventory([row("initialized", mint)]), owner: owner, mint: mint))
        XCTAssertFalse(try StablecoinRestrictionCheck.solanaFrozen(inventory([]), owner: owner, mint: mint))
        for bad in [row("frozen", "wrong-mint"), row("unknown", mint)] {
            XCTAssertThrowsError(try StablecoinRestrictionCheck.solanaFrozen(inventory([bad]), owner: owner, mint: mint))
        }
        XCTAssertThrowsError(try StablecoinRestrictionCheck.solanaFrozen(.null, owner: owner, mint: mint))
    }
    func testStellarAuthorizationMustBelongToExactIssuerAndAsset() throws {
        let usdc = token("stellar", "USDC")
        func account(_ issuer: String, _ flag: J) -> J {
            .object(["account_id": .string("fixture"), "balances": .array([.object([
                "asset_issuer": .string(issuer), "asset_code": .string("USDC"), "is_authorized": flag])])])
        }
        XCTAssertTrue(try StablecoinRestrictionCheck.stellarRestricted(account(usdc.reference, .bool(false)), owner: "fixture", token: usdc))
        XCTAssertFalse(try StablecoinRestrictionCheck.stellarRestricted(account("imposter", .bool(false)), owner: "fixture", token: usdc))
        XCTAssertThrowsError(try StablecoinRestrictionCheck.stellarRestricted(account(usdc.reference, .null), owner: "fixture", token: usdc))
        XCTAssertThrowsError(try StablecoinRestrictionCheck.stellarRestricted(account(usdc.reference, .bool(false)), owner: "other", token: usdc))
    }
    func testTONBothLockBitsAndMalformedVMResponses() throws {
        func stack(_ status: String, _ exit: UInt64 = 0) -> J {
            .object(["exit_code": .number(String(exit)), "stack": .array([.array([.string("num"), .string(status)])])])
        }
        for value in 0...3 { XCTAssertEqual(try StablecoinRestrictionCheck.tonFrozen(stack("0x\(value)")), value > 0) }
        for value in [stack("0x4"), stack("1"), stack("0x1", 11), .null] {
            XCTAssertThrowsError(try StablecoinRestrictionCheck.tonFrozen(value))
        }
    }
    func testSuiEpochTransitionsAndMalformedReturnValues() throws {
        func result(_ flags: [UInt8]) -> J {
            .object(["effects": .object(["status": .string("SUCCESS")]), "outputs": .array(flags.map { flag in
                .object(["returnValues": .array([.object(["value": .object(["type": .object(["repr": .string("bool")]),
                    "bcs": .string(Data([flag]).base64EncodedString())])])])])
            })])
        }
        XCTAssertFalse(try StablecoinRestrictionCheck.suiRestrictedResult(result([0, 0])))
        for flags: [UInt8] in [[0, 1], [1, 0], [1, 1]] { XCTAssertTrue(try StablecoinRestrictionCheck.suiRestrictedResult(result(flags))) }
        for flags: [UInt8] in [[], [1], [0, 2]] { XCTAssertThrowsError(try StablecoinRestrictionCheck.suiRestrictedResult(result(flags))) }
    }
    func testNearStringEnumAndCircleBooleanAreNotInterchangeable() async {
        for symbol in ["USDT", "USDC"] {
            for restricted in [false, true] {
                let asset = token("near", symbol)
                let transport = RestrictionFixtureTransport { request in
                    let body = try JSONDecoder().decode(J.self, from: request.httpBody!)
                    if body["method"].string == "status" { return (self.rpc(.object(["chain_id": .string("mainnet")])), 200) }
                    XCTAssertEqual(body["params"]["method_name"].string, asset.method)
                    let value: J = symbol == "USDT" ? .string(restricted ? "Banned" : "Allowable") : .bool(restricted)
                    let bytes = try JSONEncoder().encode(value)
                    return (self.rpc(.object(["result": .array(bytes.map { .number(String($0)) })])), 200)
                }
                let checker = StablecoinRestrictionCheck(endpoints: ["near": endpoint], transport: transport)
                let result = await checker.check(.init(network: "near", address: "fixture.near"), tokens: [asset])
                XCTAssertEqual(result.first?.outcome, restricted ? .restricted : .notDetected)
            }
        }
    }
    func testAptosUSDTAndUSDCUseTheirOwnReadOnlyViews() async {
        for symbol in ["USDT", "USDC"] {
            let asset = token("aptos", symbol)
            let transport = RestrictionFixtureTransport { request in
                guard let bytes = request.httpBody else { return (.object(["chain_id": .number("1")]), 200) }
                let body = try JSONDecoder().decode(J.self, from: bytes)
                XCTAssertEqual(body["function"].string, asset.method)
                XCTAssertEqual(body["type_arguments"], .array([]))
                return (.array(symbol == "USDT" ? [.bool(false), .bool(true)] : [.bool(true)]), 200)
            }
            let result = await StablecoinRestrictionCheck(endpoints: ["aptos": endpoint], transport: transport)
                .check(.init(network: "aptos", address: "0x1"), tokens: [asset])
            XCTAssertEqual(result.first?.outcome, .restricted)
        }
    }
    func testAptosSendingAndReceivingFlagsAreBothChecked() throws {
        for flags in [[false, true], [true, false], [true, true]] {
            XCTAssertTrue(try StablecoinRestrictionCheck.aptosRestricted(.array(flags.map(J.bool)), symbol: "USDT"))
        }
        XCTAssertFalse(try StablecoinRestrictionCheck.aptosRestricted(.array([.bool(false), .bool(false)]), symbol: "USDT"))
        XCTAssertThrowsError(try StablecoinRestrictionCheck.aptosRestricted(.array([.bool(true)]), symbol: "USDT"))
        XCTAssertThrowsError(try StablecoinRestrictionCheck.aptosRestricted(.array([.bool(false), .null]), symbol: "USDT"))
    }
    func testTRONConstantReadsRequireSuccessAndExactABIResult() async throws {
        for symbol in ["USDT", "USDC"] {
            let asset = token("tron", symbol)
            for valid in [true, false] {
                let transport = RestrictionFixtureTransport { request in
                    if request.url?.lastPathComponent == "getblockbynum" {
                        return (.object(["blockID": .string(TronSendNetwork.mainnet.genesisID)]), 200)
                    }
                    let body = try JSONDecoder().decode(J.self, from: request.httpBody!)
                    XCTAssertEqual(body["contract_address"].string, asset.reference)
                    XCTAssertEqual(body["function_selector"].string, asset.method)
                    XCTAssertEqual(body["parameter"].string?.count, 64)
                    return (.object(["result": .object(["result": .bool(valid)]),
                                     "constant_result": .array([.string(String(repeating: "0", count: 63) + "1")])]), 200)
                }
                let result = await StablecoinRestrictionCheck(endpoints: ["tron": endpoint], transport: transport)
                    .check(.init(network: "tron", address: asset.reference), tokens: [asset])
                XCTAssertEqual(result.first?.outcome, valid ? .restricted : .unavailable)
            }
        }
    }
    func testXRPLChecksPeerFreezeAndIssuerGlobalFreezeNotHolderFlag() async {
        let asset = token("xrpl", "USDC")
        let address = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
        for (peer, deepPeer, global, matchingCurrency, expected) in [
            (false, false, false, true, false), (true, false, false, true, true),
            (false, true, false, true, true), (false, false, true, true, true),
            (true, true, true, false, false)
        ] {
            let transport = RestrictionFixtureTransport { request in
                let body = try JSONDecoder().decode(J.self, from: request.httpBody!)
                let params = body["params"].array![0]
                var result: [String: J] = ["status": .string("success"), "validated": .bool(true), "ledger_index": .number("10")]
                switch body["method"].string {
                case "server_info":
                    result["info"] = .object(["network_id": .number("0")])
                case "account_info":
                    result["account_data"] = .object(["Account": params["account"],
                        "Flags": .number(global && params["account"].string == asset.reference ? "4194304" : "0")])
                case "account_lines":
                    XCTAssertEqual(params["peer"].string, asset.reference)
                    XCTAssertEqual(params["ledger_index"].integer, 10)
                    result["account"] = .string(address)
                    result["lines"] = .array([.object([
                        "account": .string(asset.reference), "currency": .string(matchingCurrency ? asset.method : "USD"),
                        "freeze": .bool(true), "freeze_peer": .bool(peer), "deep_freeze_peer": .bool(deepPeer)])])
                default: XCTFail("Unexpected RPC method")
                }
                return (.object(["result": .object(result)]), 200)
            }
            let results = await StablecoinRestrictionCheck(endpoints: ["xrpl": endpoint], transport: transport)
                .check(.init(network: "xrpl", address: address), tokens: [asset])
            XCTAssertEqual(results.first?.outcome, expected ? .restricted : .notDetected)
        }
    }
    func testClioUnfundedHolderDoesNotBecomeFailedRestrictionCheck() async {
        let asset = token("xrpl", "USDC")
        let address = "rh58Qu1geRrc8ieM7DhMbyxou8jgbHtxM7" // Public hash-derived absence fixture; no private key.
        for issuerMissing in [false, true] {
            let transport = RestrictionFixtureTransport { request in
                let call = try JSONDecoder().decode(J.self, from: request.httpBody!)
                if call["method"].string == "server_info" {
                    return (.object(["result": .object(["status": .string("success"), "info": .object(["network_id": .number("0")])])]), 200)
                }
                let params = call["params"].array![0]
                if issuerMissing && params["account"].string == address {
                    return (.object(["result": .object(["status": .string("success"), "validated": .bool(true),
                        "ledger_index": .number("10"), "account_data": .object(["Account": .string(address)])])]), 200)
                }
                return (.object(["result": .object(["error": .string("actNotFound"), "error_code": .number("19"),
                    "status": .string("error"), "type": .string("response"), "request": call]),
                    "warnings": .array([.object(["id": .number("2001")])])]), 200)
            }
            let checker = StablecoinRestrictionCheck(endpoints: ["xrpl": URL(string: "https://s1.ripple.com:51234")!], transport: transport)
            let results = await checker.check(.init(network: "xrpl", address: address), tokens: [asset])
            XCTAssertEqual(results.first?.outcome, issuerMissing ? .unavailable : .notDetected)
            let requests = await transport.count
            XCTAssertEqual(requests, issuerMissing ? 3 : 2)
        }
    }

    func testRPCStringIDIsAcceptedButMismatchedIDIsUnavailable() async {
        for id in ["1", "2"] {
            let transport = RestrictionFixtureTransport { request in
                let body = try JSONDecoder().decode(J.self, from: request.httpBody!)
                let result: J = body["method"].string == "eth_chainId" ? .string("0x1") : self.word(true)
                return (.object(["jsonrpc": .string("2.0"), "id": .string(id), "result": result]), 200)
            }
            let results = await StablecoinRestrictionCheck(endpoints: ["ethereum": endpoint], transport: transport)
                .check(.init(network: "ethereum", address: owner), tokens: [token("ethereum", "USDT")])
            XCTAssertEqual(results.first?.outcome, id == "1" ? .restricted : .unavailable)
        }
    }
}

private struct RestrictionHTTPFailureFixture: AnkrTransport {
    let status: Int
    var body = Data("<html>Access denied</html>".utf8)
    func send(_ request: URLRequest) async throws -> (Data,Int) { (body,status) }
}

private actor RestrictionFixtureTransport: AnkrTransport {
    private let handler: @MainActor @Sendable (URLRequest) throws -> (SolanaJSON, Int)
    private(set) var count = 0
    init(_ handler: @escaping @MainActor @Sendable (URLRequest) throws -> (SolanaJSON, Int)) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        count += 1
        let (json, status) = try await handler(request)
        return (try JSONEncoder().encode(json), status)
    }
}
