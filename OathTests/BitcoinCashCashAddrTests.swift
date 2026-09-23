import Foundation
import Testing
@testable import Aperture

struct BitcoinCashCashAddrTests {
    @Test
    func p2pkhEncodingMatchesTheCanonicalCashAddrVector() throws {
        let publicKeyHash = try #require(
            Data(hexString: "211b74ca4686f81efda5641767fc84ef16dafe0b")
        )

        #expect(
            BitcoinCashCashAddrEncoder.p2pkh(
                publicKeyHash: publicKeyHash
            )
                == "bitcoincash:qqs3kax2g6r0s8ha54jpwelusnh3dkh7pvu23rzrru"
        )
    }
}
