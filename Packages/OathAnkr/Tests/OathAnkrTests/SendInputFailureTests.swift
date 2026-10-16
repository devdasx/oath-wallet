import XCTest
@testable import OathAnkr

private struct NoSendInputNetwork: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        XCTFail("Invalid send input must be rejected before fee lookup or signing")
        throw AnkrError.transport
    }
}

final class SendInputFailureTests: XCTestCase {
    func testXRPSeparatesSameRecipientFromInvalidAmountBeforeNetworkWork() async throws {
        let sender = "r9cZA1mLK5R5Am25ArfXFmqgNwjZgnfk59", recipient = "rLxePHrWeHbkg8yy83fWxnxXmYbwmuMK9Q"
        let client = try XrplSendClient(network: .mainnet, transport: NoSendInputNetwork())
        for (to, amount, expected) in [(sender, "1", XrplSendError.sameRecipient), (recipient, "0", .amount), (recipient, "1.5", .amount)] {
            do { _ = try await client.quote(sender: sender, recipient: to, reference: "native", amount: amount); XCTFail("Rejected input accepted") }
            catch { XCTAssertEqual(error as? XrplSendError, expected) }
        }
    }
    func testAptosSeparatesSignerRecipientAndAmountFailuresBeforeNetworkWork() async throws {
        let key = Data(repeating: 1, count: 32), otherKey = Data(repeating: 2, count: 32)
        let sender = try AptosSendCrypto.address(privateKey: key), recipient = try AptosSendCrypto.address(privateKey: otherKey)
        let publicKey = try AptosSendCrypto.publicKey(privateKey: key), otherPublic = try AptosSendCrypto.publicKey(privateKey: otherKey)
        let client = try AptosSendClient(network: .testnet, transport: NoSendInputNetwork())
        for (to, amount, signingKey, expected) in [(sender, "1", publicKey, AptosSendError.sameRecipient), (recipient, "0", publicKey, .amount), (recipient, "1", otherPublic, .wrongOwner)] {
            do { _ = try await client.quote(sender: sender, recipient: to, reference: "native", publicKey: signingKey, decimals: 8, amount: amount); XCTFail("Rejected input accepted") }
            catch { XCTAssertEqual(error as? AptosSendError, expected) }
        }
    }
}
