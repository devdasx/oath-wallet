import XCTest
@testable import OathAnkr

final class PolkadotSendTests: XCTestCase, @unchecked Sendable {
    func runtime(_ name: String = "Mainnet") throws -> PolkadotRuntime {
        try PolkadotRuntime(Data(contentsOf:Bundle.module.url(forResource:"Polkadot\(name)Metadata",withExtension:"scale",subdirectory:"Fixtures")!))
    }
    func plan() throws -> PolkadotSendPlan {
        let runtime=try runtime(), key=Data(repeating:1,count:32)
        return try .init(network:.mainnet,sender:PolkadotIdentity.address(publicKey:PolkadotSendCrypto.publicKey(privateKey:key)),recipient:PolkadotIdentity.address(publicKey:Data(repeating:2,count:32)),token:.native,requestedAmount:"10000000000",amount:"10000000000",assetBalance:"100000000000",nativeBalance:"100000000000",reserve:"100000000",fee:"100000000",nonce:1,specVersion:2005001,transactionVersion:15,blockHeight:22430000,blockHash:"0x"+String(repeating:"33",count:32),metadataHash:runtime.fingerprint,callIndex:runtime.call(pallet:"Balances",name:"transfer_keep_alive").0,extensions:runtime.extensions.map(\.name),createdAt:.now)
    }
    func testIndependentSDKVerifiedFixture() throws {
        struct Vector: Decodable { let plan:PolkadotSendPlan;let signed:PolkadotSignedSend }
        let fixture=try JSONDecoder().decode(Vector.self,from:Data(contentsOf:Bundle.module.url(forResource:"PolkadotSignedVector",withExtension:"json",subdirectory:"Fixtures")!))
        try PolkadotSendCrypto.verify(fixture.signed,plan:fixture.plan)
        XCTAssertEqual(fixture.signed.hash,"0xc8c5032a0c26084ae3c3f4fa833411e9794ac1b029b5290e28b47c3263daa7a9")
    }
    func testRuntimeMetadata() throws {
        for name in ["Mainnet","Paseo"] {
            let r=try runtime(name)
            XCTAssertEqual(try r.call(pallet:"Balances",name:"transfer_keep_alive").0,Data([10,3]))
            XCTAssertEqual(try r.call(pallet:"Assets",name:"transfer").0,Data([50,8]))
            XCTAssertTrue(r.extensions.contains { $0.name == "CheckMetadataHash" })
            XCTAssertEqual(PolkadotIdentity.uint(r.pallets["Balances"]!.constants["ExistentialDeposit"]!),"100000000")
            let empty=try r.decode(Data(),pallet:"System",storage:"Account")
            XCTAssertEqual(empty["data"]["free"].text,"0")
        }
    }
    func testCompactRoundTripsAndRejectsNonCanonical() throws {
        for value in ["0","63","64","16383","16384","1073741823","1073741824","18446744073709551616","340282366920938463463374607431768211455"] {
            var reader=PolkadotScale(try PolkadotScale.compact(value));XCTAssertEqual(try reader.compact(),value);XCTAssertEqual(reader.offset,reader.data.count)
        }
        var invalid=PolkadotScale(Data([1,0]));XCTAssertThrowsError(try invalid.compact())
        XCTAssertThrowsError(try PolkadotScale.compact("340282366920938463463374607431768211456"))
    }
    func testFeeUsesRemainderBeforeReducingPayment() throws {
        XCTAssertEqual(try PolkadotSendPlan.transferAmount(requested:"100",balance:"150",reserve:"10",fee:"20",native:true),"100")
        XCTAssertEqual(try PolkadotSendPlan.transferAmount(requested:"130",balance:"150",reserve:"10",fee:"20",native:true),"120")
        XCTAssertEqual(try PolkadotSendPlan.transferAmount(requested:"150",balance:"150",reserve:"10",fee:"20",native:true),"120")
        XCTAssertEqual(try PolkadotSendPlan.transferAmount(requested:"150",balance:"150",reserve:"10",fee:"20",native:false),"150")
        XCTAssertThrowsError(try PolkadotSendPlan.transferAmount(requested:"151",balance:"150",reserve:"10",fee:"20",native:true))
        XCTAssertThrowsError(try PolkadotSendPlan.transferAmount(requested:"20",balance:"30",reserve:"10",fee:"20",native:true))
    }
    func testExactSignatureAndMutationRejection() throws {
        let p=try plan(),signed=try PolkadotSendCrypto.sign(p,privateKey:Data(repeating:1,count:32))
        try PolkadotSendCrypto.verify(signed,plan:p)
        var tampered=signed.bytes;tampered[tampered.count-1] ^= 1
        XCTAssertThrowsError(try PolkadotSendCrypto.verify(.init(bytes:tampered,signature:signed.signature,hash:signed.hash),plan:p))
        XCTAssertThrowsError(try PolkadotSendCrypto.sign(p,privateKey:Data(repeating:2,count:32)))
        if let path=ProcessInfo.processInfo.environment["OATH_DOT_VECTOR_OUTPUT"] {
            try PolkadotSendCrypto.signingPayload(p).write(to:URL(fileURLWithPath:path+"-payload.bin"));let encoder=JSONEncoder();try encoder.encode(p).write(to:URL(fileURLWithPath:path+"-plan.json"));try encoder.encode(signed).write(to:URL(fileURLWithPath:path+"-signed.json"))
        }
    }
    func testLiveReadOnlyQuote() async throws {
        guard ProcessInfo.processInfo.environment["OATH_DOT_SEND_READ_LIVE"] == "1" else { throw XCTSkip("Opt-in public read-only network check") }
        let client=try PolkadotSendClient(),sender="13vg3Mrxm3GL9eXxLsGgLYRueiwFCiMbkdHBL4ZN5aob5D4N"
        let recipient=try PolkadotIdentity.address(publicKey:Data(repeating:2,count:32))
        for (reference,decimals,amount) in [("native",10,"10000000000"),("assets:1984",6,"1000000")] {
            let p=try await client.quote(sender:sender,recipient:recipient,reference:reference,decimals:decimals,amount:amount)
            XCTAssertEqual(p.amount,amount);XCTAssertNotEqual(p.fee,"0");try p.validate()
        }
    }
}

