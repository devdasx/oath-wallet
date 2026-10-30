import XCTest
@testable import OathAnkr

final class PermissionTests:XCTestCase {
    let contract="0x"+String(repeating:"3",count:40),spender="0x"+String(repeating:"2",count:40)
    func testRemovalCalldataHasNoValueOrSpenderApproval() throws {
        let r=EVMPermissionRemoval(kind:.token,contract:contract,spender:spender,expected:"100")
        let data=try r.calldata()
        XCTAssertEqual(TronSendCrypto.hex(data),"095ea7b3"+String(repeating:"0",count:24)+String(repeating:"2",count:40)+String(repeating:"0",count:64))
        let nft=EVMPermissionRemoval(kind:.collectible,contract:contract,spender:spender,tokenID:"7",expected:spender)
        XCTAssertEqual(try nft.calldata().count,68)
        XCTAssertEqual(try nft.calldata().dropFirst(4).prefix(32),Data(repeating:0,count:32))
        let collection=EVMPermissionRemoval(kind:.collection,contract:contract,spender:spender,expected:"1")
        XCTAssertEqual(try TronSendCrypto.hex(collection.calldata().prefix(4)),"a22cb465")
        XCTAssertEqual(try collection.calldata().suffix(32),Data(repeating:0,count:32))
    }
    func testMalformedOrAlreadyRemovedPermissionsCannotBeSigned() throws {
        for r in [EVMPermissionRemoval(kind:.token,contract:contract,spender:spender,expected:"0"),
                  .init(kind:.token,contract:contract,spender:spender,expected:"-1"),
                  .init(kind:.token,contract:contract,spender:EVMPermissionRemoval.zero,expected:"1"),
                  .init(kind:.collection,contract:contract,spender:spender,expected:"2"),
                  .init(kind:.collectible,contract:contract,spender:spender,tokenID:"7",expected:contract),
                  .init(kind:.permit2,contract:contract,spender:spender,tokenID:contract,expected:"1:2:3"),
                  .init(kind:.permit2Nonce,contract:EVMPermissionRemoval.permit2,spender:spender,tokenID:contract,expected:"1:2:281474976710655")] {
            XCTAssertThrowsError(try r.calldata())
        }
    }
    func testSignedRemovalBoundToExactContractAndNoAssetValue() throws {
        let owner=try EVMSendCrypto.address(privateKey:Data(repeating:1,count:32))
        let p=EVMSendPlan(network:.ethereumSepolia,sender:owner,recipient:contract,reference:"native",decimals:18,requestedAmount:"0",amount:"0",assetBalance:"1000000000000000000",nativeBalance:"1000000000000000000",nonce:0,gasLimit:70000,maxFeePerGas:1000000000,maxPriorityFeePerGas:100000000,blockHeight:1,removal:.init(kind:.token,contract:contract,spender:spender,expected:"123"))
        let signed=try EVMSendCrypto.sign(p,privateKey:Data(repeating:1,count:32));try EVMSendCrypto.verify(signed,plan:p)
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as? [String:Any])
        for (field,value) in [("amount","1" as Any),("requestedAmount","1" as Any),("recipient",spender as Any),("reference",contract as Any),("decimals",6 as Any)] {
            var j=object;j[field]=value
            let altered=try JSONDecoder().decode(EVMSendPlan.self,from:JSONSerialization.data(withJSONObject:j))
            XCTAssertThrowsError(try altered.validate(),field)
            XCTAssertThrowsError(try EVMSendCrypto.verify(signed,plan:altered),field)
        }
        var without=object;without.removeValue(forKey:"removal")
        XCTAssertThrowsError(try JSONDecoder().decode(EVMSendPlan.self,from:JSONSerialization.data(withJSONObject:without)).validate())
    }
    func testEventDiscoveryRejectsOtherOwnerAndSeparatesNFTFromToken() throws {
        let owner="0x"+String(repeating:"1",count:40)
        func event(_ topics:[SolanaJSON])->SolanaJSON { .object(["address":.string(contract),"topics":.array(topics)]) }
        let topics:[SolanaJSON]=[.string(PermissionDiscovery.approval),.string("0x"+TronSendCrypto.hex(try EVMPermissionRemoval.word(owner))),.string("0x"+TronSendCrypto.hex(try EVMPermissionRemoval.word(spender)))]
        XCTAssertEqual(try PermissionDiscovery.candidate(event(topics),network:"ethereum",owner:owner)?.kind,.token)
        XCTAssertEqual(try PermissionDiscovery.candidate(event(topics+[.string("0x"+String(repeating:"0",count:63)+"7")]),network:"ethereum",owner:owner)?.tokenID,"7")
        XCTAssertThrowsError(try PermissionDiscovery.candidate(event(topics),network:"ethereum",owner:spender))
    }
    func testDelegationAuthorizationCannotReplayOrChangeTheApprovedPlan() throws {
        // Public deterministic test keys only. No funded wallet or RPC required.
        let key=Data(repeating:1,count:32),owner=try EVMSendCrypto.address(privateKey:Data(repeating:1,count:32))
        let removal=EVMPermissionRemoval(kind:.delegation,contract:owner,spender:spender,expected:spender)
        func plan(network:EVMSendNetwork = .ethereumSepolia,nonce:UInt64=7,legacy:Bool=false,gas:UInt64=70_000)->EVMSendPlan {
            .init(network:network,sender:owner,recipient:owner,reference:"native",decimals:18,requestedAmount:"0",amount:"0",assetBalance:"1000000000000000000",nativeBalance:"1000000000000000000",nonce:nonce,gasLimit:gas,maxFeePerGas:1_000_000_000,maxPriorityFeePerGas:0,blockHeight:1,legacy:legacy,removal:removal)
        }
        let approved=plan(),signed=try EVMSendCrypto.sign(approved,privateKey:key)
        XCTAssertEqual(signed.bytes.first,4)
        XCTAssertEqual(approved.receiver,EVMPermissionRemoval.zero)
        XCTAssertEqual(approved.value,"0")
        XCTAssertEqual(try EVMSendCrypto.data(approved),Data())
        try EVMSendCrypto.verify(signed,plan:approved)
        XCTAssertThrowsError(try EVMSendCrypto.verify(signed,plan:plan(network:.ethereum)))
        XCTAssertThrowsError(try EVMSendCrypto.verify(signed,plan:plan(nonce:8)))
        XCTAssertThrowsError(try EVMSendCrypto.sign(plan(legacy:true),privateKey:key))
        XCTAssertThrowsError(try EVMSendCrypto.sign(plan(nonce:UInt64.max-1),privateKey:key))
        XCTAssertThrowsError(try EVMSendCrypto.sign(plan(gas:45_999),privateKey:key))
        XCTAssertThrowsError(try EVMSendCrypto.verify(.init(bytes:signed.bytes,signature:signed.signature,hash:signed.hash),plan:approved))
        var changed=try XCTUnwrap(signed.authorizationSignature);changed[0] ^= 1
        XCTAssertThrowsError(try EVMSendCrypto.verify(.init(bytes:signed.bytes,signature:signed.signature,hash:signed.hash,authorizationSignature:changed),plan:approved))
    }
}

