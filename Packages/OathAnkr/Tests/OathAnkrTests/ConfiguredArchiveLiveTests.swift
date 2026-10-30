import Foundation
import XCTest
@testable import OathAnkr

/// Read-only probes of the archive route used when Alchemy is configured.
/// Fixtures are existing public test accounts; no wallet secrets or broadcasts.
final class ConfiguredArchiveLiveTests: XCTestCase, @unchecked Sendable {
    private func configuration() throws -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OATH_CONFIGURED_ARCHIVE_LIVE"] == "1" else {
            throw XCTSkip("Opt-in public archive reads")
        }
        let path = try XCTUnwrap(environment["OATH_ANKR_CONFIG"])
        return try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: String])
    }

    func testArcConfiguredArchivePreservesKnownNativeTransfer() async throws {
        let keys = try configuration()
        let client = try ArcClient(alchemyAPIKey: XCTUnwrap(keys["AlchemyAPIKey"]))
        let block: Int64 = 25_520_615
        let page = try await client.history(owner: "0x43d894e229a008c72e96872739719b9cfda941d5",
                                           from: block, through: block + 1)
        XCTAssertEqual(page.nextBlock, block + 1)
        XCTAssertTrue(page.events.contains {
            $0.hash == "0x5e3bd81e1fdfd2c37f53682007534ef45ea67609000a69c5fe7b7da05196c524"
                && $0.token.reference == "native"
        })
    }

    func testRobinhoodConfiguredArchiveValidatesReceiptsAcrossPages() async throws {
        let keys = try configuration()
        let client = try RobinhoodClient(apiKey: XCTUnwrap(keys["AnkrAPIKey"]),
                                        alchemyAPIKey: XCTUnwrap(keys["AlchemyAPIKey"]))
        let owner = "0x8366a39cc670b4001a1121b8f6a443a643e40951"
        let through = Date().timeIntervalSince1970
        var count = 0
        for stream in client.historyStreams {
            let first = try await client.history(owner: owner, stream: stream, through: through)
            count += first.events.count
            if let cursor = first.next {
                let second = try await client.history(owner: owner, stream: stream, cursor: cursor, through: through)
                XCTAssertTrue(Set(first.events.map(\.id)).isDisjoint(with: Set(second.events.map(\.id))))
                count += second.events.count
            }
        }
        XCTAssertGreaterThan(count, 0)
        print("ROBINHOOD_CONFIGURED_ARCHIVE verifiedEvents=\(count) broadcast=false")
    }
}
