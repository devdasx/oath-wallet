import XCTest
@testable import OathAnkr

private actor ArchivePacingFeed: AnkrTransport {
    let transaction: SolanaJSON
    var starts: [ContinuousClock.Instant] = []
    init(transaction: SolanaJSON) { self.transaction = transaction }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        let primary = request.url?.host == "rpc.ankr.com"
        if !primary { XCTAssertNil(body.array, "Public archive calls must not burst in batches") }
        let calls = body.array ?? [body]
        let replies = calls.map { call -> SolanaJSON in
            let result: SolanaJSON
            if call["method"].string == "getGenesisHash" { result = .string(SolanaIdentity.genesis) }
            else if primary { result = .null }
            else {
                starts.append(.now)
                guard case .object(var root) = transaction, case .object(var tx) = root["transaction"] else { preconditionFailure() }
                tx["signatures"] = .array([call["params"].array![0]])
                root["transaction"] = .object(tx); result = .object(root)
            }
            return .object(["jsonrpc": .string("2.0"), "id": call["id"], "result": result])
        }
        return (try JSONEncoder().encode(body.array == nil ? replies[0] : .array(replies)), 200)
    }
}

extension SolanaTests {
    func testArchiveFallbackSpacesMembersInsteadOfBurstingABatch() async throws {
        let feed = ArchivePacingFeed(transaction: try tx())
        let values = [signature, String(repeating: "1", count: 63) + "2", String(repeating: "1", count: 63) + "3"]
        let result = try await SolanaClient(apiKey: "fixture", transport: feed).transactions(signatures: values, owner: owner)
        XCTAssertEqual(result.map(\.signature), values)
        let starts = await feed.starts
        XCTAssertEqual(starts.count, 3)
        for i in 1..<starts.count { XCTAssertGreaterThanOrEqual(starts[i] - starts[i-1], .milliseconds(1150)) }
    }
}
