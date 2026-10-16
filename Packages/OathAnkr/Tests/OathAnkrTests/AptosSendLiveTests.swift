import XCTest
import Foundation
import CryptoKit
@testable import OathAnkr

/// Isolated, explicitly opted-in testnet funds only. Secrets remain in a local 0600 fixture.
@MainActor final class AptosSendLiveTests: XCTestCase {
    func testAmountBoundaryAndSmallTransferSimulationReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["OATH_APTOS_AMOUNT_READ_ONLY"] == "1" else {
            throw XCTSkip("Explicit isolated testnet simulation opt-in required")
        }
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: "/tmp/oath-aptos-testnet-fixture.json"))) as? [String: String])
        var key = try TronIdentity.hex(XCTUnwrap(fixture["privateKey"]).replacingOccurrences(of: "ed25519-priv-", with: ""))
        defer { key.resetBytes(in: 0..<key.count) }
        let sender = try XCTUnwrap(fixture["sender"]), recipient = try XCTUnwrap(fixture["recipient"])
        let publicKey = try AptosSendCrypto.publicKey(privateKey: key)
        let transport = AptosSimulationOnlyTransport()
        let client = try AptosSendClient(network: .testnet, transport: transport)
        do {
            _ = try await client.quote(sender: sender, recipient: recipient, reference: "native", publicKey: publicKey,
                                       decimals: 8, amount: "18446744073709551616")
            XCTFail("Out-of-range amount reached testnet")
        } catch { XCTAssertEqual(error as? AptosSendError, .amount) }
        let rejectedCalls = await transport.calls
        XCTAssertEqual(rejectedCalls, 0)
        for reference in ["native", try XCTUnwrap(fixture["coin"]), try XCTUnwrap(fixture["fa"])] {
            let plan = try await client.quote(sender: sender, recipient: recipient, reference: reference,
                publicKey: publicKey, decimals: reference == "native" ? 8 : 6, amount: "1")
            try plan.validate()
            XCTAssertEqual(plan.network, .testnet)
            XCTAssertEqual(plan.requestedAmount, 1)
            XCTAssertEqual(plan.amount, 1)
            XCTAssertGreaterThan(plan.fee, 0)
            print("APTOS_TESTNET_ONE_UNIT_SIMULATED kind=\(reference == "native" ? "APT" : reference.contains("::") ? "Coin" : "FA") signed=false broadcast=false")
        }
        let simulations = await transport.simulations
        XCTAssertEqual(simulations, 6, "Both the gas probe and exact final transfer were simulated for each asset type")
    }
    func testConfiguredMainnetProviderReadOnly() async throws {
        guard let path=ProcessInfo.processInfo.environment["OATH_APTOS_MAINNET_RPC_PLIST"] else { throw XCTSkip("Explicit read-only primary-provider opt-in required") }
        let plist=try XCTUnwrap(PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:path)),format:nil) as? [String:Any])
        let key=try XCTUnwrap(plist["AnkrAPIKey"] as? String)
        let client=try AptosSendClient(network:.mainnet,apiKey:key,transport:AptosMainnetReadOnlyTransport())
        _ = try await client.balance(owner:"0x1",reference:"native")
        print("APTOS_MAINNET_ANKR_READ_ONLY_OK chain_identity=true balance_view=true")
    }
    func testNativeCoinAndFungibleAssetEndToEnd() async throws {
        guard ProcessInfo.processInfo.environment["OATH_APTOS_LIVE"]=="1" else { throw XCTSkip("Requires isolated testnet fixture and explicit opt-in") }
        let f=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"/tmp/oath-aptos-testnet-fixture.json"))) as? [String:String])
        var key=try TronIdentity.hex(XCTUnwrap(f["privateKey"]).replacingOccurrences(of:"ed25519-priv-",with:""));defer { key.resetBytes(in:0..<key.count) }
        let sender=try XCTUnwrap(f["sender"]),recipient=try XCTUnwrap(f["recipient"]),client=try AptosSendClient(network:.testnet,transport:AptosLivePacedTransport())
        let refs=["native",try XCTUnwrap(f["coin"]),try XCTUnwrap(f["fa"])]
        for ref in refs {
            let before=try await client.balance(owner:sender,reference:ref),toBefore=try await client.balance(owner:recipient,reference:ref)
            let nativeBefore=try await client.balance(owner:sender,reference:"native")
            let plan=try await client.quote(sender:sender,recipient:recipient,reference:ref,publicKey:AptosSendCrypto.publicKey(privateKey:key),decimals:ref=="native" ? 8:6,amount:"1000000")
            try await client.preflight(plan)
            let signed=try AptosSendCrypto.sign(plan,privateKey:key)
            var result=try await client.submit(signed,plan:plan)
            for _ in 0..<40 where ![.confirmed,.failed].contains(result.outcome) {
                try await Task.sleep(for:.seconds(1));result=try await client.status(signed,plan:plan)
            }
            XCTAssertEqual(result.outcome,.confirmed)
            let fee=try XCTUnwrap(result.fee);XCTAssertLessThanOrEqual(fee,plan.fee)
            let version=try XCTUnwrap(result.version)
            let after=try await client.balance(owner:sender,reference:ref,version:version),toAfter=try await client.balance(owner:recipient,reference:ref,version:version)
            let nativeAfter=try await client.balance(owner:sender,reference:"native",version:version)
            XCTAssertEqual(toAfter-toBefore,plan.amount)
            XCTAssertEqual(before-after,plan.amount+(ref=="native" ? fee:0))
            XCTAssertEqual(nativeBefore-nativeAfter,fee+(ref=="native" ? plan.amount:0))
            // Re-submission of the original signed bytes must find the same committed transaction.
            let replay=try await client.submit(signed,plan:plan);XCTAssertEqual(replay,result)
            print("APTOS_TESTNET_CONFIRMED kind=\(ref=="native" ? "APT":ref.contains("::") ? "Coin":"FA") hash=\(signed.hash) fee_octas=\(fee) version=\(version) exact_balance_deltas=true")
        }
    }
    func testZMaximumReservesGasAndCommittedFailureIsNotSuccess() async throws {
        guard ProcessInfo.processInfo.environment["OATH_APTOS_LIVE"]=="1" else { throw XCTSkip("Requires isolated testnet fixture and explicit opt-in") }
        let f=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"/tmp/oath-aptos-testnet-fixture.json"))) as? [String:String])
        var key=try TronIdentity.hex(XCTUnwrap(f["privateKey"]).replacingOccurrences(of:"ed25519-priv-",with:""))
        var recipientKey=try TronIdentity.hex(XCTUnwrap(f["recipientKey"]).replacingOccurrences(of:"ed25519-priv-",with:""))
        defer { key.resetBytes(in:0..<key.count);recipientKey.resetBytes(in:0..<recipientKey.count) }
        let sender=try XCTUnwrap(f["sender"]),recipient=try XCTUnwrap(f["recipient"]),client=try AptosSendClient(network:.testnet,transport:AptosLivePacedTransport())
        func settle(_ signed:AptosSignedSend,_ plan:AptosSendPlan) async throws -> AptosSendReceipt {
            var result=try await client.submit(signed,plan:plan)
            for _ in 0..<40 where ![.confirmed,.failed].contains(result.outcome) {
                try await Task.sleep(for:.seconds(1));result=try await client.status(signed,plan:plan)
            }
            return result
        }
        // Give the test recipient gas, then return its entire Coin and FA
        // balances through the same Max path used by the app.
        let funding=try await client.quote(sender:sender,recipient:recipient,reference:"native",publicKey:AptosSendCrypto.publicKey(privateKey:key),decimals:8,amount:"1000000")
        let fundingReceipt=try await settle(AptosSendCrypto.sign(funding,privateKey:key),funding)
        XCTAssertEqual(fundingReceipt.outcome,.confirmed)
        for ref in [try XCTUnwrap(f["coin"]),try XCTUnwrap(f["fa"])] {
            let seed=try await client.quote(sender:sender,recipient:recipient,reference:ref,publicKey:AptosSendCrypto.publicKey(privateKey:key),decimals:6,amount:"10000")
            let seedReceipt=try await settle(AptosSendCrypto.sign(seed,privateKey:key),seed)
            XCTAssertEqual(seedReceipt.outcome,.confirmed)
            let toBefore=try await client.balance(owner:sender,reference:ref)
            let plan=try await client.quote(sender:recipient,recipient:sender,reference:ref,publicKey:AptosSendCrypto.publicKey(privateKey:recipientKey),decimals:6,amount:"1",maximum:true)
            XCTAssertEqual(plan.amount,plan.assetBalance)
            try await client.preflight(plan)
            let signed=try AptosSendCrypto.sign(plan,privateKey:recipientKey),result=try await settle(signed,plan)
            XCTAssertEqual(result.outcome,.confirmed)
            let left=try await client.balance(owner:recipient,reference:ref,version:result.version),toAfter=try await client.balance(owner:sender,reference:ref,version:result.version)
            XCTAssertEqual(left,0);XCTAssertEqual(toAfter-toBefore,plan.amount)
            print("APTOS_TESTNET_TOKEN_MAX_CONFIRMED kind=\(ref.contains("::") ? "Coin":"FA") hash=\(signed.hash) zero_token_remainder=true")
        }
        // Return the recipient's test APT with Max; the reviewed ceiling is kept
        // for gas and any unused gas stays in that account.
        let maximum=try await client.quote(sender:recipient,recipient:sender,reference:"native",publicKey:AptosSendCrypto.publicKey(privateKey:recipientKey),decimals:8,amount:"1",maximum:true)
        XCTAssertEqual(maximum.amount+maximum.fee,maximum.nativeBalance)
        try await client.preflight(maximum)
        let signedMax=try AptosSendCrypto.sign(maximum,privateKey:recipientKey),maxReceipt=try await settle(signedMax,maximum)
        XCTAssertEqual(maxReceipt.outcome,.confirmed)
        let left=try await client.balance(owner:recipient,reference:"native",version:maxReceipt.version)
        XCTAssertEqual(left,maximum.fee-(try XCTUnwrap(maxReceipt.fee)))
        print("APTOS_TESTNET_MAX_CONFIRMED hash=\(signedMax.hash) gas_reserved=true")
        // Deliberately under-budget an isolated test transfer to a new account.
        // Aptos commits failed execution and charges gas, but must transfer no APT.
        let fresh=try AptosSendCrypto.address(publicKey:Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let q=try await client.quote(sender:sender,recipient:fresh,reference:"native",publicKey:AptosSendCrypto.publicKey(privateKey:key),decimals:8,amount:"1")
        let bad=AptosSendPlan(network:q.network,sender:q.sender,recipient:q.recipient,reference:q.reference,publicKey:q.publicKey,decimals:q.decimals,requestedAmount:q.requestedAmount,amount:q.amount,assetBalance:q.assetBalance,nativeBalance:q.nativeBalance,sequence:q.sequence,gasUnitPrice:q.gasUnitPrice,maxGasAmount:max(1000,q.maxGasAmount/2),expiration:q.expiration,createdAt:q.createdAt)
        let signed=try AptosSendCrypto.sign(bad,privateKey:key),receipt=try await settle(signed,bad)
        XCTAssertEqual(receipt.outcome,.failed)
        let after=try await client.balance(owner:sender,reference:"native",version:receipt.version),to=try await client.balance(owner:fresh,reference:"native",version:receipt.version)
        XCTAssertEqual(to,0);XCTAssertEqual(bad.nativeBalance-after,try XCTUnwrap(receipt.fee))
        print("APTOS_TESTNET_FAILED_EXECUTION hash=\(signed.hash) no_recipient_credit=true actual_gas_recorded=true")
    }

}

