import XCTest
@testable import OathAnkr

/// Testnet only: two injected HTTP failures, then one actual send of the exact
/// journaled message. Mainnet hosts and unexpected request methods are refused.
private actor TonRecoveryLiveTransport: AnkrTransport {
    private let http = AnkrHTTPTransport()
    private(set) var injectedFailures = 0, broadcasts = 0
    private var signedMessage: String?
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard let url = request.url, url.scheme == "https",
              ["testnet.toncenter.com", "testnet.tonapi.io"].contains(url.host) else {
            throw TonSendError.wrongNetwork
        }
        if url.host == "testnet.toncenter.com" {
            let body = try JSONDecoder().decode(TonJSON.self, from: XCTUnwrap(request.httpBody))
            guard let method = body["method"].string,
                  ["getMasterchainInfo", "getAddressInformation", "sendBoc"].contains(method) else {
                throw TonSendError.configuration
            }
            if method == "sendBoc" {
                let message = try XCTUnwrap(body["params"]["boc"].string)
                if let signedMessage {
                    guard signedMessage == message else { throw TonSendError.changed }
                } else { signedMessage = message }
                if injectedFailures < 2 {
                    injectedFailures += 1
                    return (Data(#"{"error":"isolated test provider failure"}"#.utf8), 500)
                }
                guard broadcasts == 0 else { throw TonSendError.busy }
                broadcasts += 1
            }
        } else {
            guard url.path.hasPrefix("/v2/traces/") else { throw TonSendError.configuration }
        }
        return try await http.send(request)
    }
}

@MainActor final class TonSendRecoveryLiveTests: XCTestCase {
    func testHTTPFailureRecoveryConfirmsExactTestnetDelivery() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TON_RECOVERY_LIVE"] == "1",
              let path = ProcessInfo.processInfo.environment["OATH_TON_FIXTURE"] else {
            throw XCTSkip("Explicit isolated TON testnet recovery fixture required")
        }
        struct Fixture: Decodable { let seed: String, sender: String, recipient: String }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let key = try TronIdentity.hex(fixture.seed)
        let transport = TonRecoveryLiveTransport()
        let client = try TonSendClient(network: .testnet, transport: transport)
        let plan = try await client.quote(sender: fixture.sender, recipient: fixture.recipient,
            reference: "native", publicKey: TonSendCrypto.publicKey(privateKey: key),
            decimals: 9, amount: "10000000", memo: "Oath provider recovery test")
        XCTAssertEqual(plan.amount, TonAmount(10_000_000))
        XCTAssertGreaterThan(plan.fee, 0)
        try await client.preflight(plan)
        let signed = try TonSendCrypto.sign(plan, privateKey: key)
        try TonSendCrypto.verify(signed, plan: plan)
        let directory = URL(fileURLWithPath: "/tmp/oath-ton-recovery-live", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        // Persist before submission; never print seeds, addresses or raw bytes.
        struct Journal: Codable { let plan: TonSendPlan, signed: TonSignedSend }
        let journal = directory.appendingPathComponent("recovery-journal.json")
        try JSONEncoder().encode(Journal(plan: plan, signed: signed)).write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        let submission = try await client.submit(signed, plan: plan)
        XCTAssertTrue([.accepted, .confirmed].contains(submission.outcome))
        let failures = await transport.injectedFailures, broadcasts = await transport.broadcasts
        XCTAssertEqual(failures, 2); XCTAssertEqual(broadcasts, 1)
        for _ in 0..<30 {
            try await Task.sleep(for: .seconds(4))
            let receipt = try await client.status(signed, plan: plan)
            if receipt.outcome == .confirmed {
                let hash = try XCTUnwrap(receipt.transactionHash), fee = try XCTUnwrap(receipt.fee)
                XCTAssertLessThanOrEqual(fee, plan.feeReserve)
                let evidence = ["messageHash": signed.hash, "transactionHash": hash,
                    "amount": String(plan.amount), "fee": String(fee), "injectedHTTP500": "2", "broadcasts": "1"]
                try JSONEncoder().encode(evidence).write(to: directory.appendingPathComponent("evidence.json"), options: .atomic)
                print("TON TESTNET RECOVERY confirmed; HTTP500=2; broadcasts=1; amount=10000000; fee=\(fee); transaction=\(hash)")
                return
            }
            XCTAssertNotEqual(receipt.outcome, .failed)
        }
        XCTFail("Signed testnet message is journaled; confirmed delivery was not observed within the bounded wait")
    }
}