private struct PermissionLocalTransport:AnkrTransport {
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        var request=request;request.url=URL(string:"http://127.0.0.1:18547")!;return try await AnkrHTTPTransport().send(request)
    }
}
@MainActor final class PermissionExecutionTests:XCTestCase {
    func testProductionFeeSignBroadcastAndReadbackOnEVM() async throws {
        guard ProcessInfo.processInfo.environment["OATH_PERMISSION_LOCAL"]=="1" else { throw XCTSkip("Opt-in isolated loopback EVM") }
        struct Fixture:Decodable { let sender:String,spender:String,Token:String,FalseToken:String,NFT:String,Operator:String,vectors:[String:String] }
        let f=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:"/tmp/oath-permission-local.json")))
        let client=try EVMSendClient(network:.ethereumSepolia,endpoints:[URL(string:"https://loopback.example")!],transport:PermissionLocalTransport())
        do {
            _ = try await client.quote(sender:f.sender,recipient:f.FalseToken,reference:"native",decimals:18,amount:"0",removal:.init(kind:.token,contract:f.FalseToken,spender:f.spender,expected:"123"))
            XCTFail("False-return approval was accepted")
        } catch { XCTAssertEqual(error as? EVMSendError,.simulationFailed) }
        let operations:[EVMPermissionRemoval]=[
            .init(kind:.token,contract:f.Token,spender:f.spender,expected:"123456"),
            .init(kind:.collectible,contract:f.NFT,spender:f.spender,tokenID:"7",expected:f.spender),
            .init(kind:.collection,contract:f.NFT,spender:f.spender,expected:"1"),
            .init(kind:.collection,contract:f.Operator,spender:f.spender,expected:"1"),
            .init(kind:.permit2,contract:EVMPermissionRemoval.permit2,spender:f.spender,tokenID:f.Token,expected:"1000:2000000000:0"),
            .init(kind:.permit2Nonce,contract:EVMPermissionRemoval.permit2,spender:f.spender,tokenID:f.Token,expected:"0:2000000000:0")]
        for removal in operations {
            XCTAssertEqual("0x"+(try TronSendCrypto.hex(removal.calldata())),f.vectors[removal.kind.rawValue])
            let p=try await client.quote(sender:f.sender,recipient:removal.contract,reference:"native",decimals:18,amount:"0",removal:removal)
            XCTAssertGreaterThan(p.fee,0);try await client.preflight(p)
            let s=try EVMSendCrypto.sign(p,privateKey:Data(repeating:1,count:32))
            let result=try await client.submit(s,plan:p);XCTAssertEqual(result.outcome,.accepted)
            let receipt=try await client.status(s,plan:p);XCTAssertEqual(receipt.outcome,.confirmed)
            XCTAssertLessThanOrEqual(try XCTUnwrap(receipt.fee),p.fee)
            let removed=try await client.permissionRemoved(owner:f.sender,removal:removal);XCTAssertTrue(removed)
            do { try await client.preflight(p);XCTFail("Stale permission plan accepted") } catch {}
            print("PERMISSION_LOCAL_CONFIRMED kind=\(removal.kind.rawValue) fee=\(receipt.fee ?? 0) verified=true")
        }
    }
}

