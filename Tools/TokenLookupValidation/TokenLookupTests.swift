import XCTest
import OathDiagnostics
@testable import TokenLookup

private actor Capture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

private struct AbsentOrFailedLookup: OathTokenLookingUp {
    func lookup(address: String, network: OathTokenNetwork) async throws -> OathTokenDefinition {
        if network.chain == .base { throw OathTokenLookupError.unavailable }
        throw OathTokenLookupError.notToken
    }
}

@MainActor final class TokenLookupTests: XCTestCase {
    private let publicToken = "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    private let noToken = "0x0000000000000000000000000000000000000000"
    private func service(_ mode: String) -> OathTokenService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TokenRPCFixture.self]
        return OathTokenService(configuration: .init(ankrKey: mode), session: URLSession(configuration: configuration))
    }

    func testAbsenceIsQuietButRealFailureHasChainAndCorrelation() async throws {
        let capture = Capture(), folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        OathDiagnostics.configure(file: folder.appendingPathComponent("events.json"), transport: capture)
        let model = OathTokenSearchModel(service: AbsentOrFailedLookup())
        await model.search(noToken, available: [.ethereum, .base])
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.failedNetworks.map(\.chain), [.base])
        XCTAssertFalse(model.isSearching)
        let nonToken = OathTokenSearchModel(service: service("revertmetadata"))
        await nonToken.search(publicToken, available: [.ethereum])
        XCTAssertTrue(nonToken.results.isEmpty)
        XCTAssertTrue(nonToken.failedNetworks.isEmpty)
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.error.message == "unavailable" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let events = await capture.events
        XCTAssertFalse(events.contains { $0.error.message == "notToken" })
        XCTAssertEqual(events.count, 1, "Exact optional metadata reverts must not generate provider failures")
        let failed = try XCTUnwrap(events.first { $0.error.message == "unavailable" })
        XCTAssertEqual(failed.context["chain"], "base")
        XCTAssertNotNil(failed.operationID)
        XCTAssertFalse(String(describing: events).contains(noToken))
        let failure = OathTokenSearchModel(service: service("wrongerrorcode"))
        await failure.search(publicToken, available: [.ethereum])
        XCTAssertEqual(failure.failedNetworks.map(\.chain), [.ethereum])
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.error.domain == "Oath.Provider" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let genuine = await capture.events.filter { $0.error.domain == "Oath.Provider" }
        XCTAssertFalse(genuine.isEmpty, "Original provider failure must survive domain conversion")
        for event in genuine {
            XCTAssertEqual(event.context["rpc_code"], "-32005")
            // HTTP context uses ANKR's provider chain name; the model boundary
            // above uses the app's canonical name. Both must remain scoped.
            XCTAssertEqual(event.context["chain"], "eth")
            XCTAssertNotNil(event.operationID)
        }
        XCTAssertFalse(String(describing: genuine).lowercased().contains(publicToken.lowercased()))
    }

    func testRevertDoesNotMeanAbsentTokenForNonMetadataRPC() async throws {
        let service = service("revert"), endpoint = URL(string: "https://fixture.invalid/revert")!
        for method in ["eth_chainId", "eth_getCode", "eth_estimateGas"] {
            do { _ = try await service.call(endpoint, method: method); XCTFail("Unexpected RPC success") }
            catch { XCTAssertEqual(error as? OathTokenLookupError, .unavailable) }
        }
    }

    func testOnlyValidMetadataRevertMeansNotToken() async throws {
        let network = try XCTUnwrap(OathTokenNetwork.find(.ethereum))
        for mode in ["revertmetadata", "wrongerrorcode", "wrongreply", "resultanderror", "missingresult", "nullresult"] {
            do { _ = try await service(mode).lookup(address: publicToken, network: network); XCTFail("Invalid metadata accepted") }
            catch {
                let expected: OathTokenLookupError = mode == "revertmetadata" ? .notToken
                    : mode == "wrongerrorcode" ? .unavailable : .malformedResponse
                XCTAssertEqual(error as? OathTokenLookupError, expected, mode)
            }
        }
    }

    func testNoCodeAndValidTokenRemainDistinct() async throws {
        let network = try XCTUnwrap(OathTokenNetwork.find(.ethereum))
        do { _ = try await service("nocode").lookup(address: noToken, network: network); XCTFail("Empty code accepted") }
        catch { XCTAssertEqual(error as? OathTokenLookupError, .notToken) }
        let token = try await service("valid").lookup(address: publicToken, network: network)
        XCTAssertEqual(token.name, "Test Token")
        XCTAssertEqual(token.symbol, "TST")
        XCTAssertEqual(token.decimals, 6)
    }

    func testLiveMetadataAbsenceAndNonTokenContract() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_TOKEN_LOOKUP_LIVE_KEY"] else {
            throw XCTSkip("Opt-in public token RPC check")
        }
        let service = OathTokenService(configuration: .init(ankrKey: key))
        for (chain, address, name, symbol, decimals) in [
            (OathImportChain.ethereum, publicToken, "USD Coin", "USDC", 6),
            (.base, "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", "USD Coin", "USDC", 6),
            (.bnb, "0x55d398326f99059fF775485246999027B3197955", "Tether USD", "USDT", 18),
            (.optimism, "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85", "USD Coin", "USDC", 6)
        ] {
            let network = try XCTUnwrap(OathTokenNetwork.find(chain))
            let token = try await service.lookup(address: address, network: network)
            XCTAssertEqual(token.name, name); XCTAssertEqual(token.symbol, symbol); XCTAssertEqual(token.decimals, decimals)
            for absent in [noToken, "0x000000000022D473030F116dDEE9F6B43aC78BA3"] {
                do { _ = try await service.lookup(address: absent, network: network); XCTFail("Non-token accepted") }
                catch { XCTAssertEqual(error as? OathTokenLookupError, .notToken) }
            }
            print("OATH_TOKEN_LOOKUP_LIVE: \(network.id) exact token metadata, empty account and Permit2 non-token contract verified")
        }
    }
}

