import XCTest
@testable import OathAnkr

final class StellarPlanTimestampTests: XCTestCase {
    let seed = Data(repeating: 11, count: 32)
    let epoch = 1_700_000_000.0

    func plan(created: Double, deadline: UInt64 = 1_700_000_120) throws -> StellarSendPlan {
        StellarSendPlan(network: .testnet,
            sender: try StellarSendCrypto.address(privateKey: seed),
            recipient: try StellarSendCrypto.address(privateKey: Data(repeating: 12, count: 32)),
            reference: "native", requestedAmount: "12345", amount: "12345",
            assetBalance: "1000000000", nativeBalance: 1_000_000_000, reserve: 10_000_000,
            fee: 120, sequence: 42, firstLedger: 1000, lastLedger: 1025,
            maxTime: deadline, createdAt: Date(timeIntervalSince1970: created))
    }
    func testPersistedValidPlanKeepsSignedBytes() throws {
        let value = try plan(created: epoch + 0.25)
        let signed = try StellarSendCrypto.sign(value, privateKey: seed, now: value.createdAt)
        let decoded = try JSONDecoder().decode(StellarSendPlan.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(try StellarSendXDR.transaction(decoded), try StellarSendXDR.transaction(value))
        try StellarSendCrypto.verify(signed, plan: decoded)
        XCTAssertThrowsError(try decoded.validate(now: Date(timeIntervalSince1970: epoch + 1000)))
        // Reconciliation deliberately accepts old, structurally valid plans.
        try decoded.validate(checkAge: false)
    }
    func testOutOfRangeFiniteDatesAreRejected() throws {
        for created in [Double(UInt64.max), 1e30, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try plan(created: created).validate(checkAge: false)) {
                XCTAssertEqual($0 as? StellarSendError, .malformed)
            }
        }
    }
    func testInfiniteDatesAreRejected() throws {
        for created in [Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try plan(created: created).validate(checkAge: false)) {
                XCTAssertEqual($0 as? StellarSendError, .malformed)
            }
        }
    }
    func testNaNDateIsRejected() throws {
        XCTAssertThrowsError(try plan(created: .nan).validate(checkAge: false)) {
            XCTAssertEqual($0 as? StellarSendError, .malformed)
        }
    }
    func testDecodedOutOfRangePlanIsRejectedByPublicVerifier() throws {
        let value = try plan(created: epoch)
        let signed = try StellarSendCrypto.sign(value, privateKey: seed, now: value.createdAt)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        fields["createdAt"] = 1e30
        let decoded = try JSONDecoder().decode(StellarSendPlan.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertTrue(decoded.createdAt.timeIntervalSince1970.isFinite)
        XCTAssertThrowsError(try StellarSendCrypto.verify(signed, plan: decoded)) {
            XCTAssertEqual($0 as? StellarSendError, .malformed)
        }
    }
    func testTimestampAndExpiryBoundariesRemainCompatible() throws {
        for created in [-0.5, 0, 0.5, epoch, epoch + 0.25] {
            let deadline = UInt64(max(0, created)) + 120
            try plan(created: created, deadline: deadline).validate(checkAge: false)
        }
        try plan(created: epoch, deadline: 1_700_000_180).validate(checkAge: false)
        for deadline: UInt64 in [1_700_000_000, 1_700_000_181, UInt64.max] {
            XCTAssertThrowsError(try plan(created: epoch, deadline: deadline).validate(checkAge: false))
        }
        let value = try plan(created: epoch)
        for age in [-5.0, 0, 90] { try value.validate(now: Date(timeIntervalSince1970: epoch + age)) }
        for age in [-6.0, 91, 120] {
            XCTAssertThrowsError(try value.validate(now: Date(timeIntervalSince1970: epoch + age))) {
                XCTAssertEqual($0 as? StellarSendError, .expired)
            }
        }
    }
}
