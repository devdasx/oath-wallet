import Foundation
import XCTest
@testable import OathBitcoin

final class LitecoinHistoryDestinationTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Output: Decodable {
            let script: String
            let address: String?
        }
        let transaction: String
        let outputs: [Output]
    }

    // Expected destinations come from Litecoin Core 0.21.5.8 decoding this transaction.
    func testHistoryMatchesCoreForWitnessProgramsAndMWEBMarkers() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "litecoin-history-destinations", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let raw = try XCTUnwrap(Data(hex: fixture.transaction))
        let details = try BitcoinTransactions.details(raw, network: .litecoin)
        XCTAssertEqual(details.outputs.count, 70)
        XCTAssertEqual(fixture.outputs.count, details.outputs.count)
        XCTAssertEqual(fixture.outputs.compactMap(\.address).count, 40)
        for (actual, expected) in zip(details.outputs, fixture.outputs) {
            XCTAssertEqual(actual.script, expected.script)
            XCTAssertEqual(actual.value, 100_000)
            XCTAssertEqual(actual.address, expected.address, expected.script)
        }
    }
}
