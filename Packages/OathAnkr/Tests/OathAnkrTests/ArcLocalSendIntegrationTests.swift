import XCTest
@testable import OathAnkr

/// Loopback EVM execution is separate from public Arc testnet evidence. Only
/// transport routing changes: production message construction and signing run.
struct ArcLocalTransport:AnkrTransport {
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        var request=request;request.url=URL(string:"http://127.0.0.1:18542")!
        return try await AnkrHTTPTransport().send(request)
    }
}
@MainActor final class ArcLocalSendIntegrationTests:XCTestCase {
    func testNativeERC20MaxAndRejectionOnRealEVM() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ARC_LOCAL_EVM"]=="1" else { throw XCTSkip("Opt-in loopback EVM execution") }
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"/tmp/oath-arc-local-fixture.json"))) as? [String:String])
        let sender=try XCTUnwrap(json["sender"]),recipient=try XCTUnwrap(json["recipient"]),token=try XCTUnwrap(json["Token"]).lowercased()
        let client=ArcSendClient(network:.testnet,transport:ArcLocalTransport()),key=Data(repeating:1,count:32)
        // Run rejection checks with ample gas funds. Otherwise an empty wallet
        // could satisfy a broad throws assertion before the contract is executed.
        do {
            _ = try await client.quote(sender:sender,recipient:recipient,reference:try XCTUnwrap(json["FalseToken"]),decimals:6,amount:"1")
            XCTFail("A false-return token must not be signable")
        } catch { XCTAssertEqual(error as? ArcSendError,.simulationFailed) }
        do {
            _ = try await client.quote(sender:sender,recipient:try XCTUnwrap(json["Reject"]),reference:"native",decimals:18,amount:"1")
            XCTFail("A reverting transfer must not be signable")
        } catch {
            guard case ArcSendError.rpc = error else { return XCTFail("Expected an execution RPC rejection, got \(String(describing:error as? ArcSendError))") }
        }
        for (ref,max) in [("native",false),(token,false),(token,true),("native",true)] {
            let balance=try await client.balance(owner:sender,reference:ref),before=try await client.balance(owner:recipient,reference:ref)
            let gasBefore=try await client.balance(owner:sender,reference:"native")
            let p=try await client.quote(sender:sender,recipient:recipient,reference:ref,decimals:ref=="native" ? 18:6,amount:ref=="native" ? "123456789012345678":"12345",maximum:max)
            try await client.preflight(p)
            let signed=try ArcSendCrypto.sign(p,privateKey:key),accepted=try await client.submit(signed,plan:p)
            XCTAssertEqual(accepted.outcome,.accepted)
            let receipt=try await client.status(signed,plan:p)
            XCTAssertEqual(receipt.outcome,.confirmed)
            let after=try await client.balance(owner:recipient,reference:ref),remaining=try await client.balance(owner:sender,reference:ref)
            let gasAfter=try await client.balance(owner:sender,reference:"native"),fee=try XCTUnwrap(receipt.fee)
            XCTAssertEqual(try ArcSendAmount.subtract(after,before),p.amount)
            XCTAssertEqual(try ArcSendAmount.subtract(balance,remaining),try ArcSendAmount.add(p.amount,ref=="native" ? String(fee):"0"))
            XCTAssertEqual(try ArcSendAmount.subtract(gasBefore,gasAfter),try ArcSendAmount.add(ref=="native" ? p.amount:"0",String(fee)))
            XCTAssertLessThanOrEqual(fee,p.fee)
            if max,ref != "native" { XCTAssertEqual(remaining,"0") }
            let duplicate=try await client.submit(signed,plan:p);XCTAssertEqual(duplicate.outcome,.confirmed)
            let afterReplay=try await client.balance(owner:recipient,reference:ref);XCTAssertEqual(afterReplay,after)
            print("ARC_LOCAL_EVM_CONFIRMED kind=\(ref=="native" ? "USDC":"ERC20") max=\(max) fee=\(fee) exact_balance_delta=true")
        }
    }
}