private actor PolkadotSendRPCFixture: AnkrTransport {
    let plan: PolkadotSendPlan, signed: PolkadotSignedSend, metadata: Data, events: Data
    let expired: Bool, failedHeight: UInt64?
    let free: String, frozen: String, recipientFree: String
    let storageOverrides: [String: String]
    var blocks: Set<UInt64> = []
    init(plan: PolkadotSendPlan, signed: PolkadotSignedSend, metadata: Data, events: Data, expired: Bool = false, failedHeight: UInt64? = nil, free: String = "100000000000", frozen: String = "0", recipientFree: String = "0", storageOverrides: [String: String] = [:]) {
        self.plan=plan;self.signed=signed;self.metadata=metadata;self.events=events;self.expired=expired;self.failedHeight=failedHeight;self.free=free;self.frozen=frozen;self.recipientFree=recipientFree
        self.storageOverrides=storageOverrides
    }
    func send(_ request: URLRequest) async throws -> (Data,Int) {
        let j=try JSONDecoder().decode(SolanaJSON.self,from:request.httpBody!), method=j["method"].string!,params=j["params"].array!
        let result: SolanaJSON
        switch method {
        case "chain_getBlockHash":
            let height=UInt64(params[0].text!)!
            if height == 0 { result = .string(plan.network.genesis) }
            else {
                if height == failedHeight { throw URLError(.timedOut) }
                blocks.insert(height); result = .string("0x"+String(format:"%064llx",height))
            }
        case "chain_getFinalizedHead": result = .string(plan.blockHash)
        case "chain_getHeader": result = .object(["number":.string("0x"+String(expired ? plan.expiresAtHeight : plan.blockHeight+1,radix:16))])
        case "chain_getBlock": result = .object(["block":.object(["header":.object(["number":.string("0x"+String(UInt64(params[0].string!.dropFirst(2),radix:16)!,radix:16))]),"extrinsics":.array(expired || params[0].string != "0x"+String(format:"%064llx",plan.blockHeight+1) ? []:[.string(PolkadotIdentity.hex(signed.bytes))])])])
        case "state_getRuntimeVersion": result = .object(["specVersion":.number(String(plan.specVersion)),"transactionVersion":.number(String(plan.transactionVersion))])
        case "state_getMetadata": result = .string(PolkadotIdentity.hex(metadata))
        case "system_accountNextIndex": result = .number("1")
        case "payment_queryInfo": result = .object(["partialFee":.string("10000")])
        case "state_getStorage":
            if let value=storageOverrides[params[0].string!] { result = .string(value) }
            else if params[0].string!.hasPrefix("0x26aa394eea5630e07c48ae0c9558cef7") && params[0].string!.contains(PolkadotStorage.account) {
                let isSender=try params[0].string == PolkadotStorage.nativeKey(plan.sender)
                let amount=isSender ? free:recipientFree
                let bytes=PolkadotScale.le(UInt32(1))+PolkadotScale.le(UInt32(0))+PolkadotScale.le(UInt32(amount == "0" ? 0:1))+PolkadotScale.le(UInt32(0))
                let account=try bytes+NearSendCrypto.u128(amount)+NearSendCrypto.u128("0")+NearSendCrypto.u128(isSender ? frozen:"0")+NearSendCrypto.u128("0")
                result = .string(PolkadotIdentity.hex(account))
            } else { result = .string(PolkadotIdentity.hex(events)) }
        case "author_submitExtrinsic": result = .string(signed.hash)
        default: throw PolkadotSendError.runtimeUnsupported
        }
        return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"result":result])),200)
    }
}
extension PolkadotSendTests {
    func testFinalizedSuccessAndFailureRequireExactExtrinsicAndFeeEvents() async throws {
        let p=try plan(),signed=try PolkadotSendCrypto.sign(p,privateKey:Data(repeating:1,count:32))
        for success in [true,false] {
            let metadata=try Data(contentsOf:Bundle.module.url(forResource:"PolkadotMainnetMetadata",withExtension:"scale",subdirectory:"Fixtures")!)
            let events=try Data(contentsOf:Bundle.module.url(forResource:success ? "PolkadotSuccessEvents":"PolkadotFailureEvents",withExtension:"scale",subdirectory:"Fixtures")!)
            let fixture=PolkadotSendRPCFixture(plan:p,signed:signed,metadata:metadata,events:events)
            let client=try PolkadotSendClient(transport:fixture)
            let result=try await client.status(signed,plan:p)
            XCTAssertEqual(result.outcome,success ? .confirmed:.failed);XCTAssertEqual(result.fee,"1000");XCTAssertEqual(result.extrinsicIndex,0)
        }
    }
    func testExpiryRequiresEveryFinalizedBlockAndUnavailableBlockKeepsSendReserved() async throws {
        let p=try plan(),signed=try PolkadotSendCrypto.sign(p,privateKey:Data(repeating:1,count:32))
        for failed in [false,true] {
            let fixture=PolkadotSendRPCFixture(plan:p,signed:signed,metadata:Data(),events:Data(),expired:true,failedHeight:failed ? p.blockHeight+10:nil)
            let client=try PolkadotSendClient(transport:fixture)
            if failed {
                do { _ = try await client.status(signed,plan:p);XCTFail("An unavailable block cannot prove expiry") } catch { XCTAssertTrue(error is URLError) }
            } else {
                let result=try await client.status(signed,plan:p),count=await fixture.blocks.count
                XCTAssertEqual(result.outcome,.expired);XCTAssertEqual(count,64)
            }
        }
    }
    func testPaseoExtensionsAreEncodedAndUnknownNonemptyExtensionsFail() async throws {
        let r=try runtime("Paseo"),p=try plan()
        var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as! [String:Any]
        json["network"]="paseo";json["extensions"]=r.extensions.map(\.name);json["metadataHash"]=r.fingerprint
        let plan=try JSONDecoder().decode(PolkadotSendPlan.self,from:JSONSerialization.data(withJSONObject:json))
        let client=try PolkadotSendClient(network:.paseo)
        try await client.validateEncoding(plan,runtime:r,fields:r.call(pallet:"Balances",name:"transfer_keep_alive").1)
        XCTAssertThrowsError(try PolkadotSendCrypto.extensionBytes("UnknownFeePolicy",plan:plan))
    }
}

