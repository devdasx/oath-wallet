import XCTest
@testable import OathAnkr

/// Historical outbox plans did not contain presentation metadata. Reading
/// those plans must neither break recovery nor invent a recipient reserve.
func withoutAccountCostMetadata<P: Codable>(_ plan: P) throws -> P {
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
    for key in ["recipientReserve", "recipientNeedsActivation", "accountCreationFee"] { json.removeValue(forKey: key) }
    return try JSONDecoder().decode(P.self, from: JSONSerialization.data(withJSONObject: json))
}

final class SendAccountCostTests: XCTestCase {
    func testAllCostKindsHaveCorrectUnitsAccountingAndNonblockingHelp() {
        let cases: [(SendAccountCost.Kind, SendAccountCost.Inclusion, Int, String, SendAccountGuidance.Topic)] = [
            (.xrpReserve,.payment,6,"XRP",.xrpActivation),
            (.stellarReserve,.payment,7,"XLM",.stellarActivation),
            (.solanaReserve,.payment,9,"SOL",.solanaActivation),
            (.tronCreation,.networkFee,6,"TRX",.tronActivation),
            (.solanaTokenDeposit,.additional,9,"SOL",.solanaRent),
            (.nearStorage,.additional,24,"NEAR",.nearStorage)
        ]
        for (kind,inclusion,decimals,symbol,topic) in cases {
            let cost=SendAccountCost(kind:kind,atomic:"1250000000000000000000")
            XCTAssertEqual(cost.inclusion,inclusion);XCTAssertEqual(cost.decimals,decimals);XCTAssertEqual(cost.symbol,symbol)
            XCTAssertEqual(cost.guidance.topic,topic);XCTAssertEqual(cost.guidance.cost,cost)
            XCTAssertFalse(cost.guidance.isBlocking);XCTAssertNil(cost.guidance.minimumAtomic)
        }
    }
}