private struct PermissionDelegationTransport:AnkrTransport {
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        var request=request;request.url=URL(string:"http://127.0.0.1:18548")!;return try await AnkrHTTPTransport().send(request)
    }
}
@MainActor final class PermissionDelegationTests:XCTestCase {
    func testClearDelegationExecutesAndNeverAuthorizesAnotherDelegate() async throws {
        guard ProcessInfo.processInfo.environment["OATH_PERMISSION_DELEGATION"]=="1" else {throw XCTSkip("Isolated Prague node required")}
        struct Fixture:Decodable {let sender:String,delegate:String}
        let f=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:"/tmp/oath-permission-delegation.json")))
        let client=try EVMSendClient(network:.ethereumSepolia,endpoints:[URL(string:"https://loopback.example")!],transport:PermissionDelegationTransport())
        let r=EVMPermissionRemoval(kind:.delegation,contract:f.sender,spender:f.delegate,expected:f.delegate)
        let p=try await client.quote(sender:f.sender,recipient:f.sender,reference:"native",decimals:18,amount:"0",removal:r)
        try await client.preflight(p)
        let s=try EVMSendCrypto.sign(p,privateKey:Data(repeating:1,count:32))
        XCTAssertEqual(s.bytes.first,4);XCTAssertEqual(p.receiver,EVMPermissionRemoval.zero);XCTAssertEqual(p.value,"0");XCTAssertEqual(try EVMSendCrypto.data(p),Data())
        try EVMSendCrypto.verify(s,plan:p)
        XCTAssertThrowsError(try EVMSendCrypto.verify(.init(bytes:s.bytes,signature:s.signature,hash:s.hash),plan:p))
        let submitted=try await client.submit(s,plan:p);XCTAssertEqual(submitted.outcome,.accepted)
        var mine=URLRequest(url:URL(string:"http://127.0.0.1:18548")!);mine.httpMethod="POST";mine.setValue("application/json",forHTTPHeaderField:"Content-Type")
        mine.httpBody=Data(#"{"jsonrpc":"2.0","id":1,"method":"anvil_mine","params":["0x40"]}"#.utf8)
        _ = try await AnkrHTTPTransport().send(mine)
        let receipt=try await client.status(s,plan:p);XCTAssertEqual(receipt.outcome,.confirmed)
        let removed=try await client.permissionRemoved(owner:f.sender,removal:r);XCTAssertTrue(removed)
        XCTAssertLessThanOrEqual(try XCTUnwrap(receipt.fee),p.fee)
        // Only public fixture signatures are exported for independent ethers decoding.
        try JSONEncoder().encode(s).write(to:URL(fileURLWithPath:"/tmp/oath-permission-delegation-signed.json"))
        print("PERMISSION_DELEGATION_CONFIRMED fee=\(receipt.fee ?? 0) code_cleared=true")
    }
}

