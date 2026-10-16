import XCTest
@testable import OathAnkr

/// Only public testnet reads and unsigned simulation are allowed. The fixture
/// decoder deliberately has no private-key property; this test never signs.
private actor XrplRequirementsReadOnlyTransport: AnkrTransport {
    let transport = AnkrHTTPTransport()
    var methods = [String]()
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(XrplJSON.self, from: request.httpBody ?? Data())
        let allowed = ["server_info", "fee", "account_info", "account_lines", "ledger_entry", "simulate"]
        guard request.url == XrplSendNetwork.testnet.endpoint,
              let method = body["method"].string, allowed.contains(method) else {
            throw XrplSendError.configuration
        }
        methods.append(method)
        return try await transport.send(request)
    }
}

final class XrplAccountRequirementsLiveTests: XCTestCase {
    func testTestnetRecipientActivationAndMaximumReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["OATH_XRPL_REQUIREMENTS_LIVE"] == "1",
              let path = ProcessInfo.processInfo.environment["OATH_XRPL_TESTNET_FIXTURE"] else {
            throw XCTSkip("Explicit testnet read-only opt-in and isolated fixture required")
        }
        struct Fixture: Decodable {
            struct Wallet: Decodable { let address: String }
            let sender: Wallet
            let issued: String
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var temporary = Data((0..<32).map { _ in UInt8.random(in: 1...254) })
        let absent = try XrplSendCrypto.address(privateKey: temporary)
        temporary.resetBytes(in: 0..<temporary.count)
        let transport = XrplRequirementsReadOnlyTransport()
        let client = try XrplSendClient(network: .testnet, transport: transport)
        var minimum: UInt64?
        do {
            let _ = try await XrplSendPreparation.run {
                try await client.quote(sender: fixture.sender.address, recipient: absent, reference: "native", amount: "1")
            }
            XCTFail("One drop must not activate a new account")
        } catch {
            guard case .recipientMinimum(let value) = error as? XrplSendError else { throw error }
            minimum = value
        }
        let activationMinimum = try XCTUnwrap(minimum)
        XCTAssertGreaterThan(activationMinimum, 1)
        let exact = try await XrplSendPreparation.run {
            try await client.quote(sender: fixture.sender.address, recipient: absent, reference: "native", amount: String(activationMinimum))
        }
        XCTAssertEqual(exact.amount, String(activationMinimum))
        XCTAssertEqual(exact.recipientReserve, activationMinimum)
        XCTAssertEqual(exact.assetDebit, exact.amount)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(UInt64(exact.remaining)), exact.reserve)
        do {
            let _ = try await XrplSendPreparation.run {
                try await client.quote(sender: fixture.sender.address, recipient: absent, reference: fixture.issued,
                    amount: XrplIdentity.issuedAmount("1"))
            }
            XCTFail("An issued token cannot activate the missing recipient")
        } catch { XCTAssertEqual(error as? XrplSendError, .recipientUnfunded) }
        let maximum = try await XrplSendPreparation.run {
            try await client.quote(sender: fixture.sender.address, recipient: absent, reference: "native", amount: "1", maximum: true)
        }
        XCTAssertEqual(maximum.amount, String(maximum.nativeBalance - maximum.reserve - maximum.fee))
        XCTAssertEqual(maximum.remaining, String(maximum.reserve))
        let methods = await transport.methods
        XCTAssertTrue(methods.contains("simulate")); XCTAssertFalse(methods.contains("submit"))
        print("XRPL_REQUIREMENTS_TESTNET_VERIFIED activation_minimum=\(activationMinimum) exact_funding=true token_requires_existing_account=true max_preserves_reserve=true broadcasts=0")
    }
}