/// This live check can only read or simulate with the client's zero-signature
/// probe. A transaction submission is rejected before reaching the transport.
private actor AptosSimulationOnlyTransport: AnkrTransport {
    private let base = AptosLivePacedTransport()
    private(set) var calls = 0
    private(set) var simulations = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.url?.host == "api.testnet.aptoslabs.com",
              request.httpMethod == "GET" || (request.httpMethod == "POST" &&
                ["/v1/view", "/v1/transactions/simulate"].contains(request.url?.path ?? "")) else {
            throw AptosSendError.configuration
        }
        calls += 1
        if request.url?.path == "/v1/transactions/simulate" { simulations += 1 }
        return try await base.send(request)
    }
}

/// Keep opt-in live test assertions within the public endpoint quota. Production
/// uses its own bounded client plus the configured ANKR mainnet provider.
private actor AptosLivePacedTransport: AnkrTransport {
    let base=AnkrHTTPTransport();var next=Date.distantPast
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let now=Date.now,start=max(now,next);next=start.addingTimeInterval(0.6)
        if start>now { try await Task.sleep(for:.seconds(start.timeIntervalSince(now))) }
        for attempt in 0..<4 {
            let result=try await base.send(request)
            if result.1 != 429 || attempt==3 { return result }
            // Same request and signed bytes only; public testnet quota backoff.
            try await Task.sleep(for:.seconds(5*(attempt+1)))
        }
        throw AptosSendError.transport
    }
}

private struct AptosMainnetReadOnlyTransport:AnkrTransport {
    let base=AnkrHTTPTransport()
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        guard request.url?.host=="rpc.ankr.com",request.httpMethod=="GET" || (request.httpMethod=="POST" && request.url?.path.hasSuffix("/view")==true) else { throw AptosSendError.configuration }
        return try await base.send(request)
    }
}