private actor PermissionIndexTransport:AnkrTransport {
    let pages:[SolanaJSON],failRead:Bool
    var page=0
    var tags=[String]()
    init(pages:[SolanaJSON],failRead:Bool=false){self.pages=pages;self.failRead=failRead}
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let j=try JSONDecoder().decode(SolanaJSON.self,from:XCTUnwrap(request.httpBody))
        if j["method"].string=="ankr_getLogs" {
            let result=pages[min(page,pages.count-1)];page+=1
            return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"result":result])),200)
        }
        let rows=try XCTUnwrap(j.array)
        let response=try rows.map { row -> SolanaJSON in
            var result:[String:SolanaJSON]=["jsonrpc":.string("2.0"),"id":row["id"]]
            if row["method"].string=="eth_chainId" {result["result"] = .string("0x1")}
            else {
                tags.append(row["params"].array?.last?.string ?? "")
                if failRead {result["error"] = .object(["code":.number("-32000"),"message":.string("Read unavailable")])}
                else {result["result"] = .string("0x"+TronSendCrypto.hex(try TronSendCrypto.uint256("12")))}
            }
            return .object(result)
        }
        return (try JSONEncoder().encode(SolanaJSON.array(response)),200)
    }
}
@MainActor final class PermissionIndexTests:XCTestCase {
    let owner="0x"+String(repeating:"1",count:40),spender="0x"+String(repeating:"2",count:40),contract="0x"+String(repeating:"3",count:40)
    func page(chain:String="eth",cursor:String?=nil,timestamp:Double=Date.now.timeIntervalSince1970,empty:Bool=false) throws -> SolanaJSON {
        let log:SolanaJSON = .object(["blockchain":.string(chain),"address":.string(contract),"topics":.array([.string(PermissionDiscovery.approval),.string("0x"+TronSendCrypto.hex(try EVMPermissionRemoval.word(owner))),.string("0x"+TronSendCrypto.hex(try EVMPermissionRemoval.word(spender)))])])
        var j:[String:SolanaJSON]=["logs":.array(empty ? []:[log]),"syncStatus":.object(["status":.string("synced"),"timestamp":.number(String(UInt64(timestamp)))])]
        if let cursor {j["nextPageToken"] = .string(cursor)};return .object(j)
    }
    private func run(_ t:PermissionIndexTransport) async throws -> PermissionScan {
        try await PermissionDiscovery(apiKey:"test",transport:t).evm(network:.ethereum,owner:owner,client:EVMSendClient(network:.ethereum,endpoints:[URL(string:"https://fixture.example")!],transport:t))
    }
    func testFreshIndexIsVerifiedAgainstChainAndReadbackUsesReceiptBlock() async throws {
        let t=try PermissionIndexTransport(pages:[page()]);let result=try await run(t)
        XCTAssertEqual(result.coverage,.checked);XCTAssertEqual(result.permissions.first?.amount,"12")
        let client=try EVMSendClient(network:.ethereum,endpoints:[URL(string:"https://fixture.example")!],transport:t)
        _ = try await client.permissionRemoved(owner:owner,removal:.init(kind:.token,contract:contract,spender:spender,expected:"12"),atBlock:123)
        let tags=await t.tags;XCTAssertEqual(tags.last,"0x7b")
    }
    func testWrongChainCannotBecomeSuccessfulEmptyScan() async throws {
        let t=try PermissionIndexTransport(pages:[page(chain:"bsc")])
        do {_ = try await run(t);XCTFail("Wrong-chain index accepted")}catch{XCTAssertEqual(error as? AnkrError,.wrongChain)}
    }
    func testStaleIndexReadFailureAndPaginationLoopStayPartial() async throws {
        let stale=try PermissionIndexTransport(pages:[page(timestamp:Date.now.timeIntervalSince1970-600,empty:true)])
        let a=try await run(stale);XCTAssertEqual(a.coverage,.partial)
        let failed=try PermissionIndexTransport(pages:[page()],failRead:true)
        let b=try await run(failed);XCTAssertEqual(b.coverage,.partial);XCTAssertTrue(b.permissions.isEmpty)
        let loop=try PermissionIndexTransport(pages:[page(cursor:"repeat")])
        let c=try await run(loop);XCTAssertEqual(c.coverage,.partial);XCTAssertEqual(c.permissions.count,1)
        let count=await loop.page;XCTAssertEqual(count,2)
    }
}