extension PolkadotSendTests {
    func testLivePaseoNativeSendAndResume() async throws {
        guard ProcessInfo.processInfo.environment["OATH_DOT_PASEO_SEND_LIVE"] == "1",
              let path=ProcessInfo.processInfo.environment["OATH_DOT_DISPOSABLE_FILE"] else { throw XCTSkip("Opt-in funded disposable Paseo wallet required") }
        let object=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        var seed=try PolkadotIdentity.bytes("0x"+XCTUnwrap(object["seed"]))
        defer { seed.resetBytes(in:0..<seed.count) }
        let sender=try XCTUnwrap(object["address"]),recipient=try XCTUnwrap(object["recipient"]),client=try PolkadotSendClient(network:.paseo)
        let plan:PolkadotSendPlan
        do { plan=try await client.quote(sender:sender,recipient:recipient,reference:"native",decimals:10,amount:"10000000000") }
        catch PolkadotSendError.insufficientFunds { throw XCTSkip("Disposable Paseo address has not received faucet funds") }
        XCTAssertEqual(plan.amount,"10000000000")
        try await client.preflight(plan)
        let signed=try PolkadotSendCrypto.sign(plan,privateKey:seed)
        let journal=try JSONEncoder().encode(signed),stored=try JSONDecoder().decode(PolkadotSignedSend.self,from:journal)
        let accepted=try await client.submit(stored,plan:plan,reconcileFirst:false)
        XCTAssertEqual(accepted.outcome,.accepted)
        // A new client reconciles the persisted bytes; it does not derive a new nonce/signature.
        let resumed=try PolkadotSendClient(network:.paseo)
        var receipt=PolkadotSendReceipt(hash:signed.hash,outcome:.unknown)
        for _ in 0..<30 {
            receipt=try await resumed.status(stored,plan:plan)
            if receipt.outcome != .unknown { break }
            try await Task.sleep(for:.seconds(4))
        }
        XCTAssertEqual(receipt.outcome,.confirmed);XCTAssertNotNil(receipt.fee);XCTAssertNotNil(receipt.block)
        if let output=ProcessInfo.processInfo.environment["OATH_DOT_LIVE_REPORT"] {
            let report:[String:Any]=["network":"paseo","genesis":PolkadotSendNetwork.paseo.genesis,"hash":signed.hash,"amount":plan.amount,"quotedFee":plan.fee,"actualFee":receipt.fee ?? "","block":receipt.block ?? 0,"outcome":receipt.outcome.rawValue]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
        }
    }
}

