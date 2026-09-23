import Foundation
import Testing
@testable import Aperture

struct SolanaRPCBatchBudgetTests {
    @Test
    func budgetsEncodedUTF8BytesAndMethodCount() async throws {
        let recorder = SolanaBudgetTestExecutor(shape: .none)
        let endpoint = URL(string: "https://bytes-\(UUID().uuidString).example")!
        let transport = SolanaRPCTransport(endpoints: [endpoint]) { try await recorder.send($0) }
        let text = String(repeating: "العنوان\"\\", count: 100)
        let requests = (1...200).map {
            SolanaRPCRequest(method: "getBalance", params: [.string(text)], id: $0)
        }
        let responses = try await transport.batch(requests)
        #expect(responses.map(\.id) == requests.map(\.id))
        #expect(await recorder.take().allSatisfy { $0.count <= 50 })
        #expect(await recorder.bytes().allSatisfy { $0 <= 24 * 1_024 })
    }

    @Test(arguments: [SolanaSizeRejection.http, .whole, .items])
    func remembersHTTPWholeRPCAndPerItemLimits(shape: SolanaSizeRejection) async throws {
        let recorder = SolanaBudgetTestExecutor(shape: shape)
        let endpoint = URL(string: "https://solana-budget-\(UUID().uuidString).example")!
        let transport = SolanaRPCTransport(endpoints: [endpoint]) { try await recorder.send($0) }
        let requests = (1...16).map { SolanaRPCRequest(method: "getBalance", params: [.string("owner-\($0)")], id: $0) }
        let first = try await transport.batch(requests)
        #expect(first.map(\.id) == requests.map(\.id))
        let initial = await recorder.take()
        #expect(initial.contains { $0.count > 4 })
        let second = try await transport.batch(requests)
        #expect(second.count == 16)
        #expect(await recorder.take().allSatisfy { $0.count <= 4 })
    }

