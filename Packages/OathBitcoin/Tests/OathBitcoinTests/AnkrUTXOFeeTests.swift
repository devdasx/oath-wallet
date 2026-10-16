import Foundation
import XCTest
import OathDiagnostics
@testable import OathBitcoin

final class AnkrUTXOFeeTests: XCTestCase, @unchecked Sendable {
    func testRequestIsReadOnlyBitcoinRPCAndNeverEnabledForUnverifiedChains() throws {
        let api = try XCTUnwrap(AnkrUTXOFeeAPI(apiKey: "testCredential123"))
        XCTAssertEqual(api.request.url?.host, "rpc.ankr.com")
        XCTAssertEqual(api.request.url?.pathComponents.dropLast().last, "btc")
        XCTAssertEqual(api.request.httpMethod, "POST")
        XCTAssertEqual(api.request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertLessThanOrEqual(api.request.timeoutInterval, 3)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(api.request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["method"] as? String, "estimatesmartfee")
        XCTAssertEqual(body["id"] as? Int, 1)
        let params = try XCTUnwrap(body["params"] as? [Any])
        XCTAssertEqual(params.count, 2)
        XCTAssertEqual(params[0] as? Int, 3)
        XCTAssertEqual(params[1] as? String, "CONSERVATIVE")
        for network in UTXONetwork.allCases {
            XCTAssertEqual(api.source(for: network) != nil, network == .bitcoin)
        }
        for key in [nil, "", " ", "key/other", "key?other"] {
            XCTAssertNil(AnkrUTXOFeeAPI(apiKey: key))
        }
        let context = DiagnosticHTTP.context(api.request)
        XCTAssertEqual(context, ["host": "rpc.ankr.com", "method": "estimatesmartfee"])
        XCTAssertFalse(context.description.contains("testCredential123"))
    }

    func testExactFeeUnitsCeilingAndRelayFloor() throws {
        for (rate, expected): (String, Int64) in [
            ("0.00001073", 1073), ("1.073e-5", 1073),
            ("0.000010730001", 1074), ("0.00000001", 1000),
            ("0.01", 1_000_000)
        ] {
            let data = Data("{\"id\":1,\"error\":null,\"result\":{\"feerate\":\(rate),\"blocks\":3}}".utf8)
            XCTAssertEqual(try AnkrUTXOFeeAPI.decode(data), expected)
        }
    }

    func testInvalidAndUncorrelatedResponsesNeverBecomeFees() {
        for json in [
            #"{"id":2,"result":{"feerate":0.00001,"blocks":3}}"#,
            #"{"id":1,"result":{"feerate":0,"blocks":3}}"#,
            #"{"id":1,"result":{"feerate":-1,"blocks":3}}"#,
            #"{"id":1,"result":{"feerate":1e25,"blocks":3}}"#,
            #"{"id":1,"result":{"feerate":0.01000001,"blocks":3}}"#,
            #"{"id":1,"result":{"feerate":0.00001,"blocks":0}}"#,
            #"{"id":1,"result":{"feerate":0.00001,"blocks":1009}}"#,
            #"{"id":1,"result":{"blocks":3}}"#,
            #"{"id":1,"result":null}"#,
            #"{"id":1,"result":{"feerate":true,"blocks":3}}"#,
            #"{"result":{"feerate":0.00001,"blocks":3}}"#,
            "[]", "<html>upstream unavailable</html>"
        ] { XCTAssertThrowsError(try AnkrUTXOFeeAPI.decode(Data(json.utf8))) }
        XCTAssertThrowsError(try AnkrUTXOFeeAPI.decode(Data(repeating: 32, count: 65_537)))
    }

    func testOriginalProviderErrorsReachTheSharedSourceBoundary() {
        let rpc = Data(#"{"id":1,"result":null,"error":{"code":-32601,"message":"Method not found"}}"#.utf8)
        XCTAssertThrowsError(try AnkrUTXOFeeAPI.decode(rpc)) { error in
            XCTAssertEqual((error as NSError).code, -32601)
            XCTAssertEqual(error.localizedDescription, "Method not found")
        }
        let estimate = Data(#"{"id":1,"error":null,"result":{"blocks":3,"errors":["Insufficient data"]}}"#.utf8)
        XCTAssertThrowsError(try AnkrUTXOFeeAPI.decode(estimate)) { error in
            XCTAssertEqual(error.localizedDescription, "Insufficient data")
        }
    }

    func testCredentialEchoInProviderErrorIsFilteredBeforePersistence() throws {
        let credential = String(repeating: "a", count: 64)
        let api = try XCTUnwrap(AnkrUTXOFeeAPI(apiKey: credential))
        let message = "Access denied at https://rpc.ankr.com/btc/" + credential
        let data = try JSONSerialization.data(withJSONObject: ["id": 1, "result": NSNull(),
            "error": ["code": -32000, "message": message]])
        do { _ = try AnkrUTXOFeeAPI.decode(data); XCTFail("Accepted a provider error") }
        catch {
            let event = DiagnosticEvent(error: error, component: "send", operation: "fee_source",
                context: DiagnosticHTTP.context(api.request), sessionID: UUID())
            let stored = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
            XCTAssertFalse(stored.contains(credential))
            XCTAssertFalse(stored.contains("https://rpc.ankr.com/btc/"))
            XCTAssertTrue(stored.contains("Access denied"))
            XCTAssertTrue(stored.contains("-32000"))
        }
    }

    func testLiveConfiguredAnkrAndAllChainFallbacks() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OATH_ANKR_FEES_LIVE"] == "1",
              let path = environment["OATH_RPC_CONFIGURATION_PATH"] else {
            throw XCTSkip("Opt-in read-only mainnet fee lookup; no wallet data or transaction submission")
        }
        let config = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let key = try XCTUnwrap(config["AnkrAPIKey"])
        let api = try XCTUnwrap(AnkrUTXOFeeAPI(apiKey: key))
        let source = try XCTUnwrap(api.source(for: .bitcoin))
        // Execute the actual transport and decoder twice, independently of any
        // fallback, so public API success cannot mask a broken ANKR integration.
        for round in 1...2 {
            let start = ContinuousClock.now
            do {
                let rate = try await source.load()
                XCTAssertTrue(UTXONetwork.bitcoin.sendFeeRates.contains(rate))
                print("LIVE ANKR Bitcoin round=\(round) atomic/kVB=\(rate) duration=\(start.duration(to: .now))")
            } catch {
                // Never let XCTest echo a credential-bearing URL from URLError.
                XCTFail("ANKR fee lookup failed; error type: \(type(of: error))")
            }
        }
        let provider = UTXOFeeProvider(ankrAPIKey: key)
        for chain in UTXONetwork.allCases {
            let start = ContinuousClock.now
            do {
                let rate = try await provider.rate(for: chain)
                XCTAssertTrue(chain.sendFeeRates.contains(rate))
                print("LIVE CONFIGURED FEE chain=\(chain.rawValue) atomic/kVB=\(rate) duration=\(start.duration(to: .now))")
                let cachedStart = ContinuousClock.now
                let cached = try await provider.rate(for: chain)
                XCTAssertEqual(cached, rate)
                XCTAssertLessThan(cachedStart.duration(to: .now), .milliseconds(100))
            } catch { XCTFail("Fee lookup failed for \(chain.rawValue); error type: \(type(of: error))") }
        }
    }
}