final class TronPermissionControlTests:XCTestCase {
    func testRemovingKeyPreservesConfigurationAndRejectsLossOfControl() throws {
        let owner=try TronSendCrypto.address(privateKey:Data(repeating:1,count:32)),external=try TronSendCrypto.address(privateKey:Data(repeating:2,count:32))
        let operations=String(repeating:"7f",count:32)
        func permission(_ id:UInt64,_ threshold:UInt64,_ keys:[TronJSON])->TronJSON {
            var p:[String:TronJSON]=["permission_name":.string(id==0 ? "owner":"active"),"threshold":.number(String(threshold)),"keys":.array(keys)]
            if id>0 {p["id"] = .number(String(id));p["type"] = .string("Active");p["operations"] = .string(operations)}
            return .object(p)
        }
        let ownKey:TronJSON = .object(["address":.string(owner),"weight":.number("1")]),other:TronJSON = .object(["address":.string(external),"weight":.number("1")])
        func config(ownerThreshold:UInt64=1,activeThreshold:UInt64=1)->TronJSON {
            .object(["owner_permission":permission(0,ownerThreshold,[ownKey,other]),"active_permission":.array([permission(2,activeThreshold,[ownKey,other])])])
        }
        let control=try TronPermissionControl(configuration:config(),permissionID:2,delegate:external)
        try control.validate(signer:owner)
        XCTAssertEqual(control.owner.keys.count,2);XCTAssertEqual(control.actives[0].operations,operations)
        XCTAssertFalse(try control.matches(config(activeThreshold:2)))
        XCTAssertThrowsError(try TronPermissionControl(configuration:config(),permissionID:2,delegate:owner).validate(signer:owner))
        XCTAssertThrowsError(try TronPermissionControl(configuration:config(ownerThreshold:2),permissionID:2,delegate:external).validate(signer:owner))
        XCTAssertThrowsError(try TronPermissionControl(configuration:config(activeThreshold:2),permissionID:2,delegate:external).validate(signer:owner))
        let after:TronJSON = .object(["owner_permission":permission(0,1,[ownKey,other]),"active_permission":.array([permission(2,1,[ownKey])])])
        XCTAssertTrue(try control.isRemoved(after));XCTAssertFalse(try control.matches(after))
    }
}
