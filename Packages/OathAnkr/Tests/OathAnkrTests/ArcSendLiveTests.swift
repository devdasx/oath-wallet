import XCTest
@testable import OathAnkr

/// Free isolated testnet funds only. Uses the production Swift quote, EIP-1559
/// signer, broadcaster and receipt verifier, never an SDK to perform the sends.
@MainActor final class ArcSendLiveTests:XCTestCase {
    struct Fixture:Decodable { let privateKey:String,sender:String,recipient:String }
    let eurc="0x89b50855aa3be2f677cd6303cec089b5f319d72a"
    private func rpc(_ method:String,_ params:[SolanaJSON]) async throws -> SolanaJSON {
        var request=URLRequest(url:ArcSendNetwork.testnet.endpoints[0]);request.httpMethod="POST";request.timeoutInterval=15
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try JSONEncoder().encode(SolanaJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string(method),"params":.array(params)]))
        let (data,status)=try await AnkrHTTPTransport().send(request);XCTAssertEqual(status,200)
        let j=try JSONDecoder().decode(SolanaJSON.self,from:data)
        guard j["error"].isNull else { throw ArcSendError.malformed };return j["result"]
    }
    func testPublicTestnetFeeAndNetwork() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ARC_PUBLIC_QUOTE"]=="1" else { throw XCTSkip("Opt-in public testnet reads") }
        let chain=try await ArcSendClient.uint(rpc("eth_chainId",[]));XCTAssertEqual(chain,5042002)
        let block=try await rpc("eth_getBlockByNumber",[.string("latest"),.bool(true)])
        let height=try ArcSendClient.uint(block["number"])
        let gas=try await ArcSendClient.uint(rpc("eth_gasPrice",[]));XCTAssertGreaterThan(gas,0)
        let final=try await rpc("eth_getBlockByNumber",[.string("finalized"),.bool(false)])
        XCTAssertGreaterThan(try ArcSendClient.uint(final["number"]),0)
        let decimals=try await ArcSendClient.uint(rpc("eth_call",[.object(["to":.string(eurc),"data":.string("0x313ce567")]),.string("latest")]))
        XCTAssertEqual(decimals,6)
        // Public chain data only, no keys: simulate from an existing EOA. This
        // validates RPC shapes/gas behavior but is not a broadcast proof.
        var prepared=false
        for row in (block["transactions"].array ?? []).prefix(12) {
            guard let sender=row["from"].string else { continue }
            let code=try await rpc("eth_getCode",[.string(sender),.string("latest")])
            if code.string != "0x" { continue }
            let client=ArcSendClient(network:.testnet)
            do {
                let p=try await client.quote(sender:sender,recipient:"0x"+String(repeating:"2",count:40),reference:"native",decimals:18,amount:"1000000000000")
                try await client.preflight(p);prepared=true
                print("ARC_TESTNET_READ_ONLY fee_ceiling=\(p.fee) gas=\(p.gasLimit) simulated=true broadcast=false");break
            } catch ArcSendError.busy { continue }
              catch ArcSendError.insufficientFunds { continue }
        }
        XCTAssertTrue(prepared,"Need a funded public testnet EOA for read-only simulation")
        print("ARC_TESTNET_NETWORK chain=\(chain) height=\(height) gas_price=\(gas) EURC_decimals=\(decimals)")
    }
    private func execute(_ p:ArcSendPlan,key:Data,client:ArcSendClient,name:String) async throws -> ArcSendReceipt {
        try await client.preflight(p)
        let signed=try ArcSendCrypto.sign(p,privateKey:key)
        let dir=URL(fileURLWithPath:"/tmp/oath-arc-live")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        try JSONEncoder().encode(p).write(to:dir.appendingPathComponent("plan-\(name).json"))
        try JSONEncoder().encode(signed).write(to:dir.appendingPathComponent("signed-\(name).json"))
        let submitted=try await client.submit(signed,plan:p)
        XCTAssertTrue([.accepted,.confirmed].contains(submitted.outcome))
        let resumed=ArcSendClient(network:.testnet)
        var receipt=submitted
        for _ in 0..<30 {
            if [.confirmed,.failed,.replaced,.cancelled].contains(receipt.outcome) { break }
            try await Task.sleep(for:.seconds(2));receipt=try await resumed.status(signed,plan:p)
        }
        XCTAssertEqual(receipt.outcome,.confirmed);XCTAssertNotNil(receipt.height);XCTAssertNotNil(receipt.fee)
        let replay=try await resumed.submit(signed,plan:p);XCTAssertEqual(replay.outcome,.confirmed)
        print("ARC_TESTNET_CONFIRMED kind=\(name) hash=\(signed.hash) actual_fee=\(receipt.fee ?? 0) replay_did_not_resend=true")
        return receipt
    }
    func testLiveNativeTokenAndMax() async throws {
        guard let path=ProcessInfo.processInfo.environment["OATH_ARC_TESTNET_FIXTURE"] else { throw XCTSkip("Opt-in funded test wallet required") }
        let f=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        var key=try TronIdentity.hex(f.privateKey);defer { key.resetBytes(in:0..<key.count) }
        XCTAssertEqual(try ArcSendCrypto.address(privateKey:key),f.sender)
        let client=ArcSendClient(network:.testnet)
        for (name,ref,amount,max) in [("native","native","1000000000000000",false),("eurc",eurc,"1000",false),("eurc-max",eurc,"1",true)] {
            let senderBefore=try await client.balance(owner:f.sender,reference:ref),recipientBefore=try await client.balance(owner:f.recipient,reference:ref)
            let gasBefore=try await client.balance(owner:f.sender,reference:"native")
            let p=try await client.quote(sender:f.sender,recipient:f.recipient,reference:ref,decimals:ref=="native" ? 18:6,amount:amount,maximum:max)
            let receipt=try await execute(p,key:key,client:client,name:name)
            let senderAfter=try await client.balance(owner:f.sender,reference:ref),recipientAfter=try await client.balance(owner:f.recipient,reference:ref)
            let gasAfter=try await client.balance(owner:f.sender,reference:"native")
            let fee=try XCTUnwrap(receipt.fee)
            XCTAssertEqual(try ArcSendAmount.subtract(recipientAfter,recipientBefore),p.amount)
            XCTAssertEqual(try ArcSendAmount.subtract(senderBefore,senderAfter),try ArcSendAmount.add(p.amount,ref=="native" ? String(fee):"0"))
            XCTAssertEqual(try ArcSendAmount.subtract(gasBefore,gasAfter),try ArcSendAmount.add(ref=="native" ? p.amount:"0",String(fee)))
            if max { XCTAssertEqual(senderAfter,"0") }
        }
    }
}
