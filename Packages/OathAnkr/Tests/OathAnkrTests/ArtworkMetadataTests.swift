import XCTest
@testable import OathAnkr

final class ArtworkMetadataTests: XCTestCase {
    func testAptosPreservesPanoraAndDecentralizedArtwork() throws {
        for source in ["https://assets.panora.exchange/tokens/aptos/USDC.svg", "ipfs://bafyTest/art.svg"] {
            let json: AptosJSON = .object(["decimals": .number("6"), "name": .string("Token"), "symbol": .string("TKN"), "icon_uri": .string(source)])
            let token = try AptosToken.decode(json, reference: "0x123")
            XCTAssertEqual(token.logo, source.replacingOccurrences(of: "ipfs://", with: "https://ipfs.io/ipfs/"))
        }
    }
    func testTonPreservesCDNArtwork() throws {
        let source = "https://cache.tonapi.io/imgproxy/public/logo.webp"
        let json: TonJSON = .object(["address": .string("0:" + String(repeating: "1", count: 64)),
            "name": .string("Token"), "symbol": .string("TKN"), "decimals": .number("6"),
            "image": .string(source), "verification": .string("whitelist")])
        XCTAssertEqual(try TonToken.decode(json).logo, source)
    }
    func testNearInlineSVGAndSuiIPFSDoNotGetDiscarded() throws {
        let image = "data:image/svg+xml;base64," + Data("<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'><circle cx='10' cy='10' r='10'/></svg>".utf8).base64EncodedString()
        let near: NearJSON = .object(["spec": .string("ft-1.0.0"), "decimals": .number("18"),
            "name": .string("Token"), "symbol": .string("TKN"), "icon": .string(image)])
        XCTAssertEqual(try NearToken.decode(near, reference: "token.near").logo, image)
        let sui: SuiJSON = .object(["decimals": .number("9"), "name": .string("Token"), "symbol": .string("TKN"), "iconUrl": .string("ipfs://bafyTest/logo.png")])
        XCTAssertEqual(try SuiToken.decode(sui, reference: "0x1::token::TOKEN").logo, "https://ipfs.io/ipfs/bafyTest/logo.png")
    }
}
