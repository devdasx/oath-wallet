import Foundation
import XCTest
import OathDiagnostics
@testable import OathBitcoin

final class AlchemyUTXOTests: XCTestCase, @unchecked Sendable {
    private func fixtureSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AlchemyReplyProtocol.self]
        return URLSession(configuration: config)
    }
    private func feeJSON(_ rate: String, _ chain: UTXONetwork) -> Data {
        let result = chain == .bitcoincash ? rate : "{\"feerate\":\(rate),\"blocks\":3}"
        return Data("{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":\(result)}".utf8)
    }
    func testAllFourMainnetRoutesAndExactRPCParameters() throws {
        let api = try XCTUnwrap(AlchemyUTXOAPI(apiKey: "alch_fixture-only_123"))
        for chain in UTXONetwork.allCases {
            let fee = try api.feeRequest(chain)
            XCTAssertEqual(fee.url?.host, "\(chain.rawValue)-mainnet.g.alchemy.com")
            XCTAssertEqual(fee.url?.scheme, "https"); XCTAssertEqual(fee.httpMethod, "POST")
            XCTAssertEqual(fee.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertLessThanOrEqual(fee.timeoutInterval, 3)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(fee.httpBody)) as? [String: Any])
            XCTAssertEqual(body["id"] as? Int, 1)
            XCTAssertEqual(body["params"] as? [Int], chain == .bitcoincash ? [] : [3])
            XCTAssertEqual(body["method"] as? String, chain == .bitcoincash ? "estimatefee" : "estimatesmartfee")
            let post = try api.broadcastRequest(chain, hex: "abcdef")
            let posted = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(post.httpBody)) as? [String: Any])
            XCTAssertEqual(posted["method"] as? String, "sendrawtransaction")
            XCTAssertEqual(posted["params"] as? [String], ["abcdef"])
            XCTAssertFalse(post.url!.absoluteString.contains("abcdef"))
            let read = try api.lookupRequest(chain, txid: String(repeating: "a", count: 64))
            XCTAssertEqual(DiagnosticHTTP.context(read), ["host": AlchemyUTXOAPI.host(chain), "method": "getrawtransaction"])
        }
        for key in [nil, "", "key/extra", "key?query", "key#fragment", "key with spaces", String(repeating: "a", count: 257)] {
            XCTAssertNil(AlchemyUTXOAPI(apiKey: key))
        }
    }
    func testFeesUseExactDecimalUnitsAndRelayFloorForEveryChain() throws {
        for chain in UTXONetwork.allCases {
            for (rate, atomic): (String, Int64) in [("1.074e-5", 1074), ("0.000010740001", 1075), ("0.00000995", 995)] {
                XCTAssertEqual(try AlchemyUTXOAPI.decodeFee(feeJSON(rate, chain), network: chain), max(chain.sendFeeRates.lowerBound, atomic))
            }
            for rate in ["-1", "0", "true", "null", "1e30", "\"0.00001\""] {
                XCTAssertThrowsError(try AlchemyUTXOAPI.decodeFee(feeJSON(rate, chain), network: chain))
            }
        }
        XCTAssertEqual(try AlchemyUTXOAPI.decodeFee(feeJSON("0.53294152", .dogecoin), network: .dogecoin), 53_294_152)
        XCTAssertThrowsError(try AlchemyUTXOAPI.decodeFee(feeJSON("0.53294152", .bitcoin), network: .bitcoin))
    }
    func testMalformedWrongChainAndUncorrelatedFeeEnvelopesAreRejected() {
        for chain in UTXONetwork.allCases {
            let valid = String(decoding: feeJSON("0.00001", chain), as: UTF8.self)
            for json in [valid.replacingOccurrences(of: "\"id\":1", with: "\"id\":2"),
                         valid.replacingOccurrences(of: "\"id\":1", with: "\"id\":true"),
                         valid.replacingOccurrences(of: "\"2.0\"", with: "\"3.0\""),
                         #"{"id":1,"result":null}"#, "[]", "<html>outage</html>",
                         #"{"id":1,"result":{"blocks":0,"feerate":0.00001}}"#,
                         #"{"id":1,"result":{"blocks":1009,"feerate":0.00001}}"#,
                         #"{"id":1,"result":{"blocks":3,"errors":["No estimate"]}}"#] {
                XCTAssertThrowsError(try AlchemyUTXOAPI.decodeFee(Data(json.utf8), network: chain))
            }
            XCTAssertThrowsError(try AlchemyUTXOAPI.decodeFee(Data(repeating: 32, count: 65_537), network: chain))
        }
        XCTAssertThrowsError(try AlchemyUTXOAPI.decodeFee(feeJSON("0.00001", .bitcoin), network: .bitcoincash))
        XCTAssertThrowsError(try AlchemyUTXOAPI.decodeFee(feeJSON("0.00001", .bitcoincash), network: .bitcoin))
    }
    func testBroadcastAndLookupStrictlyDecodeSuccessAndExpectedAbsence() throws {
        let txid = String(repeating: "a", count: 64)
        XCTAssertEqual(try AlchemyUTXOAPI.decodeBroadcast(Data("{\"id\":1,\"result\":\"\(txid.uppercased())\"}".utf8)), txid)
        XCTAssertEqual(try AlchemyUTXOAPI.decodeRaw(Data(#"{"id":1,"result":"0102"}"#.utf8)), Data([1, 2]))
        XCTAssertNil(try AlchemyUTXOAPI.decodeRaw(Data(#"{"id":1,"error":{"code":-5,"message":"No such mempool transaction"}}"#.utf8)))
        for json in [#"{"id":1,"result":true}"#, #"{"id":1,"result":null}"#,
                     #"{"id":2,"result":"0102"}"#, #"{"id":1,"result":"0g"}"#,
                     #"{"id":1,"result":""}"#, #"{"id":1,"result":"010"}"#,
                     #"{"id":1,"error":{"code":-27,"message":"already in block chain"}}"#,
                     #"{"id":1,"error":{"code":-32001,"message":"Unable to complete request at this time."}}"#] {
            XCTAssertThrowsError(try AlchemyUTXOAPI.decodeBroadcast(Data(json.utf8)))
            XCTAssertThrowsError(try AlchemyUTXOAPI.decodeRaw(Data(json.utf8)))
        }
    }
    func testProviderCodesSurviveWhileCredentialAndTransactionEchoesAreRedacted() throws {
        let key = "alch_fixture-key_123", raw = String(repeating: "01020304", count: 100)
        let data = try JSONSerialization.data(withJSONObject: ["id": 1, "error": ["code": -32001,
            "message": "Unavailable \(key) https://bitcoincash-mainnet.g.alchemy.com/v2/\(key) \(raw)"]])
        do { _ = try AlchemyUTXOAPI.decodeBroadcast(data); XCTFail("Error accepted") }
        catch {
            let event = DiagnosticEvent(error: error, component: "send", operation: "broadcast_api", sessionID: UUID())
            let stored = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
            XCTAssertFalse(stored.contains(key)); XCTAssertFalse(stored.contains(raw))
            XCTAssertFalse(stored.contains("/v2/")); XCTAssertTrue(stored.contains("-32001"))
        }
    }
    func testActualAdapterTransportForAllFourChains() async throws {
        let session = fixtureSession(); defer { session.invalidateAndCancel() }
        let api = try XCTUnwrap(AlchemyUTXOAPI(apiKey: "fixture", session: session, budget: UTXOAPIBudget()))
        for chain in UTXONetwork.allCases {
            let rate = try await api.feeSource(chain).load()
            XCTAssertEqual(rate, chain == .dogecoin ? 53_294_152 : 1074)
            let source = api.broadcastSource(chain)
            let txid = try await source.submit("0102")
            XCTAssertEqual(txid, String(repeating: "a", count: 64))
            let raw = try await source.lookup(txid)
            XCTAssertEqual(raw, Data([1, 2]))
        }
    }
    func testBothHTTPAndRPC429BackOffAllAlchemyChainsButKeepOtherProvidersAvailable() async throws {
        let session = fixtureSession(); defer { session.invalidateAndCancel() }
        for mode in ["httpLimited", "rpcLimited"] {
            let budget = UTXOAPIBudget()
            let api = try XCTUnwrap(AlchemyUTXOAPI(apiKey: mode, session: session, budget: budget))
            do { _ = try await api.feeSource(.bitcoin).load(); XCTFail("Rate limit accepted") } catch { }
            for chain in UTXONetwork.allCases {
                do { try await budget.acquire(AlchemyUTXOAPI.host(chain)); XCTFail("Cooldown bypassed") }
                catch is UTXOAPIBudget.Deferred { }
            }
            try await budget.acquire("mempool.space"); await budget.release("mempool.space")
        }
    }
    func testExpectedPropagationAbsenceAndHTTP503NeverBecomeAcceptance() async throws {
        let session = fixtureSession(); defer { session.invalidateAndCancel() }
        for mode in ["missing", "outage"] {
            let api = try XCTUnwrap(AlchemyUTXOAPI(apiKey: mode, session: session, budget: UTXOAPIBudget()))
            let source = api.broadcastSource(.bitcoincash)
            do { _ = try await source.submit("0102"); XCTFail("Failure became acceptance") } catch { }
            if mode == "missing" {
                let value = try await source.lookup(String(repeating: "a", count: 64)); XCTAssertNil(value)
            } else {
                do { _ = try await source.lookup(String(repeating: "a", count: 64)); XCTFail("Outage became absence") } catch { }
            }
        }
    }
    func testSharedAlchemyBudgetSpacesStartsAcrossDifferentChains() async throws {
        let budget = UTXOAPIBudget(), start = ContinuousClock.now
        for chain in UTXONetwork.allCases {
            try await budget.acquire(AlchemyUTXOAPI.host(chain))
            await budget.release(AlchemyUTXOAPI.host(chain))
        }
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(290))
    }

    func testLiveConfiguredAlchemyFeesAndCacheOnAllChains() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OATH_ALCHEMY_LIVE"] == "1", let path = environment["OATH_RPC_CONFIGURATION_PATH"] else {
            throw XCTSkip("Opt-in live fee API test; no wallet data")
        }
        let config = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let api = try XCTUnwrap(AlchemyUTXOAPI(apiKey: config["AlchemyAPIKey"]))
        // No fallback in this test: a healthy public provider cannot conceal an
        // Alchemy failure. Exercise the real fee provider, cache and transport.
        let provider = UTXOFeeProvider(preferredDeadline: .milliseconds(1250), preferred: { api.feeSource($0) }, sources: { _ in [] })
        for chain in UTXONetwork.allCases {
            let start = ContinuousClock.now
            do {
                let rate = try await provider.rate(for: chain)
                XCTAssertTrue(chain.sendFeeRates.contains(rate))
                print("LIVE ALCHEMY FEE chain=\(chain.rawValue) atomic/kB=\(rate) duration=\(start.duration(to: .now))")
                let cachedStart = ContinuousClock.now, cached = try await provider.rate(for: chain)
                XCTAssertEqual(cached, rate); XCTAssertLessThan(cachedStart.duration(to: .now), .milliseconds(100))
            } catch { XCTFail("Alchemy fee failed for \(chain.rawValue); type=\(type(of: error))") }
        }
    }
    func testLiveBroadcastProbeUsesOnlyImpossibleSyntheticSpend() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OATH_ALCHEMY_LIVE"] == "1", let path = environment["OATH_RPC_CONFIGURATION_PATH"] else {
            throw XCTSkip("Opt-in rejection probe only; no valid transaction or user funds")
        }
        let config = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let api = try XCTUnwrap(AlchemyUTXOAPI(apiKey: config["AlchemyAPIKey"]))
        let raw = "0100000001" + String(repeating: "11", count: 32) + "0000000000ffffffff010100000000000000015100000000"
        for chain in UTXONetwork.allCases {
            let start = ContinuousClock.now
            do { _ = try await api.broadcastSource(chain).submit(raw); XCTFail("Invalid synthetic spend unexpectedly accepted") }
            catch {
                // Code/type only: XCTest must not echo credential-bearing URLs.
                let status: String
                if case UTXOAPIProvider.APIError.http(let code) = error { status = "http=\(code)" }
                else if (error as NSError).domain == "Oath.Alchemy" { status = "rpc=\((error as NSError).code)" }
                else { XCTFail("Probe did not reach a conclusive API response for \(chain.rawValue)"); continue }
                print("LIVE ALCHEMY BROADCAST REJECTION chain=\(chain.rawValue) \(status) duration=\(start.duration(to: .now)); acceptance UNVERIFIED")
            }
        }
    }
}