extension PolkadotSendTests {
    func testNativeQuoteProtectsLocksAndReserveAndAppliesFeeShortfallExactly() async throws {
        let p=try plan(),signed=try PolkadotSendCrypto.sign(p,privateKey:Data(repeating:1,count:32))
        let metadata=try Data(contentsOf:Bundle.module.url(forResource:"PolkadotMainnetMetadata",withExtension:"scale",subdirectory:"Fixtures")!)
        for (free,frozen,requested,expected) in [("1000000000","0","500000000","500000000"),("1000000000","800000000","900000000","199987499"),("1000000000","0","1000000000","899987499")] {
            let fixture=PolkadotSendRPCFixture(plan:p,signed:signed,metadata:metadata,events:Data(),free:free,frozen:frozen)
            let result=try await PolkadotSendClient(transport:fixture).quote(sender:p.sender,recipient:p.recipient,reference:"native",decimals:10,amount:requested)
            XCTAssertEqual(result.amount,expected);XCTAssertEqual(result.fee,"12501");try result.validate()
        }
    }
    func testFirstPaymentMinimumAndFeeFundingAreOrdinaryDomainErrors() async throws {
        let p=try plan(),signed=try PolkadotSendCrypto.sign(p,privateKey:Data(repeating:1,count:32))
        let metadata=try Data(contentsOf:Bundle.module.url(forResource:"PolkadotMainnetMetadata",withExtension:"scale",subdirectory:"Fixtures")!)
        let fixture=PolkadotSendRPCFixture(plan:p,signed:signed,metadata:metadata,events:Data())
        do { _ = try await PolkadotSendClient(transport:fixture).quote(sender:p.sender,recipient:p.recipient,reference:"native",decimals:10,amount:"1");XCTFail("Unfunded recipient minimum") }
        catch { XCTAssertEqual(error as? PolkadotSendError,.recipientMinimum) }
        let noFee=PolkadotSendRPCFixture(plan:p,signed:signed,metadata:metadata,events:Data(),free:"100000001")
        do { _ = try await PolkadotSendClient(transport:noFee).quote(sender:p.sender,recipient:p.recipient,reference:"native",decimals:10,amount:"1");XCTFail("Cannot spend reserve for fees") }
        catch { XCTAssertTrue(error is SendFeeFundingError) }
    }
    func testSelfTransferRemainingSubtractsOnlyNativeFee() throws {
        var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan())) as! [String:Any]
        json["recipient"]=json["sender"]
        let p=try JSONDecoder().decode(PolkadotSendPlan.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertTrue(p.isSelfTransfer);XCTAssertEqual(p.remaining,"99900000000")
    }
}

