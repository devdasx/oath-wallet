import XCTest
@testable import Schemas
import WalletConnectNetworking

final class SessionExpiryTests: XCTestCase {
    private func session(expiryOffset: Int64 = 7200) -> WCSession {
        let metadata = AppMetadata(name: "Synthetic", description: "Audit fixture", url: "https://example.invalid", icons: [], redirect: try! AppMetadata.Redirect(native: "", universal: nil))
        let owner = Participant(publicKey: String(repeating: "1", count: 64), metadata: metadata)
        let peer = Participant(publicKey: String(repeating: "2", count: 64), metadata: metadata)
        let parameters = SessionType.SettleParams(relay: RelayProtocolOptions(protocol: "irn", data: nil),
            controller: owner, namespaces: [:], sessionProperties: nil, scopedProperties: nil,
            expiry: Int64(Date().timeIntervalSince1970) + expiryOffset, proposalRequestsResponses: nil)
        return WCSession(topic: "synthetic-session", pairingTopic: "synthetic-pairing", timestamp: Date(),
            selfParticipant: owner, peerParticipant: peer, settleParams: parameters,
            requiredNamespaces: [:], acknowledged: true, transportType: .relay, verifyContext: nil)
    }

    private func reject(_ timestamp: Int64) {
        var value = session()
        let original = value.expiryDate
        XCTAssertThrowsError(try value.updateExpiry(to: timestamp), "Invalid extension must throw")
        XCTAssertEqual(value.expiryDate, original, "Rejected extension must preserve the stored expiry")
    }

    func testNegativeRelativeExtensionCannotReviveExpiredSession() {
        var value = session(expiryOffset: -7200)
        let original = value.expiryDate
        XCTAssertThrowsError(try value.updateExpiry(by: -1), "Negative relative extension must throw")
        XCTAssertEqual(value.expiryDate, original, "Rejected relative extension must preserve expiry")
    }

    func testCannotShortenLiveSession() { reject(Int64(Date().timeIntervalSince1970) + 3600) }
    func testCannotMoveExpiryIntoPast() { reject(Int64(Date().timeIntervalSince1970) - 3600) }
    func testMaximumIntegerDoesNotTrap() { reject(.max) }
    func testMinimumIntegerDoesNotTrap() { reject(.min) }
    func testCannotExceedSevenDayWindow() { reject(Int64(Date().timeIntervalSince1970) + 8 * 86400) }

    func testValidExtensionPreservesExactTimestamp() throws {
        var value = session()
        let timestamp = Int64(Date().timeIntervalSince1970) + 3 * 86400
        try value.updateExpiry(to: timestamp)
        XCTAssertEqual(value.expiryDate.timeIntervalSince1970, Double(timestamp))
    }

    func testAcknowledgementAtSameSecondIsIdempotent() throws {
        var value = session()
        try value.updateExpiry(by: 86400)
        let rounded = Int64(value.expiryDate.timeIntervalSince1970)
        try value.updateExpiry(to: rounded)
        try value.updateExpiry(to: rounded)
        XCTAssertEqual(value.expiryDate.timeIntervalSince1970, Double(rounded))
    }

    private func request(expiry: UInt64?) -> Schemas.Request {
        Schemas.Request(id: RPCID(42), topic: "synthetic-session", method: "synthetic-method",
            params: AnyCodable([String]()), chainId: Blockchain("eip155:1")!, expiryTimestamp: expiry)
    }

    func testMaximumRequestExpiryDoesNotTrap() {
        let value = request(expiry: .max)
        XCTAssertThrowsError(try value.calculateTtl(), "Unbounded request TTL must throw")
    }

    func testRequestCannotAdvertiseUnboundedTtl() {
        let value = request(expiry: UInt64(Date().timeIntervalSince1970) + 8 * 86400)
        XCTAssertThrowsError(try value.calculateTtl(), "Unbounded request TTL must throw")
    }

    func testElapsedRequestRetainsRemainingTtl() throws {
        let value = request(expiry: 2_000_000_300)
        XCTAssertEqual(try value.calculateTtl(currentDate: Date(timeIntervalSince1970: 2_000_000_100)), 200)
    }

    func testMissingRequestExpiryUsesDefault() throws {
        XCTAssertEqual(try request(expiry: nil).calculateTtl(), 300)
    }

    func testExpiredRequestThrows() {
        XCTAssertThrowsError(try request(expiry: 1).calculateTtl())
    }
}