private final class TokenRPCFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), bytes = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }; data.append(bytes, count: count)
            }
            body = data
        }
        let input = try! JSONSerialization.jsonObject(with: body!) as! [String: Any]
        let method = input["method"] as! String, mode = request.url!.lastPathComponent
        var result: Any = "0x1"
        if method == "eth_getCode" { result = mode == "nocode" ? "0x" : "0x6000" }
        if method == "eth_call" {
            let selector = ((input["params"] as? [Any])?.first as? [String: Any])?["data"] as? String
            if selector == "0x313ce567" { result = "0x" + String(repeating: "0", count: 63) + "6" }
            else if selector == "0x18160ddd" { result = "0x" + String(repeating: "0", count: 63) + "1" }
            else {
                let text = selector == "0x06fdde03" ? "Test Token" : "TST"
                result = "0x" + Data(text.utf8).map { String(format: "%02x", $0) }.joined() + String(repeating: "00", count: 32 - text.utf8.count)
            }
        }
        var output: [String: Any] = ["jsonrpc": "2.0", "id": input["id"]!, "result": result]
        if mode == "revert" || (method == "eth_call" && ["revertmetadata", "wrongerrorcode", "wrongreply", "resultanderror"].contains(mode)) {
            output["error"] = ["code": mode == "wrongerrorcode" ? -32005 : 3, "message": "execution reverted"]
            if mode != "resultanderror" { output.removeValue(forKey: "result") }
            if mode == "wrongreply" { output["id"] = "different-reply" }
        }
        if method == "eth_call", mode == "missingresult" { output.removeValue(forKey: "result") }
        if method == "eth_call", mode == "nullresult" { output["result"] = NSNull() }
        let data = try! JSONSerialization.data(withJSONObject: output)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
