import XCTest
import CryptoKit
@testable import OathAnkr

/// This regression uses only the API present in build 104, so the exact same
/// test can run against the reported source and the repaired implementation.
final class WalletConnectSolanaConsentRegressionTests: XCTestCase {
    func testPermissionChangeWithIdenticalBalancesMustChangeReview() async throws {
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)).publicKey.rawRepresentation
        let source = Data(repeating: 2, count: 32), program = Data(repeating: 9, count: 32)
        // An arbitrary program can invoke SPL Approve through CPI. Its input
        // and balances can be unchanged while its selected delegate changes.
        var message = Data([1,0,4,6]) + signer + source
        message += Data(repeating: 4, count: 32) + Data(repeating: 8, count: 32)
        message += try SolanaSendCrypto.decode(SolanaIdentity.tokenProgram)
        message += program + Data(repeating: 7, count: 32) + Data([1,5,5,1,2,3,0,4,1,0])
        let wire = Data([1]) + Data(repeating: 0, count: 64) + message
        let request = try WalletConnectSolanaRequest(method: "solana_signTransaction", chain: SolanaSendNetwork.devnet.walletConnectChain,
            account: SolanaSendCrypto.encode(signer), params: JSONEncoder().encode(SolanaJSON.object(["transaction": .string(wire.base64EncodedString())])))
        let original = try await SolanaSendClient(network: .devnet, transport: ConsentRegressionRPC(owner: signer, delegate: 4)).walletConnectReview(request)[0]
        let changed = try await SolanaSendClient(network: .devnet, transport: ConsentRegressionRPC(owner: signer, delegate: 8)).walletConnectReview(request)[0]
        XCTAssertEqual(original.fee, changed.fee)
        XCTAssertEqual(original.programs, changed.programs)
        XCTAssertEqual(original.changes, changed.changes)
        XCTAssertEqual(original.slot, changed.slot)
        XCTAssertNotEqual(original, changed, "A different token delegate must not be represented by an identical review")
    }
}

private struct ConsentRegressionRPC: AnkrTransport {
    let owner: Data, delegate: UInt8
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        XCTAssertEqual(request.url?.host, "api.devnet.solana.com")
        let json = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        func token(_ approved: Bool) -> SolanaJSON {
            var bytes = Data(repeating: 3, count: 32) + owner + Data(repeating: 0, count: 101)
            bytes.replaceSubrange(64..<72, with: Data([0,202,154,59,0,0,0,0])) // 1,000,000,000 base units
            bytes[108] = 1
            if approved {
                bytes[72] = 1; bytes.replaceSubrange(76..<108, with: Data(repeating: delegate, count: 32))
                bytes.replaceSubrange(121..<129, with: Data(repeating: 255, count: 8))
            }
            return .object(["owner": .string(SolanaIdentity.tokenProgram), "data": .array([.string(bytes.base64EncodedString()), .string("base64")])])
        }
        let result: SolanaJSON
        switch json["method"].string {
        case "getGenesisHash": result = .string(SolanaSendNetwork.devnet.genesis)
        case "isBlockhashValid": result = .object(["value": .bool(true)])
        case "getMultipleAccounts": result = .object(["context": .object(["slot": .number("123")]), "value": .array([.object(["lamports": .number("100000")]), token(false)])])
        case "simulateTransaction": result = .object(["value": .object(["err": .null, "accounts": .array([.object(["lamports": .number("95000")]), token(true)])])])
        case "getFeeForMessage": result = .object(["value": .number("5000")])
        case "getAccountInfo": result = .object(["value": .null]) // use exact base units
        default: XCTFail("Unexpected request"); throw SolanaSendError.malformed
        }
        return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": json["id"], "result": result])), 200)
    }
}
