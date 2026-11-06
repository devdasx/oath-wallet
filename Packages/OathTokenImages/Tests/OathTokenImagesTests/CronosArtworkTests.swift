import XCTest
@testable import OathTokenImages

final class CronosArtworkTests: XCTestCase {
    func testArtworkCannotCrossNetworkOrContractIdentity() throws {
        let contract = "0x" + String(repeating: "A", count: 40)
        let identity = try XCTUnwrap(TokenArtworkIdentity(networkID: "cronos", reference: contract, decimals: 18))
        XCTAssertEqual(identity.reference, contract.lowercased())
        let source = "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/cronos/assets/" + contract + "/logo.png"
        let route = try XCTUnwrap(ArtworkFallbackCatalog.identity(source))
        XCTAssertEqual(route.networkID, "cronos"); XCTAssertEqual(route.chainID, 25)
        XCTAssertEqual(route.platform, "cronos"); XCTAssertEqual(route.contract, contract.lowercased())
    }
}
