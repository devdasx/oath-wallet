import XCTest
@testable import OathAnkr

final class WalletConnectNetworkRequestTests: XCTestCase {
    func testSwitchAcceptsOnlyExactAuthorizedKnownChain() throws {
        func parse(_ text: String, authorized: Set<UInt64> = [1,42161]) throws -> UInt64 {
            try WalletConnectNetworkRequest.chainID(params: Data(text.utf8), supported: [1,42161], authorized: authorized)
        }
        XCTAssertEqual(try parse("[{\"chainId\":\"0xa4b1\"}]"),42161)
        for invalid in ["[]", "{}", "[{\"chainId\":42161}]", "[{\"chainId\":\"0x0\"}]", "[{\"chainId\":\"0x01\"}]", "[{\"chainId\":\"0xa4b1\",\"rpcUrls\":[\"https://evil.example\"]}]", "[{\"chainId\":\"0x1\",\"chainId\":\"0xa4b1\"}]", "[{\"chainId\":\"0x1\"},{\"chainId\":\"0xa4b1\"}]"] {
            XCTAssertThrowsError(try parse(invalid))
        }
        XCTAssertThrowsError(try parse("[{\"chainId\":\"0xa4b1\"}]",authorized:[1]))
        XCTAssertThrowsError(try parse("[{\"chainId\":\"0xdeadbeef\"}]"))
    }
}
