import Foundation
import Testing
@testable import Aperture

@Suite(.timeLimit(.minutes(1)))
struct StablecoinBlacklistTransportTests {
    @Test(arguments: ["http429", "wrongchain"])
    func fallbackRevalidatesChainAndReturnsOnlyVerifiedBoolean(mode: String) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StablecoinFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let target = StablecoinBlacklistTarget(networkID: "eth", chainID: 1, symbol: "USDT",
            contract: StablecoinBlacklistTests.targets[0].contract, method: .tether,
            endpoint: "https://stablecoin.invalid/" + mode,
            fallbackEndpoints: ["https://stablecoin.invalid/false"])
        #expect(try await !StablecoinBlacklistClient(session: session).check(target: target, address: StablecoinBlacklistTests.address))
    }

    @Test(arguments: ["true", "false", "rpc", "empty", "wrongchain", "wrongid", "null", "http401", "http429", "malformed"])
    func validatesTransportChainAndExecution(mode: String) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StablecoinFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let target = StablecoinBlacklistTarget(networkID: "eth", chainID: 1, symbol: "USDT",
            contract: StablecoinBlacklistTests.targets[0].contract, method: .tether,
            endpoint: "https://stablecoin.invalid/" + mode)
        do {
            let result = try await StablecoinBlacklistClient(session: session)
                .check(target: target, address: StablecoinBlacklistTests.address)
            #expect(mode == "true" || mode == "false")
            #expect(result == (mode == "true"))
        } catch {
            #expect(mode != "true" && mode != "false")
            if mode == "wrongchain" { #expect(error as? StablecoinCheckError == .wrongChain) }
            if mode == "http429" { #expect(error as? StablecoinCheckError == .http(429)) }
            if mode == "rpc" { #expect(error as? StablecoinCheckError == .rpc(-32000, "execution reverted")) }
        }
    }
}

private final class StablecoinFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stablecoin.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.url!.lastPathComponent
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024), body = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
            }
            data = body
        }
        let object = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:]
        let method = object["method"] as? String
        let id = object["id"] as? Int ?? 0
        var response: [String: Any] = ["jsonrpc": "2.0", "id": mode == "wrongid" ? 999 : id]
        if method == "eth_chainId" {
            response["result"] = mode == "wrongchain" ? "0x38" : "0x1"
        } else {
            let params = object["params"] as? [Any]
            let call = params?.first as? [String: String]
            #expect(call?["data"] == "0xe47d6060" + String(repeating: "0", count: 60) + "dead")
            #expect(params?.last as? String == "latest")
            switch mode {
            case "rpc": response["error"] = ["code": -32000, "message": "execution reverted"]
            case "empty": response["result"] = "0x"
            case "null": response["result"] = NSNull()
            default: response["result"] = "0x" + String(repeating: "0", count: 63) + (mode == "true" ? "1" : "0")
            }
        }
        let status = mode == "http401" ? 401 : mode == "http429" ? 429 : 200
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        let body = mode == "malformed" ? Data("not JSON".utf8) : (try! JSONSerialization.data(withJSONObject: response))
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
