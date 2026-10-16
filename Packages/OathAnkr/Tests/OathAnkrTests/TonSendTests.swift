import XCTest
@testable import OathAnkr

@MainActor final class TonSendTests:XCTestCase {
    nonisolated static let key=Data(repeating:1,count:32)
    nonisolated static func plan(token:Bool=false,deploy:Bool=false,now:Date = .now,tokenAmount:TonAmount=123456,network:TonSendNetwork = .testnet) throws -> TonSendPlan {
        let pub=try TonSendCrypto.publicKey(privateKey:key),recipient=try TonSendCrypto.address(publicKey:TonSendCrypto.publicKey(privateKey:Data(repeating:2,count:32))),jw=try TonSendCrypto.address(publicKey:TonSendCrypto.publicKey(privateKey:Data(repeating:3,count:32)))
        return .init(network:network,sender:try TonSendCrypto.address(publicKey:pub),recipient:recipient,reference:token ? "0:"+String(repeating:"a",count:64):"native",publicKey:pub,decimals:token ? 6:9,requestedAmount:token ? tokenAmount:123456,amount:token ? tokenAmount:123456,assetBalance:token ? tokenAmount+UInt64(1_000_000_000):1_000_000_000,nativeBalance:1_000_000_000,sequence:deploy ? 0:7,expiration:UInt32(now.timeIntervalSince1970)+300,deploy:deploy,bounce:token,fee:1_000_000,feeReserve:10_000_000,attached:token ? 150_000_000:123456,jettonWallet:token ? jw:nil,recipientJettonWallet:token ? recipient:nil,queryID:42,createdAt:now)
    }
    func testSDKSigningPayloadsAndSignatures() throws {
        struct Vector:Decodable { let token:Bool,deploy:Bool,amount:String,sender:String,recipient:String,publicKey:String,body:String,bodyHash:String,hash:String,signingHash:String }
        let path=Bundle.module.url(forResource:"vectors",withExtension:"json",subdirectory:"Fixtures/TonSend")!
        for v in try JSONDecoder().decode([Vector].self,from:Data(contentsOf:path)) {
            let p=try Self.plan(token:v.token,deploy:v.deploy,now:Date(timeIntervalSince1970:2_000_000_000),tokenAmount:TonAmount(v.amount)!)
            XCTAssertEqual(p.sender,v.sender);XCTAssertEqual(p.recipient,v.recipient)
            XCTAssertEqual(TronSendCrypto.hex(try TonSendCrypto.signingCell(p).hash),v.signingHash)
            let body=try TonCell.parse(Data(base64Encoded:v.body)!),sig=Data(stride(from:0,to:512,by:8).map { body.bits[$0..<$0+8].reduce(0){($0<<1)|$1} })
            let s=TonSignedSend(bytes:try TonSendCrypto.external(p,body).boc(),signature:sig,hash:v.hash,bodyHash:v.bodyHash)
            try TonSendCrypto.verify(s,plan:p)
            let signed=try TonSendCrypto.sign(p,privateKey:Self.key,now:p.createdAt);try TonSendCrypto.verify(signed,plan:p)
            XCTAssertThrowsError(try TonSendCrypto.verify(.init(bytes:s.bytes,signature:Data(repeating:0,count:64),hash:s.hash,bodyHash:s.bodyHash),plan:p))
        }
    }
    func testFullJettonAmountRangeAndInvalidInput() async throws {
        for text in ["0","18446744073709551615","18446744073709551616","1000000000000000000000","1329227995784915872903807060280344575"] {
            let value=try XCTUnwrap(TonAmount(text))
            XCTAssertEqual(String(value),text)
            var b=TonBuilder();try b.jettonCoins(value)
            var r=TonReader(try b.cell());XCTAssertEqual(try r.jettonCoins(),value)
            if value>0 { XCTAssertEqual((value-UInt64(1))+UInt64(1),value) }
            XCTAssertEqual(try JSONDecoder().decode(TonAmount.self,from:JSONEncoder().encode(value)),value)
        }
        for text in ["1329227995784915872903807060280344576","-1","1.2","1e9","",String(repeating:"9",count:41)] { XCTAssertNil(TonAmount(text)) }
        XCTAssertEqual(String(TonAmount("ffffffffffffffffffffffffffffff",radix:16)!),"1329227995784915872903807060280344575")
        let p=try Self.plan(),c=try TonSendClient(network:.testnet,transport:TonStatusFixture(plan:p,mode:"cancel"),indexInterval:0)
        do { _ = try await c.quote(sender:p.sender,recipient:p.recipient,reference:p.reference,publicKey:p.publicKey,decimals:-1,amount:"1");XCTFail("Invalid decimals accepted") }
        catch { XCTAssertEqual(error as? TonSendError,.amount) }
        // Every signed field is bound; fee metadata cannot authorize new bytes.
        let signed=try TonSendCrypto.sign(p,privateKey:Self.key)
        var json=try JSONDecoder().decode(TonJSON.self,from:JSONEncoder().encode(p))
        json=change(json,["memo"],.string("changed"))
        let altered=try JSONDecoder().decode(TonSendPlan.self,from:JSONEncoder().encode(json))
        XCTAssertThrowsError(try TonSendCrypto.verify(signed,plan:altered))
    }
    func testJettonLibraryCellsMatchSDKAndStalePlansCannotSign() throws {
        struct Vector:Decodable { let boc:String,hash:String }
        let url=Bundle.module.url(forResource:"library",withExtension:"json",subdirectory:"Fixtures/TonSend")!
        for v in try JSONDecoder().decode([Vector].self,from:Data(contentsOf:url)) {
            let cell=try TonCell.parse(Data(base64Encoded:v.boc)!)
            XCTAssertEqual(TronSendCrypto.hex(cell.hash),v.hash)
            XCTAssertEqual(try TonCell.parse(cell.boc()).hash,cell.hash)
        }
        XCTAssertThrowsError(try TonCell([0,0,0,0,0,0,1,0],library:true))
        let p=try Self.plan(now:Date.now.addingTimeInterval(-95))
        XCTAssertThrowsError(try p.validate())
        XCTAssertThrowsError(try TonSendCrypto.sign(p,privateKey:Self.key))
    }
    func testMalformedBOCsAndNetworkAddresses() throws {
        let p=try Self.plan(),cell=try TonSendCrypto.signingCell(p),boc=try cell.boc()
        XCTAssertEqual(try TonCell.parse(boc).hash,cell.hash)
        for count in 0..<boc.count { XCTAssertThrowsError(try TonCell.parse(Data(boc.prefix(count)))) }
        var cyclic=boc;cyclic[cyclic.count-1]=0
        XCTAssertThrowsError(try TonCell.parse(Data([0xb5,0xee,0x9c,0x72,1,1,1,1,0,3,0,1,0,0])))
        let friendly=try TonIdentity.friendly(p.sender);var bytes=TonIdentity.base64(friendly)!;bytes[0]|=0x80;bytes=Data(bytes.prefix(34));bytes+=TonIdentity.crc16(bytes)
        XCTAssertThrowsError(try TonSendNetwork.mainnet.address(bytes.base64EncodedString()))
        XCTAssertEqual(try TonSendNetwork.testnet.address(bytes.base64EncodedString()),p.sender)
        XCTAssertThrowsError(try TonSendCrypto.sign(p,privateKey:Data(repeating:3,count:32)))
    }
}

