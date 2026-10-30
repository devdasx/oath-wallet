import XCTest
@testable import OathAnkr

private struct EVMPendingLocalTransport: AnkrTransport {
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        var request=request;request.url=URL(string:"http://127.0.0.1:18549")!
        return try await AnkrHTTPTransport().send(request)
    }
}

/// Requires a dedicated loopback Anvil fixture with automining disabled and a
/// six-decimal ERC-20. Executes production quote, sign, submit and receipt logic.
/// This is real local EVM execution, not mainnet or physical-device evidence.
@MainActor final class EVMPendingLocalSendIntegrationTests:XCTestCase {
    func testTwoTokenPaymentsAndNativePaymentQueueBeforeMining() async throws {
        guard ProcessInfo.processInfo.environment["OATH_EVM_PENDING_LOCAL"]=="1" else { throw XCTSkip("Opt-in dedicated local EVM fixture") }
        let fixturePath=try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_EVM_PENDING_FIXTURE"])
        let fixture=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:fixturePath)))
        let sender=try XCTUnwrap(fixture["sender"]),recipient=try XCTUnwrap(fixture["recipient"]),token=try XCTUnwrap(fixture["token"])
        let client=try EVMSendClient(network:.ethereum,endpoints:[URL(string:"https://loopback.invalid")!],transport:EVMPendingLocalTransport())
        let key=Data(repeating:1,count:32)
        let nativeBefore=try await client.balance(owner:sender,reference:"native")
        let tokenBefore=try await client.balance(owner:sender,reference:token)
        let receivedBefore=try await client.balance(owner:recipient,reference:token)
        let recipientNativeBefore=try await client.balance(owner:recipient,reference:"native")
        var reservations=[EVMSendReservation](),sent=[(EVMSendPlan,EVMSignedSend)]()
        for reference in [token,token,"native"] {
            let amount=reference=="native" ? "123456789000000":"1250000"
            let plan=try await client.quote(sender:sender,recipient:recipient,reference:reference,decimals:reference=="native" ? 18:6,amount:amount,reservations:reservations)
            if let previous=sent.last { XCTAssertEqual(plan.nonce,previous.0.nonce+1) }
            try await client.preflight(plan)
            let signed=try EVMSendCrypto.sign(plan,privateKey:key)
            let accepted=try await client.submit(signed,plan:plan,reconcileFirst:false)
            XCTAssertEqual(accepted.outcome,.accepted)
            let status=try await client.status(signed,plan:plan)
            XCTAssertEqual(status.outcome,.accepted,"Each earlier payment is still unmined")
            reservations.append(try EVMSendReservation(plan:plan,hash:signed.hash));sent.append((plan,signed))
        }
        let stillUnmined=try await client.balance(owner:recipient,reference:token)
        XCTAssertEqual(stillUnmined,receivedBefore)
        do {
            _ = try await client.quote(sender:sender,recipient:recipient,reference:token,decimals:6,amount:tokenBefore,reservations:reservations)
            XCTFail("Pending payments cannot spend the same tokens twice")
        } catch { XCTAssertEqual(error as? EVMSendError,.insufficientFunds) }
        var request=URLRequest(url:URL(string:"http://127.0.0.1:18549")!);request.httpMethod="POST"
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        // Anvil's finalized tag trails latest by 64 blocks. Mine past that
        // boundary; inclusion alone must never satisfy the receipt assertion.
        request.httpBody=Data(#"{"jsonrpc":"2.0","id":1,"method":"anvil_mine","params":["0x80"]}"#.utf8)
        let (data,status)=try await AnkrHTTPTransport().send(request)
        XCTAssertEqual(status,200);XCTAssertTrue(try JSONDecoder().decode(SolanaJSON.self,from:data)["error"].isNull)
        var fees="0"
        for (plan,signed) in sent {
            let receipt=try await client.status(signed,plan:plan)
            XCTAssertEqual(receipt.outcome,.confirmed)
            fees=try EVMSendAmount.add(fees,String(XCTUnwrap(receipt.fee)))
        }
        let tokenAfter=try await client.balance(owner:sender,reference:token)
        let receivedAfter=try await client.balance(owner:recipient,reference:token)
        let nativeAfter=try await client.balance(owner:sender,reference:"native")
        let recipientNativeAfter=try await client.balance(owner:recipient,reference:"native")
        XCTAssertEqual(try EVMSendAmount.subtract(tokenBefore,tokenAfter),"2500000")
        XCTAssertEqual(try EVMSendAmount.subtract(receivedAfter,receivedBefore),"2500000")
        XCTAssertEqual(try EVMSendAmount.subtract(recipientNativeAfter,recipientNativeBefore),"123456789000000")
        XCTAssertEqual(try EVMSendAmount.subtract(nativeBefore,nativeAfter),try EVMSendAmount.add(fees,"123456789000000"))
    }
}