private final class AlchemyReplyProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // URLSession can replace httpBody with a stream before URLProtocol.
        var call = request
        if call.httpBody == nil, let stream = call.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while data.count < 4096 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            call.httpBody = data
        }
        let method = DiagnosticHTTP.context(call)["method"], mode = request.url!.lastPathComponent
        var status = 200, reply: String
        switch mode {
        case "httpLimited", "rpcLimited":
            status = mode == "httpLimited" ? 429 : 200
            reply = #"{"id":1,"error":{"code":429,"message":"Rate limited"}}"#
        case "outage":
            status = 503; reply = #"{"id":1,"error":{"code":-32001,"message":"Unable to complete request at this time."}}"#
        case "missing": reply = #"{"id":1,"error":{"code":-5,"message":"No such mempool transaction"}}"#
        default:
            switch method {
            case "estimatefee": reply = #"{"id":1,"result":0.00001074}"#
            case "estimatesmartfee":
                let rate = request.url?.host?.hasPrefix("dogecoin-") == true ? "0.53294152" : "0.00001074"
                reply = "{\"id\":1,\"result\":{\"feerate\":\(rate),\"blocks\":3}}"
            case "sendrawtransaction": reply = "{\"id\":1,\"result\":\"\(String(repeating: "a", count: 64))\"}"
            default: reply = #"{"id":1,"result":"0102"}"#
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Retry-After": "60"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
