import XCTest
@testable import OathMarketData

final class CronosIdentityTests: XCTestCase {
    func testCronosNativeAndTokenPricesUseTheirExactNetworkIdentity() {
        XCTAssertEqual(MarketIdentity.native["cronos"]?.coinbase, "CRO")
        XCTAssertEqual(MarketIdentity.native["cronos"]?.gecko, "crypto-com-chain")
        XCTAssertEqual(MarketIdentity.geckoPlatforms["cronos"], "cronos")
        XCTAssertNil(MarketIdentity.native["cronosTestnet"])
    }
}
