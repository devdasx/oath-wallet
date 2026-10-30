import XCTest
@testable import OathAnkr

final class PartialInventoryCauseTests: XCTestCase {
    private func ton(_ errors: [TonError], failed: Int? = nil, complete: Bool = true, discovery: TonError? = nil) -> TonInventory {
        .init(owner: "fixture", holdings: [], prices: [], failedReferences: Array(repeating: "fixture", count: failed ?? errors.count), discoveryComplete: complete, observedAt: .now, raw: Data(), discoveryError: discovery, holdingErrors: errors)
    }
    private func aptos(_ errors: [AptosError], failed: Int? = nil, complete: Bool = true, discovery: AptosError? = nil) -> AptosInventory {
        .init(owner: "fixture", holdings: [], failedReferences: Array(repeating: "fixture", count: failed ?? errors.count), discoveryComplete: complete, ledgerVersion: 1, observedAt: .now, raw: Data(), discoveryError: discovery, holdingErrors: errors)
    }
    func testKnownReadFailuresKeepCauseButMixedValidationNeverBecomesAvailability() {
        XCTAssertEqual(ton([.http(408)]).incompleteError, .http(408))
        XCTAssertEqual(aptos([.http(408)]).incompleteError, .http(408))
        for reversed in [false, true] {
            let tonErrors: [TonError] = reversed ? [.wrongOwner, .http(408)] : [.http(408), .wrongOwner]
            let aptosErrors: [AptosError] = reversed ? [.wrongOwner, .http(408)] : [.http(408), .wrongOwner]
            XCTAssertEqual(ton(tonErrors).incompleteError, .wrongOwner)
            XCTAssertEqual(aptos(aptosErrors).incompleteError, .wrongOwner)
        }
        XCTAssertEqual(ton([.http(408)], complete: false, discovery: .malformed).incompleteError, .malformed)
        XCTAssertEqual(aptos([.http(408)], complete: false, discovery: .malformed).incompleteError, .malformed)
        XCTAssertEqual(ton([.wrongOwner], complete: false, discovery: .http(429)).incompleteError, .wrongOwner)
        XCTAssertEqual(aptos([.wrongOwner], complete: false, discovery: .http(429)).incompleteError, .wrongOwner)
    }
    func testUnknownFailureOrIncompleteDiscoveryCannotBeExcludedAsAnOutage() {
        XCTAssertEqual(ton([.http(408)], failed: 2).incompleteError, .incomplete)
        XCTAssertEqual(aptos([.http(408)], failed: 2).incompleteError, .incomplete)
        XCTAssertEqual(ton([.http(408)], complete: false).incompleteError, .incomplete)
        XCTAssertEqual(aptos([.http(408)], complete: false).incompleteError, .incomplete)
        XCTAssertNil(ton([]).incompleteError)
        XCTAssertNil(aptos([]).incompleteError)
    }
    func testTransientCausesAreNotStoredOrReconstructedFromSnapshots() throws {
        let tonData = try JSONEncoder().encode(ton([.http(408)], complete: false, discovery: .http(429)))
        let aptosData = try JSONEncoder().encode(aptos([.http(408)], complete: false, discovery: .http(429)))
        for data in [tonData, aptosData] {
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(fields["holdingErrors"]); XCTAssertNil(fields["discoveryError"])
        }
        let restoredTon = try JSONDecoder().decode(TonInventory.self, from: tonData)
        let restoredAptos = try JSONDecoder().decode(AptosInventory.self, from: aptosData)
        XCTAssertTrue(restoredTon.holdingErrors.isEmpty); XCTAssertEqual(restoredTon.incompleteError, .incomplete)
        XCTAssertTrue(restoredAptos.holdingErrors.isEmpty); XCTAssertEqual(restoredAptos.incompleteError, .incomplete)
    }
}
