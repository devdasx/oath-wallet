import Foundation
import XCTest
@testable import OathAnkr

final class EVMHistoryEnrichmentLiveTests: XCTestCase {
    func testSepoliaNativeUnknownRouterAndCCTPReceipts() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OATH_HISTORY_TESTNET_LIVE"] == "1", let path = env["OATH_HISTORY_TESTNET_RPC_PLIST"] else {
            throw XCTSkip("Explicit read-only public testnet validation required")
        }
        let settings = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let endpoint = URL(string: "https://rpc.ankr.com/eth_sepolia")!.appendingPathComponent(try XCTUnwrap(settings["AnkrAPIKey"]))
        let client = try EVMSendClient(network: .ethereumSepolia, endpoints: [endpoint])
        for (name, hash) in [
            ("native-input", "0xcaa8907f4afad28134d10a56f0614b2326e809716a3090618f238e4501a51163"),
            ("unknown-router-native-output", "0x83b8c6b9809927f30ca1550d99f355872681e4aeaf94f31f337103db29f80301"),
            ("cctp-source", "0x5b1c5ac9965afcb4e8860c01535fe8f9eb11bd7a5345c547a800f23a82b96bc1")
        ] {
            let e = try await client.historyEvidence(hash: hash), owner = try XCTUnwrap(e.transaction["from"].string)
            if name == "cctp-source" {
                let bridge = try XCTUnwrap(EVMHistoryBridge.classify(e, owner: owner, chainID: 11155111))
                XCTAssertEqual(bridge.amount, "100000000"); XCTAssertEqual(bridge.direction, "outgoing")
            } else {
                let swap = try XCTUnwrap(EVMHistorySwap.classify(transaction: e.transaction, receipt: e.receipt,
                    owner: owner, chainID: 11155111, trace: e.trace, pools: e.pools ?? []), name)
                if name == "native-input" { XCTAssertEqual(swap.input, "native") }
                else { XCTAssertEqual(swap.output, "native"); XCTAssertFalse(e.pools?.isEmpty ?? true) }
                print("HISTORY_TESTNET_VERIFIED type=\(name) hash=\(hash) spent=\(swap.spent) received=\(swap.received)")
            }
            if let output = env["OATH_HISTORY_EVIDENCE_OUTPUT"] {
                let folder = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try JSONEncoder().encode(e).write(to: folder.appendingPathComponent(name + ".json"))
            }
        }
    }
}
