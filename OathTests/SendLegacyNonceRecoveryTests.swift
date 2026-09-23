import Foundation
import Testing
@testable import Aperture

struct SendLegacyNonceRecoveryTests {
    @Test
    func readsExactTransactionNonceLosslessly() async throws {
        let client = try makeClient(.valid)
        #expect(try await client.transactionNonce(hash: hash, fromAddress: sender) == "9007199254740993")
    }

    @Test(arguments: [LegacyNonceFixture.wrongHash, .wrongSender, .wrongID, .missing, .badNonce, .rpcError, .httpError])
    fileprivate func rejectsMissingOrMismatchedTransactionEvidence(fixture: LegacyNonceFixture) async throws {
        let client = try makeClient(fixture)
        await #expect(throws: SendTransactionSubmissionError.self) {
            _ = try await client.transactionNonce(hash: hash, fromAddress: sender)
        }
    }

    private let hash = "0x" + String(repeating: "ab", count: 32)
    private let sender = "0x" + String(repeating: "12", count: 20)

    private func makeClient(_ fixture: LegacyNonceFixture) throws -> SendEVMRPCClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LegacyNonceURLProtocol.self]
        return try SendEVMRPCClient(networkID: "eth", session: URLSession(configuration: config),
                                    endpoints: [URL(string: "https://nonce-recovery.invalid/\(fixture.rawValue)")!])
    }
}

private enum LegacyNonceFixture: String, Sendable {
    case valid, wrongHash, wrongSender, wrongID, missing, badNonce, rpcError, httpError
}

private final class LegacyNonceURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "nonce-recovery.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let mode = LegacyNonceFixture(rawValue: request.url!.lastPathComponent)!
            let data: Data
            if let body = request.httpBody {
                data = body
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    bytes.append(buffer, count: count)
                }
                data = bytes
            } else {
                throw URLError(.badURL)
            }
            let requestJSON = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            guard requestJSON["method"] as? String == "eth_getTransactionByHash" else { throw URLError(.badURL) }
            let params = requestJSON["params"] as! [String]
            let expectedID = requestJSON["id"] as! Int
            var envelope: [String: Any] = ["jsonrpc": "2.0", "id": mode == .wrongID ? expectedID + 1 : expectedID]
            if mode == .rpcError {
                envelope["error"] = ["code": -32000, "message": "Fixture read failure"]
            } else if mode == .missing {
                envelope["result"] = NSNull()
            } else {
                envelope["result"] = [
                    "hash": mode == .wrongHash ? "0x" + String(repeating: "cd", count: 32) : params[0],
                    "from": "0x" + String(repeating: mode == .wrongSender ? "34" : "12", count: 20),
                    "nonce": mode == .badNonce ? "not-a-number" : "0x20000000000001"
                ]
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: mode == .httpError ? 503 : 200,
                                           httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: envelope))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

struct EVMPendingReconciliationRPCTests {
    @Test(arguments: ["missing", "present", "wrongHash", "outage"])
    func nullReceiptRequiresExactMempoolLookup(_ mode: String) async throws {
        let client = try rpc(mode)
        if mode == "wrongHash" || mode == "outage" {
            await #expect(throws: (any Error).self) { try await client.transactionStatus(hash: Self.hash) }
        } else {
            #expect(try await client.transactionStatus(hash: Self.hash) == (mode == "present" ? .pending : .notFound))
        }
    }

    @Test(arguments: ["match", "wrongSender", "wrongNonce", "wrongBlock", "original"])
    func nonceReplacementRequiresMinedSameSenderAndNonce(_ mode: String) async throws {
        let client = try rpc(mode)
        let replacement = try await client.confirmedReplacement(hash: Self.hash, sender: Self.sender, nonce: 17)
        #expect(replacement == (mode == "match" ? Self.other : nil))
    }

    static let hash = "0x" + String(repeating: "a", count: 64)
    static let other = "0x" + String(repeating: "b", count: 64)
    static let sender = "0x" + String(repeating: "1", count: 40)
    private func rpc(_ mode: String) throws -> SendEVMRPCClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EVMPendingRPCProtocol.self]
        return try SendEVMRPCClient(networkID: "eth", session: URLSession(configuration: config),
            endpoints: [URL(string: "https://pending-rpc.invalid/" + mode)!])
    }
}

private final class EVMPendingRPCProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pending-rpc.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
            }
            let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let method = body["method"] as! String
            let mode = request.url!.lastPathComponent
            let params = body["params"] as! [Any]
            var result: Any = NSNull()
            let blockHash = "0x" + String(repeating: "c", count: 64)
            switch method {
            case "eth_getTransactionReceipt": break
            case "eth_getTransactionByHash":
                if mode == "present" || mode == "wrongHash" {
                    result = ["hash": mode == "wrongHash" ? EVMPendingReconciliationRPCTests.other : EVMPendingReconciliationRPCTests.hash]
                }
            case "eth_blockNumber": result = "0x2"
            case "eth_getBlockByNumber":
                result = ["number": params[0], "hash": blockHash, "transactions": [[
                    "hash": mode == "original" ? EVMPendingReconciliationRPCTests.hash : EVMPendingReconciliationRPCTests.other,
                    "from": mode == "wrongSender" ? "0x" + String(repeating: "2", count: 40) : EVMPendingReconciliationRPCTests.sender,
                    "nonce": mode == "wrongNonce" ? "0x12" : "0x11",
                    "blockHash": mode == "wrongBlock" ? "0x" + String(repeating: "d", count: 64) : blockHash
                ]]]
            default: throw URLError(.badURL)
            }
            let envelope: [String: Any] = ["jsonrpc": "2.0", "id": body["id"]!, "result": result]
            let response = HTTPURLResponse(url: request.url!, statusCode: mode == "outage" ? 503 : 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: envelope))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
