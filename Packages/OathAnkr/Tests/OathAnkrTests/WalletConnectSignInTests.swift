import XCTest
@testable import OathAnkr

final class WalletConnectSignInTests: XCTestCase {
    let account = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    let now = Date(timeIntervalSince1970: 1_792_051_200) // 2026-10-15 08:00 UTC
    var message: String {
        """
        app.example.com wants you to sign in with your Ethereum account:
        \(account)

        Sign in to Example.

        URI: https://app.example.com/login
        Version: 1
        Chain ID: 1
        Nonce: OathTest123
        Issued At: 2026-10-15T07:59:00Z
        Expiration Time: 2026-10-15T08:05:00Z
        Not Before: 2026-10-15T07:59:00Z
        Request ID: request-1
        Resources:
        - https://app.example.com/profile
        - urn:recap:example
        """
    }
    func parse(_ text: String) throws -> WalletConnectSignIn? {
        try .parse(Data(text.utf8), account: account, chainID: 1, website: "https://app.example.com", now: now)
    }
    func testRecognizesBoundSignInAndKeepsAllResources() throws {
        let value = try XCTUnwrap(parse(message))
        XCTAssertEqual(value.domain, "app.example.com")
        XCTAssertEqual(value.statement, "Sign in to Example.")
        XCTAssertEqual(value.resources, ["https://app.example.com/profile", "urn:recap:example"])
        XCTAssertEqual(value.requestID, "request-1")
        XCTAssertEqual(value.nonce, "OathTest123")
        XCTAssertThrowsError(try value.validateTime(now: now.addingTimeInterval(301)))
        XCTAssertThrowsError(try value.validateTime(now: now.addingTimeInterval(-120)))
        XCTAssertNil(try parse("A generic message, not a login"))
    }
    func testRejectsOriginAccountChainTimeAndGrammarSubstitution() throws {
        for (before, after) in [
            ("app.example.com wants", "attacker.example.com wants"),
            ("URI: https://app.example.com", "URI: https://attacker.example.com"),
            ("app.example.com wants", "http://app.example.com wants"),
            (account, "0x1111111111111111111111111111111111111111"),
            ("Chain ID: 1", "Chain ID: 56"),
            ("Version: 1", "Version: 2"),
            ("Nonce: OathTest123", "Nonce: short"),
            ("Nonce: OathTest123", "Nonce: eight-123"),
            ("Expiration Time: 2026-10-15T08:05:00Z", "Expiration Time: 2026-10-15T08:00:00Z"),
            ("Not Before: 2026-10-15T07:59:00Z", "Not Before: 2026-10-15T08:01:00Z"),
            ("Issued At: 2026-10-15T07:59:00Z", "Issued At: never"),
            ("Sign in to Example.", "Sign in\nwith hidden extra fields"),
            ("Sign in to Example.", "Sign in\u{202e}to Example."),
            ("Request ID: request-1", "Version: 1"),
            ("- urn:recap:example", "ignored trailing content")
        ] { XCTAssertThrowsError(try parse(message.replacingOccurrences(of: before, with: after)), before) }
    }
    func testEmptyStatementOptionalDatesAndHTTPSDefaultPort() throws {
        let basic = """
        https://app.example.com:443 wants you to sign in with your Ethereum account:
        \(account)


        URI: https://app.example.com/login
        Version: 1
        Chain ID: 1
        Nonce: 12345678
        Issued At: 2026-10-15T07:59:00.000Z
        """
        let value = try XCTUnwrap(parse(basic))
        XCTAssertNil(value.statement); XCTAssertNil(value.expiration); XCTAssertTrue(value.resources.isEmpty)
        XCTAssertThrowsError(try parse(basic + "\nNonce: 87654321"))
        XCTAssertThrowsError(try parse(basic.replacingOccurrences(of: ":443", with: ":444")))
    }
}