    @Test
    func partialFallbackOnlyRequestsFailedSiblings() async throws {
        let testID = UUID().uuidString
        let first = URL(string: "https://partial-\(testID).example")!
        let second = URL(string: "https://recovery-\(testID).example")!
        let seen = SolanaBudgetTestExecutor(shape: .none)
        let transport = SolanaRPCTransport(endpoints: [first, second]) { request in
            let ids = try SolanaBudgetTestExecutor.ids(request)
            await seen.record(ids)
            let values: [[String: Any]] = ids.map { id in
                if request.url == first && id == 2 {
                    return ["id": id, "error": ["code": 429, "message": "Too many requests"]]
                }
                return ["id": id, "result": ["value": id]]
            }
            return (try JSONSerialization.data(withJSONObject: values), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let responses = try await transport.batch((1...3).map { .init(method: "getBalance", params: [], id: $0) })
        #expect(responses.map(\.id) == [1, 2, 3])
        #expect(await seen.take() == [[1, 2, 3], [2]])
    }

    @Test
    func partialSizeRejectionDoesNotResendSuccessfulItems() async throws {
        let recorder = SolanaBudgetTestExecutor(shape: .mixed)
        let endpoint = URL(string: "https://mixed-\(UUID().uuidString).example")!
        let transport = SolanaRPCTransport(endpoints: [endpoint]) { try await recorder.send($0) }
        let responses = try await transport.batch((1...8).map { .init(method: "getBalance", params: [], id: $0) })
        #expect(responses.count == 8)
        let waves = await recorder.take()
        #expect(waves.flatMap { $0 }.filter { $0 == 1 }.count == 1)
    }

    @Test
    func sizeErrorDoesNotCancelHealthyHedgeAndThirdEndpointIsNotAlwaysCalled() async throws {
        let testID = UUID().uuidString
        let first = URL(string: "https://oversized-\(testID).example")!
        let second = URL(string: "https://healthy-\(testID).example")!
        let unused = URL(string: "https://unused-\(testID).example")!
        let hosts = SolanaBudgetHostRecorder()
        let transport = SolanaRPCTransport(endpoints: [first, second, unused]) { request in
            await hosts.record(request.url!.host!)
            if request.url == first {
                return (Data(#"{"error":{"code":-32062,"message":"Request is too large"},"id":null}"#.utf8), HTTPURLResponse(url: first, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(#"[{"id":1,"result":{"value":42}}]"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(try await transport.batchBalance([.init(method: "getBalance", params: [], id: 1)]).count == 1)
        #expect(await hosts.count(first.host!) == 1)
        // The remaining provider may replace a failed attempt; a normal healthy
        // wave below proves it is not launched unconditionally.
        let cleanID = UUID().uuidString
        let endpoints = (1...3).map { URL(string: "https://normal-\($0)-\(cleanID).example")! }
        let clean = SolanaRPCTransport(endpoints: endpoints) { request in
            await hosts.record(request.url!.host!)
            return (Data(#"[{"id":1,"result":{"value":42}}]"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await clean.batchBalance([.init(method: "getBalance", params: [], id: 1)])
        #expect(await hosts.count(endpoints[2].host!) == 0)
    }

    @Test(arguments: ["duplicate", "foreign", "missing", "neither", "both"])
    func malformedIDsAndAmbiguousResultsCannotBecomeBalances(fault: String) async throws {
        let endpoint = URL(string: "https://invalid-\(UUID().uuidString).example")!
        let transport = SolanaRPCTransport(endpoints: [endpoint]) { _ in
            let data: String
            switch fault {
            case "duplicate": data = #"[{"id":1,"result":0},{"id":1,"result":0}]"#
            case "foreign": data = #"[{"id":1,"result":0},{"id":3,"result":0}]"#
            case "missing": data = #"[{"id":1,"result":0}]"#
            case "both": data = #"[{"id":1,"result":0,"error":{"code":42,"message":"error"}},{"id":2,"result":0}]"#
            default: data = #"[{"id":1},{"id":2,"result":0}]"#
            }
            return (Data(data.utf8), HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: (any Error).self) {
            try await transport.batch([.init(method: "getBalance", params: [], id: 1), .init(method: "getBalance", params: [], id: 2)])
        }
    }

    @Test
    func validNullResultIsNotMistakenForMissingPayload() async throws {
        let response = try JSONDecoder().decode(SolanaRPCResponse.self, from: Data(#"{"id":1,"result":null}"#.utf8))
        guard case .null = response.result else { Issue.record("Null RPC result was lost"); return }
    }

    @Test
    func errorWithNullResultPreservesTheProviderCause() async throws {
        let endpoint = URL(string: "https://rpc-error-\(UUID().uuidString).example")!
        let transport = SolanaRPCTransport(endpoints: [endpoint]) { _ in
            (Data(#"[{"id":1,"result":null,"error":{"code":-32602,"message":"Invalid owner address"}}]"#.utf8),
             HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await transport.batch([.init(method: "getBalance", params: [], id: 1)])
            Issue.record("Expected the original RPC error")
        } catch let AnkrAPIError.rpcFailure(code, message) {
            #expect(code == -32602)
            #expect(message == "Invalid owner address")
        }
    }
}

enum SolanaSizeRejection: CaseIterable, Sendable {
    case http, whole, items, mixed, none
}

private actor SolanaBudgetTestExecutor {
    let shape: SolanaSizeRejection
    private var calls: [[Int]] = []
    private var payloadBytes: [Int] = []
    init(shape: SolanaSizeRejection) { self.shape = shape }
    func record(_ ids: [Int]) { calls.append(ids) }
    func take() -> [[Int]] { defer { calls = [] }; return calls }
    func bytes() -> [Int] { payloadBytes }

    nonisolated static func ids(_ request: URLRequest) throws -> [Int] {
        let calls = try JSONSerialization.jsonObject(with: request.httpBody!) as! [[String: Any]]
        return calls.map { $0["id"] as! Int }
    }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        let ids = try Self.ids(request)
        calls.append(ids)
        payloadBytes.append(request.httpBody!.count)
        let rejected = ids.count > 4 && shape != .none
        let error: [String: Any] = ["code": -32062, "message": "Request is too large"]
        let status = rejected && shape == .http ? 413 : 200
        let body: Any
        if rejected && (shape == .http || shape == .whole) {
            body = ["id": NSNull(), "error": error]
        } else {
            body = ids.reversed().map { id -> [String: Any] in
                if rejected && !(shape == .mixed && id == 1) { return ["id": id, "error": error] }
                return ["id": id, "result": ["value": id]]
            }
        }
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor SolanaBudgetHostRecorder {
    private var hosts: [String: Int] = [:]
    func record(_ host: String) { hosts[host, default: 0] += 1 }
    func count(_ host: String) -> Int { hosts[host, default: 0] }
}
