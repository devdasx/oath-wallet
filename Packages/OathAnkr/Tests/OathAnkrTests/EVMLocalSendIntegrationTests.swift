import XCTest
@testable import OathAnkr

/// Loopback EVM execution is separate from public testnet evidence. Only
/// transport routing changes: production message construction and signing run.
struct EVMLocalTransport:AnkrTransport {
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        var request=request;request.url=URL(string:"http://127.0.0.1:" + (ProcessInfo.processInfo.environment["OATH_EVM_LOCAL_PORT"] ?? "18543"))!
        return try await AnkrHTTPTransport().send(request)
    }
}
@MainActor final class EVMLocalSendIntegrationTests:XCTestCase {
    func testNativeERC20MaxAndRejectionOnRealEVM() async throws {
        guard ProcessInfo.processInfo.environment["OATH_EVM_LOCAL"]=="1" else { throw XCTSkip("Opt-in loopback EVM execution") }
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:ProcessInfo.processInfo.environment["OATH_EVM_LOCAL_FIXTURE"] ?? "/tmp/oath-evm-local-fixture.json"))) as? [String:String])
        let sender=try XCTUnwrap(json["sender"]),recipient=try XCTUnwrap(json["recipient"]),token=try XCTUnwrap(json["Token"]).lowercased()
        let network: EVMSendNetwork = ProcessInfo.processInfo.environment["OATH_EVM_LOCAL_NETWORK"] == "chiliz" ? .chiliz : .arbitrum
        let client=try EVMSendClient(network:network,endpoints:[URL(string:"https://loopback.example")!],transport:EVMLocalTransport()),key=Data(repeating:1,count:32)
        // Run rejection checks with ample gas funds. Otherwise an empty wallet
        // could satisfy a broad throws assertion before the contract is executed.
        do {
            _ = try await client.quote(sender:sender,recipient:recipient,reference:try XCTUnwrap(json["FalseToken"]),decimals:6,amount:"1")
            XCTFail("A false-return token must not be signable")
        } catch { XCTAssertEqual(error as? EVMSendError,.simulationFailed) }
        do {
            _ = try await client.quote(sender:sender,recipient:try XCTUnwrap(json["Reject"]),reference:"native",decimals:18,amount:"1")
            XCTFail("A reverting transfer must not be signable")
        } catch {
            guard case EVMSendError.rpc = error else { return XCTFail("Expected an execution RPC rejection, got \(String(describing:error as? EVMSendError))") }
        }
        let payable=try XCTUnwrap(json["Payable"]).lowercased()
        let contractPlan=try await client.quote(sender:sender,recipient:payable,reference:"native",decimals:18,amount:"123")
        let contractSignature=try EVMSendCrypto.sign(contractPlan,privateKey:key)
        _ = try await client.submit(contractSignature,plan:contractPlan)
        let contractReceipt=try await client.status(contractSignature,plan:contractPlan)
        XCTAssertEqual(contractReceipt.outcome,.confirmed)
        let received=try await client.balance(owner:payable,reference:"native")
        XCTAssertEqual(received,"123")
        for (ref,max) in [("native",false),(token,false),(token,true),("native",true)] {
            let balance=try await client.balance(owner:sender,reference:ref),before=try await client.balance(owner:recipient,reference:ref)
            let gasBefore=try await client.balance(owner:sender,reference:"native")
            let p=try await client.quote(sender:sender,recipient:recipient,reference:ref,decimals:ref=="native" ? 18:6,amount:ref=="native" ? "123456789012345678":"12345",maximum:max)
            try await client.preflight(p)
            let signed=try EVMSendCrypto.sign(p,privateKey:key),accepted=try await client.submit(signed,plan:p)
            XCTAssertEqual(accepted.outcome,.accepted)
            let receipt=try await client.status(signed,plan:p)
            XCTAssertEqual(receipt.outcome,.confirmed)
            let after=try await client.balance(owner:recipient,reference:ref),remaining=try await client.balance(owner:sender,reference:ref)
            let gasAfter=try await client.balance(owner:sender,reference:"native"),fee=try XCTUnwrap(receipt.fee)
            XCTAssertEqual(try EVMSendAmount.subtract(after,before),p.amount)
            XCTAssertEqual(try EVMSendAmount.subtract(balance,remaining),try EVMSendAmount.add(p.amount,ref=="native" ? String(fee):"0"))
            XCTAssertEqual(try EVMSendAmount.subtract(gasBefore,gasAfter),try EVMSendAmount.add(ref=="native" ? p.amount:"0",String(fee)))
            XCTAssertLessThanOrEqual(fee,p.fee)
            if max,ref != "native" { XCTAssertEqual(remaining,"0") }
            let duplicate=try await client.submit(signed,plan:p);XCTAssertEqual(duplicate.outcome,.confirmed)
            let afterReplay=try await client.balance(owner:recipient,reference:ref);XCTAssertEqual(afterReplay,after)
            print("EVM_LOCAL_EVM_CONFIRMED kind=\(ref=="native" ? network.symbol:"ERC20") max=\(max) fee=\(fee) exact_balance_delta=true")
        }
    }
}
