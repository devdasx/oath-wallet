import XCTest
import CryptoKit
@testable import OathAnkr

@MainActor final class TronSendTests:XCTestCase {
    func testOfficialTronWebEncodingAndSignatures() throws {
        let url=Bundle.module.url(forResource:"sdk-vector",withExtension:"json",subdirectory:"Fixtures/TronSend")!
        let v=try JSONDecoder().decode(TronJSON.self,from:Data(contentsOf:url)),key=try TronIdentity.hex(v["key"].string!)
        XCTAssertEqual(try TronSendCrypto.address(privateKey:key),v["sender"].string)
        for row in v["vectors"].array! {
            let timestamp=v["timestamp"].integer!,ref=row["reference"].string!,limit=row["feeLimit"].integer!
            let plan=TronSendPlan(network:.nile,sender:v["sender"].string!,recipient:v["recipient"].string!,reference:ref,amount:"1234567",requestedAmount:"1234567",assetBalance:ref=="native" ? "1000000000":"10000000",decimals:6,nativeBalance:1_000_000_000,fee:limit+1_000_000,estimatedFee:limit,feeLimit:limit,energyPrice:100,bandwidthPrice:1000,blockID:v["blockID"].string!,blockNumber:71803059,timestamp:timestamp,expiration:timestamp+180000,createdAt:Date(timeIntervalSince1970:Double(timestamp)/1000))
            let signed=try TronSendCrypto.sign(plan,privateKey:key,now:plan.createdAt)
            XCTAssertEqual(TronSendCrypto.hex(try TronSendCrypto.raw(plan)),row["raw"].string)
            XCTAssertEqual(signed.hash,row["hash"].string)
            XCTAssertEqual(TronSendCrypto.hex(signed.signature),row["signature"].string?.lowercased())
            XCTAssertEqual(TronSendCrypto.hex(signed.bytes),row["bytes"].string)
            try TronSendCrypto.verify(signed,plan:plan)
            var bad=signed.bytes;bad[20]^=1
            XCTAssertThrowsError(try TronSendCrypto.verify(.init(bytes:bad,signature:signed.signature,hash:signed.hash),plan:plan))
            XCTAssertThrowsError(try TronSendCrypto.sign(plan,privateKey:Data(repeating:8,count:32),now:plan.createdAt))
        }
    }
    func testKeccakAndUint256Boundaries() throws {
        XCTAssertEqual(TronSendCrypto.hex(TronSendCrypto.keccak(Data())),"c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        for (length,hash) in [(135,"34367dc248bbd832f4e3e69dfaac2f92638bd0bbd18f2912ba4ef454919cf446"),(136,"a6c4d403279fe3e0af03729caada8374b5ca54d8065329a3ebcaeb4b60aa386e"),(271,"132f47effd6c8b1b299efa53fe68aece77ec8ae4eb2e294f668eec94f76001e1")] {
            XCTAssertEqual(TronSendCrypto.hex(TronSendCrypto.keccak(Data(repeating:0x61,count:length))),hash)
        }
        XCTAssertEqual(try TronSendCrypto.uint256("115792089237316195423570985008687907853269984665640564039457584007913129639935"),Data(repeating:255,count:32))
        XCTAssertThrowsError(try TronSendCrypto.uint256("115792089237316195423570985008687907853269984665640564039457584007913129639936"))
        XCTAssertThrowsError(try TronSendCrypto.uint256("-1"))
    }
    func testLiveMainnetPrimaryQuoteReadOnly() async throws {
        guard let key=ProcessInfo.processInfo.environment["OATH_TRON_PRIMARY_KEY"] else {throw XCTSkip("Opt-in ANKR mainnet read-only quote")}
        let client=try TronSendClient(network:.mainnet,apiKey:key,transport:TronPrimaryOnlyTransport())
        let start=Date.now
        let quote=try await client.quote(sender:TronTests.owner,recipient:TronSendCrypto.address(privateKey:Data(repeating:8,count:32)),reference:"native",decimals:6,amount:"1000")
        XCTAssertEqual(quote.network,.mainnet);XCTAssertEqual(quote.amount,"1000");try quote.validate()
        print("ANKR MAINNET READ-ONLY quote passed in \(Date.now.timeIntervalSince(start)) seconds; fee allowance SUN=\(quote.fee). No signing or broadcast.")
    }
    func testLiveNileExpiryProofDoesNotBroadcast() async throws {
        guard let path=ProcessInfo.processInfo.environment["OATH_TRON_TESTNET_FIXTURE"] else {throw XCTSkip("Opt-in Nile fixture, no broadcast")}
        let f=try JSONDecoder().decode(TronJSON.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let transport=TronNoBroadcastTransport(),client=try TronSendClient(network:.nile,transport:transport)
        let p=try await client.quote(sender:f["sender"].string!,recipient:f["recipient"].string!,reference:"native",decimals:6,amount:"1")
        var request=URLRequest(url:TronSendNetwork.nile.endpoint.appendingPathComponent("wallet/getblockbynum"));request.httpMethod="POST";request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try JSONEncoder().encode(TronJSON.object(["num":.number(String(p.blockNumber-100))]))
        let (bytes,status)=try await transport.send(request);XCTAssertEqual(status,200)
        let block=try JSONDecoder().decode(TronJSON.self,from:bytes),time=try XCTUnwrap(block["block_header"]["raw_data"]["timestamp"].integer)
        let plan=TronSendPlan(network:p.network,sender:p.sender,recipient:p.recipient,reference:p.reference,amount:p.amount,requestedAmount:p.requestedAmount,assetBalance:p.assetBalance,decimals:p.decimals,nativeBalance:p.nativeBalance,fee:p.fee,estimatedFee:p.estimatedFee,feeLimit:p.feeLimit,energyPrice:p.energyPrice,bandwidthPrice:p.bandwidthPrice,blockID:try XCTUnwrap(block["blockID"].string),blockNumber:p.blockNumber-100,timestamp:time,expiration:time+180000,createdAt:Date(timeIntervalSince1970:Double(time)/1000))
        let signed=try TronSendCrypto.sign(plan,privateKey:TronIdentity.hex(f["key"].string!),now:plan.createdAt)
        let result=try await client.submit(signed,plan:plan)
        XCTAssertEqual(result.outcome,.expired);XCTAssertNil(result.fee)
        print("NILE verified complete solid-block expiry proof; transport forbids broadcast.")
    }
    func testLiveNileTransfers() async throws {
        guard let path=ProcessInfo.processInfo.environment["OATH_TRON_TESTNET_FIXTURE"] else { throw XCTSkip("Opt-in faucet-funded Nile accounts") }
        let f=try JSONDecoder().decode(TronJSON.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let key=try TronIdentity.hex(f["key"].string!),sender=f["sender"].string!,recipient=f["recipient"].string!
        let client=try TronSendClient(network:.nile)
        for (reference,decimals,amount) in [("native",6,"1234567"),("1005416",6,"1234567"),("TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf",6,"1234567")] {
            if let only=ProcessInfo.processInfo.environment["OATH_TRON_TEST_REFERENCE"],only != reference { continue }
            let before=try await client.balance(owner:recipient,reference:reference)
            let senderBefore=try await client.balance(owner:sender,reference:"native")
            let plan=try await client.quote(sender:sender,recipient:recipient,reference:reference,decimals:decimals,amount:amount)
            let signed=try TronSendCrypto.sign(plan,privateKey:key)
            var receipt=try await client.submit(signed,plan:plan)
            for _ in 0..<35 where receipt.requiresConfirmation {
                try await Task.sleep(for:.seconds(3));receipt=try await client.status(signed,plan:plan)
            }
            XCTAssertEqual(receipt.outcome,.confirmed)
            guard receipt.outcome == .confirmed,let fee=receipt.fee else { XCTFail("No solid success");return }
            let after=try await client.balance(owner:recipient,reference:reference)
            XCTAssertEqual(StellarIdentity.sum(after,"-"+before),plan.amount)
            let senderAfter=try await client.balance(owner:sender,reference:"native")
            XCTAssertEqual(StellarIdentity.sum(senderBefore,"-"+senderAfter),String(fee+(reference=="native" ? UInt64(plan.amount)!:0)))
            XCTAssertLessThanOrEqual(fee,plan.fee)
            let retry=try await client.submit(signed,plan:plan);XCTAssertEqual(retry,receipt)
            let unchanged=try await client.balance(owner:recipient,reference:reference);XCTAssertEqual(unchanged,after)
            print("NILE VERIFIED \(reference == "native" ? "TRX":reference == "1005416" ? "TRC10":"TRC20") hash=\(signed.hash) feeSUN=\(fee) received=\(plan.amount)")
        }
    }
    func testLiveNileTokenMaximumAndExecutionFailure() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TRON_EXTENDED_TESTS"] == "1",let path=ProcessInfo.processInfo.environment["OATH_TRON_TESTNET_FIXTURE"] else { throw XCTSkip("Opt-in funded Nile contract fixture and OATH_TRON_EXTENDED_TESTS=1") }
        let f=try JSONDecoder().decode(TronJSON.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let key=try TronIdentity.hex(f["key"].string!),sender=f["sender"].string!,recipient=f["recipient"].string!,contract=try XCTUnwrap(f["contract"].string)
        let client=try TronSendClient(network:.nile)
        func execute(_ plan:TronSendPlan,_ signingKey:Data,expected:TronSendReceipt.Outcome = .confirmed) async throws {
            let before=try await client.balance(owner:plan.recipient,reference:plan.reference)
            let payerBefore=try await client.balance(owner:plan.sender,reference:"native")
            let signed=try TronSendCrypto.sign(plan,privateKey:signingKey)
            var result=try await client.submit(signed,plan:plan)
            for _ in 0..<40 where result.requiresConfirmation {try await Task.sleep(for:.seconds(3));result=try await client.status(signed,plan:plan)}
            XCTAssertEqual(result.outcome,expected);guard result.outcome==expected,let fee=result.fee else {throw TronSendError.execution}
            let after=try await client.balance(owner:plan.recipient,reference:plan.reference)
            XCTAssertEqual(StellarIdentity.sum(after,"-"+before),expected == .confirmed ? plan.amount:"0")
            let payerAfter=try await client.balance(owner:plan.sender,reference:"native")
            XCTAssertEqual(StellarIdentity.sum(payerBefore,"-"+payerAfter),String(fee+(expected == .confirmed && plan.reference=="native" ? UInt64(plan.amount)!:0)))
            XCTAssertLessThanOrEqual(fee,plan.fee)
            let retry=try await client.submit(signed,plan:plan);XCTAssertEqual(retry,result)
            print("NILE EXTENDED \(expected.rawValue) asset=\(plan.reference) hash=\(signed.hash) feeSUN=\(fee) amount=\(plan.amount)")
        }
        let standard=try await client.quote(sender:sender,recipient:recipient,reference:contract,decimals:6,amount:"1234567")
        try await execute(standard,key)
        let p=try await client.quote(sender:sender,recipient:recipient,reference:contract,decimals:6,amount:"1")
        // Deliberately underfund energy on a test-only contract. This proves that
        // accepted broadcasts with failed execution never become successful sends.
        let failure=TronSendPlan(network:p.network,sender:sender,recipient:recipient,reference:contract,amount:p.amount,requestedAmount:p.requestedAmount,assetBalance:p.assetBalance,decimals:p.decimals,nativeBalance:p.nativeBalance,fee:1_000_000,estimatedFee:10_000,feeLimit:10_000,energyPrice:p.energyPrice,bandwidthPrice:p.bandwidthPrice,blockID:p.blockID,blockNumber:p.blockNumber,timestamp:p.timestamp,expiration:p.expiration,createdAt:p.createdAt)
        try await execute(failure,key,expected:.failed)
        for reference in [contract,"1005416"] {
            let maximum=try await client.quote(sender:sender,recipient:recipient,reference:reference,decimals:6,amount:"1",maximum:true)
            XCTAssertEqual(maximum.amount,maximum.assetBalance)
            try await execute(maximum,key)
            let remaining=try await client.balance(owner:sender,reference:reference);XCTAssertEqual(remaining,"0")
        }
        let native=try await client.quote(sender:recipient,recipient:sender,reference:"native",decimals:6,amount:"1",maximum:true)
        XCTAssertEqual(UInt64(native.amount)!+native.fee,native.nativeBalance)
        try await execute(native,TronIdentity.hex(f["recipientKey"].string!))
    }

}

private struct TronPrimaryOnlyTransport:AnkrTransport {
    let base=AnkrHTTPTransport()
    func send(_ request:URLRequest) async throws ->(Data,Int) {
        guard request.url?.host=="rpc.ankr.com",request.url?.lastPathComponent != "broadcasthex" else {throw TronSendError.configuration}
        return try await base.send(request)
    }
}

private struct TronNoBroadcastTransport:AnkrTransport {
    let base=AnkrHTTPTransport()
    func send(_ request:URLRequest) async throws ->(Data,Int) {
        guard request.url?.host=="nile.trongrid.io",request.url?.lastPathComponent != "broadcasthex" else {throw TronSendError.configuration}
        return try await base.send(request)
    }
}
