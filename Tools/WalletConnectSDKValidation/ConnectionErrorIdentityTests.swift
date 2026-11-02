import XCTest
@testable import WalletConnectPairing
@testable import WalletConnectRelay

final class ConnectionErrorIdentityTests: XCTestCase {
    func testConnectionErrorIdentitiesUsedByAppPresentation() {
        let used = WalletPairService.Errors.noPendingRequestsForPairing(topic: "synthetic-private-topic") as NSError
        XCTAssertEqual(used.domain, "WalletConnectPairing.WalletPairService.Errors")
        XCTAssertEqual(used.code, 0)
        let disconnected = WalletPairService.Errors.networkNotConnected as NSError
        XCTAssertEqual(disconnected.domain, used.domain)
        XCTAssertEqual(disconnected.code, 1)
        let timeout = RelayError.requestTimeout as NSError
        XCTAssertEqual(timeout.domain, "WalletConnectRelay.RelayError")
        XCTAssertEqual(timeout.code, 0)
    }
}