extension TonSendTests {
    struct ReceiptFixture:Decodable { let plan:TonSendPlan,signed:TonSignedSend,trace:TonJSON }
    func fixture(_ name:String) throws -> ReceiptFixture {
        let path=Bundle.module.url(forResource:name+"-receipt",withExtension:"json",subdirectory:"Fixtures/TonSend")!
        return try JSONDecoder().decode(ReceiptFixture.self,from:Data(contentsOf:path))
    }
    func proof(_ trace:TonJSON,_ f:ReceiptFixture) throws -> TonSendProof {
        try TonSendProof.decode(trace,plan:f.plan,bodyHash:f.signed.bodyHash,messageHash:TronSendCrypto.hex(TonCell.parse(f.signed.bytes).hash),emulated:false)
    }
    func change(_ j:TonJSON,_ path:[String],_ value:TonJSON) -> TonJSON {
        guard let key=path.first,case .object(var obj)=j else { return value }
        obj[key]=change(obj[key] ?? .null,Array(path.dropFirst()),value);return .object(obj)
    }
    func testConfirmedPublicReceiptsBindSignaturesRawTransactionsAndDelivery() throws {
        for name in ["native","jetton"] {
            let f=try fixture(name);try TonSendCrypto.verify(f.signed,plan:f.plan)
            let p=try proof(f.trace,f);XCTAssertTrue(p.complete);XCTAssertTrue(p.success)
            XCTAssertGreaterThan(p.fee,0)
            if name=="jetton" {
                let delivered=f.trace["children"].array![0]["children"].array!.first { $0["transaction"]["account"]["address"].string==f.plan.recipientJettonWallet }!["transaction"]
                XCTAssertEqual(p.hash,delivered["hash"].string)
                XCTAssertNotEqual(p.hash,f.trace["transaction"]["hash"].string)
            }
            if name=="native" { XCTAssertEqual(p.fee,955136) } // includes the forwarded message fee
            let partial=try proof(change(f.trace,["children"],.array([])),f)
            XCTAssertFalse(partial.complete)
            for altered in [change(f.trace,["emulated"],.bool(true)),change(f.trace,["transaction","hash"],.string(String(repeating:"f",count:64))),change(f.trace,["transaction","raw"],.string("00"))] {
                XCTAssertThrowsError(try proof(altered,f))
            }
            XCTAssertThrowsError(try TonSendProof.decode(f.trace,plan:f.plan,bodyHash:f.signed.bodyHash,messageHash:String(repeating:"0",count:64),emulated:false))
        }
    }
    func testFailedDeliveryDoesNotBecomeSuccessAndPartialTraceStaysPending() throws {
        let f=try fixture("jetton")
        func failRecipient(_ j:TonJSON)->TonJSON {
            guard case .object(var d)=j else { return j }
            if d["transaction"]?["account"]["address"].string==f.plan.recipientJettonWallet {
                d["transaction"]=change(d["transaction"]!,["success"],.bool(false))
            }
            if let children=d["children"]?.array { d["children"] = .array(children.map(failRecipient)) };return .object(d)
        }
        let failed=try proof(failRecipient(f.trace),f);XCTAssertTrue(failed.complete);XCTAssertFalse(failed.success)
        let partial=try proof(change(f.trace,["children"],.array([])),f);XCTAssertFalse(partial.complete)
    }
    func testWrongChainProviderCancellationAndExpiredMessageUsePinnedState() async throws {
        let p=try Self.plan(now:Date.now.addingTimeInterval(-1000)),signed=try TonSendCrypto.sign(p,privateKey:Self.key,now:p.createdAt)
        for mode in ["expired","consumed","legacy","badID","wrongNetwork","cancel"] {
            let t=TonStatusFixture(plan:p,mode:mode),c=try TonSendClient(network:.testnet,transport:t,indexInterval:0)
            do {
                let r=try await c.status(signed,plan:p)
                XCTAssertEqual(r.outcome,["expired","legacy"].contains(mode) ? .expired:.unknown)
                XCTAssertTrue(["expired","consumed","legacy"].contains(mode))
                let pinned=await t.pinned;XCTAssertTrue(pinned)
            } catch {
                if mode=="cancel" { XCTAssertTrue(error is CancellationError) }
                else if mode=="badID" { XCTAssertEqual(error as? TonSendError,.malformed) }
                else { XCTAssertEqual(mode,"wrongNetwork");XCTAssertEqual(error as? TonSendError,.wrongNetwork) }
            }
        }
    }
}
actor TonStatusFixture:AnkrTransport {
    let plan:TonSendPlan,mode:String;var pinned=false
    init(plan:TonSendPlan,mode:String) { self.plan=plan;self.mode=mode }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        if mode=="cancel" { throw CancellationError() }
        if request.url!.path.hasPrefix("/v2/traces/") { return (Data("{\"error\":\"entity not found\"}".utf8),404) }
        let call=try JSONDecoder().decode(TonJSON.self,from:request.httpBody!),method=call["method"].string!
        let result:TonJSON
        switch method {
        case "getMasterchainInfo":result = .object(["init":.object(["root_hash":.string(mode=="wrongNetwork" ? TonIdentity.genesis:"gj+B8wb/AmlPk1z1AhVI484rhrUpgSr2oSFIh56VoSg=")]),"last":.object(["seqno":.number("123"),"shard":.string("-9223372036854775808")])])
        case "getBlockHeader":result = .object(["gen_utime":.number(String(UInt64(plan.expiration)+100))])
        case "getAddressInformation":
            pinned=call["params"]["seqno"].integer==123
            var b=TonBuilder();try b.uint(UInt64(plan.sequence)+(mode=="consumed" ? 1:0),32);try b.uint(TonSendPlan.walletID,32);try b.bytes(plan.publicKey);try b.uint(0,1)
            result = .object(["balance":.string("1000000000"),"state":.string("active"),"code":.string(try TonSendCrypto.code().boc().base64EncodedString()),"data":.string(try b.cell().boc().base64EncodedString())])
        default:throw TonSendError.malformed
        }
        let envelope:TonJSON = mode=="legacy" ? .object(["ok":.bool(true),"result":result]):.object(["jsonrpc":.string("2.0"),"id":.number(mode=="badID" ? "2":"1"),"result":result])
        return (try JSONEncoder().encode(envelope),200)
    }
}