extension PolkadotSendTests {
    func testLocalPoolAndForeignCallsMatchIndependentSDK() async throws {
        struct Vector:Decodable { let plan:PolkadotSendPlan;let call:String }
        let vectors=try JSONDecoder().decode([Vector].self,from:Data(contentsOf:Bundle.module.url(forResource:"PolkadotAssetCalls",withExtension:"json",subdirectory:"Fixtures")!))
        XCTAssertEqual(vectors.count,3)
        let runtime=try runtime(),client=try PolkadotSendClient()
        for vector in vectors {
            try vector.plan.validate(checkAge:false)
            XCTAssertEqual(try PolkadotSendCrypto.call(vector.plan),try PolkadotIdentity.bytes(vector.call))
            try await client.validateEncoding(vector.plan,runtime:runtime,fields:runtime.call(pallet:vector.plan.token.pallet,name:"transfer_keep_alive").1)
            let signed=try PolkadotSendCrypto.sign(vector.plan,privateKey:Data(repeating:1,count:32),now:vector.plan.createdAt)
            try PolkadotSendCrypto.verify(signed,plan:vector.plan)
        }
    }
}

extension PolkadotSendTests {
    private func tokenQuote(amount: String = "1000", maximum: Bool = true, minimum: String = "minimum100", source: String = "source", target: String? = nil, locked: Bool = false, nativeFree: String = "100000000000") async throws -> PolkadotSendPlan {
        let p=try plan(),signed=try PolkadotSendCrypto.sign(p,privateKey:Data(repeating:1,count:32))
        let directory=Bundle.module
        let values=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:directory.url(forResource:"PolkadotTokenStorage",withExtension:"json",subdirectory:"Fixtures")!))
        let metadata=try Data(contentsOf:directory.url(forResource:"PolkadotMainnetMetadata",withExtension:"scale",subdirectory:"Fixtures")!)
        let token=PolkadotToken(reference:"assets:1",name:"Test asset",symbol:"TEST",decimals:0,pallet:"Assets",key:PolkadotScale.le(UInt32(1)))
        let suffix=PolkadotIdentity.hex(PolkadotIdentity.concat(token.key)).dropFirst(2),prefix="0x"+PolkadotStorage.pallets["Assets"]!
        var overrides=[prefix+PolkadotStorage.metadata+suffix:values["metadata"]!,prefix+PolkadotStorage.asset+suffix:values[minimum]!,try PolkadotStorage.accountKey(token,owner:p.sender):values[source]!,try PolkadotStorage.accountKey(token,owner:p.recipient):target.flatMap { values[$0] } ?? "0x"]
        if locked {
            let accountSuffix=PolkadotIdentity.hex(PolkadotIdentity.concat(token.key)+PolkadotIdentity.concat(try PolkadotIdentity.publicKey(p.sender))).dropFirst(2)
            overrides["0x35b7c66f50d9dd5ea57fd81d50aabe4e0aae5fbb94f8a30f52f9a263e67b53c8"+accountSuffix]=values["frozen600"]
            overrides["0x8c5b9c237726a63375a5d60e5cf1b0b3ea054aacc32ece6e888367287e12de1e"+accountSuffix]=values["held200"]
        }
        let fixture=PolkadotSendRPCFixture(plan:p,signed:signed,metadata:metadata,events:Data(),free:nativeFree,storageOverrides:overrides)
        return try await PolkadotSendClient(transport:fixture).quote(sender:p.sender,recipient:p.recipient,reference:token.reference,decimals:0,amount:amount,maximum:maximum)
    }
    func testTokenMaximumKeepsMinimumAndDoesNotSweepUnapprovedDust() async throws {
        let retained=try await tokenQuote()
        XCTAssertEqual(retained.amount,"900");XCTAssertEqual(retained.remaining,"100");XCTAssertEqual(retained.callIndex,Data([50,9]))
        let all=try await tokenQuote(minimum:"minimum1")
        XCTAssertEqual(all.amount,"1000");XCTAssertEqual(all.remaining,"0");XCTAssertEqual(all.callIndex,Data([50,8]))
        do { _ = try await tokenQuote(amount:"950",maximum:false);XCTFail("Dust cannot increase a reviewed transfer") }
        catch { XCTAssertEqual(error as? PolkadotSendError,.minimumBalance) }
        let locked=try await tokenQuote(locked:true)
        XCTAssertEqual(locked.amount,"600");XCTAssertEqual(locked.remaining,"400")
    }
    func testTokenAccountStatesAndFirstDepositMinimum() async throws {
        for (source,target,minimum,amount,expected) in [("sourceFrozen",nil,"minimum100","100",PolkadotSendError.frozen),("source","targetBlocked","minimum100","100",.frozen),("source",nil,"nonSufficient","100",.recipientNeedsNative),("source",nil,"minimum100","99",.recipientMinimum)] {
            do { _ = try await tokenQuote(amount:amount,maximum:false,minimum:minimum,source:source,target:target);XCTFail("Invalid token transfer") }
            catch { XCTAssertEqual(error as? PolkadotSendError,expected) }
        }
        let receivingFrozen=try await tokenQuote(amount:"100",maximum:false,target:"targetFrozen")
        XCTAssertEqual(receivingFrozen.amount,"100")
    }
    func testTokenFeeNeedsNativeFundsAndNeverReducesTokenAmount() async throws {
        let plan=try await tokenQuote(amount:"100",maximum:false)
        XCTAssertEqual(plan.amount,"100");XCTAssertEqual(plan.fee,"12501");XCTAssertEqual(plan.nativeDebit,plan.fee)
        do { _ = try await tokenQuote(amount:"100",maximum:false,nativeFree:"100000001");XCTFail("Tokens cannot fund native fees") }
        catch { XCTAssertTrue(error is SendFeeFundingError) }
    }
}
