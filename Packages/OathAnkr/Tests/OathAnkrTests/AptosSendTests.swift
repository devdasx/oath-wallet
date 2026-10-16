import XCTest
@testable import OathAnkr

@MainActor final class AptosSendTests: XCTestCase {
    nonisolated static let key=Data(repeating:1,count:32)
    func plan(reference:String="native",network:AptosSendNetwork = .testnet,now:Date = .now) throws -> AptosSendPlan {
        .init(network:network,sender:try AptosSendCrypto.address(privateKey:Self.key),recipient:try AptosSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:try AptosIdentity.reference(reference),publicKey:try AptosSendCrypto.publicKey(privateKey:Self.key),decimals:reference=="native" ? 8:6,requestedAmount:123456,amount:123456,assetBalance:100_000_000,nativeBalance:100_000_000,sequence:7,gasUnitPrice:100,maxGasAmount:2000,expiration:UInt64(now.timeIntervalSince1970)+300,createdAt:now)
    }
    func testOfficialSDKRawBytesSignatureHashAndGenericTokens() throws {
        struct Vector:Decodable { let reference:String,sender:String,recipient:String,publicKey:String,raw:String,signature:String,signed:String,hash:String }
        let url=Bundle.module.url(forResource:"vectors",withExtension:"json",subdirectory:"Fixtures/AptosSend")!
        for vector in try JSONDecoder().decode([Vector].self,from:Data(contentsOf:url)) {
            let p=try plan(reference:vector.reference,now:Date(timeIntervalSince1970:2_000_000_000)),s=try AptosSendCrypto.sign(p,privateKey:Self.key,now:p.createdAt)
            XCTAssertEqual(p.sender,vector.sender);XCTAssertEqual(p.recipient,vector.recipient)
            XCTAssertEqual(try AptosSendCrypto.raw(p),try TronIdentity.hex(vector.raw))
            // CryptoKit may randomize Ed25519 signatures. Verify the independent SDK
            // signature and hash instead of requiring identical signature nonces.
            let sdk=AptosSignedSend(bytes:try TronIdentity.hex(vector.signed),publicKey:try TronIdentity.hex(vector.publicKey),signature:try TronIdentity.hex(vector.signature),hash:vector.hash)
            try AptosSendCrypto.verify(sdk,plan:p)
            XCTAssertEqual(AptosSendCrypto.hash(sdk.bytes),vector.hash)
            try AptosSendCrypto.verify(s,plan:p)
            var wrong=s.bytes;wrong[0]^=1
            XCTAssertThrowsError(try AptosSendCrypto.verify(.init(bytes:wrong,publicKey:s.publicKey,signature:s.signature,hash:AptosSendCrypto.hash(wrong)),plan:p))
        }
        XCTAssertEqual(TronSendCrypto.hex(TronSendCrypto.sha3(Data())),"a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a")
    }
    func testQuoteNativeCoinFAAndMaxReserveFee() async throws {
        for reference in ["native","0x123::example::Token",try AptosIdentity.address("0x456")] {
            let p=try plan(reference:reference),transport=AptosSendFixture(plan:p)
            let client=try AptosSendClient(network:.testnet,transport:transport)
            let q=try await client.quote(sender:p.sender,recipient:p.recipient,reference:p.reference,publicKey:p.publicKey,decimals:p.decimals,amount:"123456")
            XCTAssertEqual(q.amount,123456);XCTAssertEqual(q.maxGasAmount,666);XCTAssertEqual(q.fee,66_600)
            try await client.preflight(q)
            let max=try await client.quote(sender:p.sender,recipient:p.recipient,reference:p.reference,publicKey:p.publicKey,decimals:p.decimals,amount:"123456",maximum:true)
            XCTAssertEqual(max.amount,reference=="native" ? max.assetBalance-max.fee:max.assetBalance)
        }
    }
    func testNetworkMetadataBalancesAndSimulationMustSucceed() async throws {
        let p=try plan()
        for mode in ["wrongNetwork","wrongOwner","metadata","gas","insufficient","simulation","payload"] {
            let transport=AptosSendFixture(plan:p,mode:mode),client=try AptosSendClient(network:.testnet,transport:transport)
            do { _ = try await client.quote(sender:p.sender,recipient:p.recipient,reference:p.reference,publicKey:p.publicKey,decimals:mode=="metadata" ? 7:8,amount:"123456");XCTFail("Accepted \(mode)") } catch { XCTAssertNotNil(error as? AptosSendError) }
        }
    }
    func testFreshSubmitSkipsTransactionHistory() async throws {
        let p=try plan(),s=try AptosSendCrypto.sign(p,privateKey:Self.key),t=AptosSendFixture(plan:p,mode:"pending",signed:s),c=try AptosSendClient(network:.testnet,transport:t)
        let receipt=try await c.submit(s,plan:p,reconcileFirst:false)
        XCTAssertEqual(receipt.outcome,.accepted)
        let paths=await t.paths;XCTAssertFalse(paths.contains(where:{$0.contains("by_hash") || $0.contains("accounts/")}))
        let bytes=await t.broadcast;XCTAssertEqual(bytes,s.bytes)
    }
    func testAcceptedIsNotConfirmedAndExactBytesReplayed() async throws {
        let p=try plan(),s=try AptosSendCrypto.sign(p,privateKey:Self.key),transport=AptosSendFixture(plan:p,mode:"pending",signed:s),client=try AptosSendClient(network:.testnet,transport:transport)
        let accepted=try await client.submit(s,plan:p);XCTAssertEqual(accepted.outcome,.accepted)
        let body=await transport.broadcast;XCTAssertEqual(body,s.bytes)
        await transport.setMode("confirmed")
        let receipt=try await client.status(s,plan:p);XCTAssertEqual(receipt.outcome,.confirmed);XCTAssertEqual(receipt.fee,50_000)
        await transport.setMode("failed")
        let failed=try await client.status(s,plan:p);XCTAssertEqual(failed.outcome,.failed)
    }
    func testUnknownExpiredConsumedSequenceAndWrongReceipt() async throws {
        let p=try plan(),s=try AptosSendCrypto.sign(p,privateKey:Self.key),t=AptosSendFixture(plan:p,signed:s),c=try AptosSendClient(network:.testnet,transport:t)
        let unknown = try await c.status(s,plan:p);XCTAssertEqual(unknown.outcome,.unknown)
        await t.setMode("expired");let expired = try await c.status(s,plan:p);XCTAssertEqual(expired.outcome,.expired)
        await t.setMode("replaced");let replaced = try await c.status(s,plan:p);XCTAssertEqual(replaced.outcome,.replaced)
        for mode in ["receiptHash","receiptSignature","receiptGas","receiptAmount"] {
            await t.setMode(mode);do { _ = try await c.status(s,plan:p);XCTFail("Accepted \(mode)") } catch {}
        }
    }
    func testProviderFailoverValidatesIdentityAndDoesNotReplayCancellation() async throws {
        let transport=AptosFallbackFixture(),client=try AptosSendClient(network:.mainnet,apiKey:"fixture",transport:transport)
        let amount=try await client.balance(owner:"0x1",reference:"native");XCTAssertEqual(amount,42)
        let hosts=await transport.hosts;XCTAssertEqual(hosts,["rpc.ankr.com","api.mainnet.aptoslabs.com","api.mainnet.aptoslabs.com"])
        let wrong=AptosFallbackFixture(mode:"wrongChain"),bad=try AptosSendClient(network:.mainnet,apiKey:"fixture",transport:wrong)
        do { _ = try await bad.balance(owner:"0x1",reference:"native");XCTFail("Accepted wrong-chain fallback") } catch { XCTAssertEqual(error as? AptosSendError,.wrongNetwork) }
        let cancelled=AptosFallbackFixture(mode:"cancel"),stopped=try AptosSendClient(network:.mainnet,apiKey:"fixture",transport:cancelled)
        do { _ = try await stopped.balance(owner:"0x1",reference:"native");XCTFail("Cancelled request returned data") } catch { XCTAssertTrue(error is CancellationError) }
        let count=await cancelled.hosts.count;XCTAssertEqual(count,1)
    }
    func testHugeMetadataAndIntegerValuesFailClosed() async throws {
        for j:AptosJSON in [.string("18446744073709551616"),.string("-1"),.string("1.5"),.number("1e6"),.string("0001")] { XCTAssertThrowsError(try AptosSendClient.uint(j)) }
        let p=try plan(reference:"0x123::example::Token"),transport=AptosSendFixture(plan:p,mode:"hugeMetadata"),client=try AptosSendClient(network:.testnet,transport:transport)
        do { _ = try await client.quote(sender:p.sender,recipient:p.recipient,reference:p.reference,publicKey:p.publicKey,decimals:6,amount:"1");XCTFail("Overflowing token precision") } catch { XCTAssertEqual(error as? AptosSendError,.malformed) }
    }
    func testTransferAmountBoundsRejectBeforeNetworkWithoutClamping() async throws {
        let p = try plan(), transport = AptosSendFixture(plan: p)
        let client = try AptosSendClient(network: .testnet, transport: transport)
        for invalid in ["", "0", "00", "01", "+1", "-1", "1.0", "1e6", " 1", "١", "18446744073709551616", String(repeating: "9", count: 193)] {
            XCTAssertThrowsError(try AptosSendClient.validatedAmount(invalid)) { error in
                XCTAssertEqual(error as? AptosSendError, .amount)
            }
            for maximum in [false, true] {
                do {
                    _ = try await client.quote(sender: p.sender, recipient: p.recipient, reference: p.reference,
                        publicKey: p.publicKey, decimals: p.decimals, amount: invalid, maximum: maximum)
                    XCTFail("Invalid amount reached the quote")
                } catch { XCTAssertEqual(error as? AptosSendError, .amount) }
            }
        }
        let paths = await transport.paths
        XCTAssertTrue(paths.isEmpty, "Invalid amounts must not create RPC traffic")
        for value: UInt64 in [1, UInt64.max - 1, UInt64.max] {
            XCTAssertEqual(try AptosSendClient.validatedAmount(String(value)), value)
        }
    }
    func testPrunedOrAbsentMainnetTransactionFallsBackToVerifiedArchive() async throws {
        let p=try plan(network:.mainnet),s=try AptosSendCrypto.sign(p,privateKey:Self.key)
        for code in [404,410] {
            let transport=AptosArchiveFixture(plan:p,signed:s,status:code)
            let client=try AptosSendClient(network:.mainnet,apiKey:"fixture",transport:transport)
            let receipt=try await client.status(s,plan:p)
            XCTAssertEqual(receipt.outcome,.confirmed);XCTAssertEqual(receipt.fee,50_000)
            let hosts=await transport.lookupHosts
            XCTAssertEqual(hosts,["rpc.ankr.com","api.mainnet.aptoslabs.com","archive.mainnet.aptoslabs.com"])
        }
    }
    func testPreflightRejectsChangedSequenceAndSigner() async throws {
        let p=try plan(),t=AptosSendFixture(plan:p,mode:"sequence"),c=try AptosSendClient(network:.testnet,transport:t)
        do { try await c.preflight(p);XCTFail("Changed sequence") } catch { XCTAssertEqual(error as? AptosSendError,.changed) }
        XCTAssertThrowsError(try AptosSendCrypto.sign(p,privateKey:Data(repeating:3,count:32)))
        for input in ["0x1::m::T<>","0x1::m::T<u64,>","0x1::m::T><u64>","0x1::m::T<u64>x",String(repeating:"vector<",count:18)+"u64"+String(repeating:">",count:18)] { XCTAssertThrowsError(try AptosBCS.typeTag(input)) }
    }
}

actor AptosSendFixture: AnkrTransport {
    var paths=[String]()
    var mode:String;let plan:AptosSendPlan;var broadcast:Data?;let signed:AptosSignedSend?
    init(plan:AptosSendPlan,mode:String="normal",signed:AptosSignedSend?=nil) { self.plan=plan;self.mode=mode;self.signed=signed }
    func setMode(_ value:String) { mode=value }
    func send(_ req:URLRequest) async throws -> (Data,Int) {
        let path=req.url!.path;paths.append(path);var code=200;let j:AptosJSON
        let signed=try self.signed ?? AptosSendCrypto.sign(plan,privateKey:AptosSendTests.key,now:plan.createdAt)
        func transaction(_ simulated:Bool=false) throws -> AptosJSON {
            var max=plan.maxGasAmount,amount=plan.amount,expiration=plan.expiration
            if simulated,let bytes=req.httpBody {
                // Decode the fixed u64 tail and last argument of the local BCS transfer.
                let raw=Data(bytes.dropLast(99)),tail=raw.count-25
                func u(_ start:Int)->UInt64 { (0..<8).reduce(0) { $0 | UInt64(raw[start+$1])<<($1*8) } }
                max=u(tail);expiration=u(tail+16);amount=u(tail-8)
            }
            let temp=AptosSendPlan(network:plan.network,sender:plan.sender,recipient:plan.recipient,reference:plan.reference,publicKey:plan.publicKey,decimals:plan.decimals,requestedAmount:amount,amount:amount,assetBalance:plan.assetBalance,nativeBalance:plan.nativeBalance,sequence:plan.sequence,gasUnitPrice:plan.gasUnitPrice,maxGasAmount:max,expiration:expiration,createdAt:plan.createdAt)
            var payload=AptosSendCrypto.payload(temp)
            if plan.reference != "native",!plan.reference.contains("::"),case .object(var d)=payload,var args=d["arguments"]?.array {
                args[0] = .object(["inner":args[0]]);d["arguments"] = .array(args);payload = .object(d)
            }
            if mode=="payload" || mode=="receiptAmount" { guard case .object(var d)=payload else { throw AptosSendError.malformed };d["arguments"] = .array([.string(plan.recipient),.string("1")]);payload = .object(d) }
            return .object(["type":.string(simulated || mode != "pending" ? "user_transaction":"pending_transaction"),"hash":.string(mode=="receiptHash" ? "0x"+String(repeating:"1",count:64):signed.hash),"sender":.string(plan.sender),"sequence_number":.string(String(plan.sequence)),"max_gas_amount":.string(String(max)),"gas_unit_price":.string(String(plan.gasUnitPrice)),"expiration_timestamp_secs":.string(String(expiration)),"payload":payload,"success":.bool(mode != "failed" && mode != "simulation"),"gas_used":.string(mode=="receiptGas" ? "999999":"500"),"version":.string("123"),"timestamp":.string(String(UInt64(Date.now.timeIntervalSince1970)*1_000_000)),"signature":.object(["type":.string("ed25519_signature"),"public_key":.string("0x"+TronSendCrypto.hex(signed.publicKey)),"signature":.string("0x"+TronSendCrypto.hex(mode=="receiptSignature" ? Data(repeating:0,count:64):signed.signature))])])
        }
        if path.hasSuffix("/v1/") || path.hasSuffix("/v1") { j = .object(["chain_id":.number(mode=="wrongNetwork" ? "1":String(plan.network.chainID)),"ledger_version":.string("1000"),"ledger_timestamp":.string(String((mode=="expired" ? plan.expiration+10:UInt64(Date.now.timeIntervalSince1970))*1_000_000))]) }
        else if path.hasSuffix("estimate_gas_price") { j = .object(["gas_estimate":.number(mode=="gas" ? "100000001":"100")]) }
        else if path.hasSuffix("/view") {
            let body=try JSONDecoder().decode(AptosJSON.self,from:req.httpBody!),fn=body["function"].string!
            j = .array([.string(fn.hasSuffix("::decimals") ? (mode=="hugeMetadata" ? String(UInt64.max):String(plan.decimals)):mode=="insufficient" ? "10":String(plan.nativeBalance))])
        } else if path.hasSuffix("/simulate") { j = .array([try transaction(true)]) }
        else if path.contains("transactions/by_hash") {
            if ["confirmed","failed","receiptHash","receiptGas","receiptSignature","receiptAmount"].contains(mode) { j=try transaction() }
            else { code=404;j = .object(["error_code":.string("transaction_not_found"),"message":.string("not found")]) }
        } else if path.contains("/accounts/"),path.hasSuffix("/transactions") {
            j = .array([.object(["type":.string("user_transaction"),"sender":.string(plan.sender),"sequence_number":.string(String(plan.sequence)),"hash":.string("0x"+String(repeating:"5",count:64)),"version":.string("999")])])
        } else if path.contains("/accounts/") { j = .object(["authentication_key":.string(mode=="wrongOwner" ? plan.recipient:plan.sender),"sequence_number":.string(String(plan.sequence+(["sequence","replaced"].contains(mode) ? 1:0)))]) }
        else if path.hasSuffix("/transactions") { broadcast=req.httpBody
            guard case .object(var d)=try transaction() else { throw AptosSendError.malformed }
            if mode=="pending" { d.removeValue(forKey:"type") };j = .object(d) }
        else { throw AptosSendError.malformed }
        return (try JSONEncoder().encode(j),code)
    }
}

private actor AptosArchiveFixture:AnkrTransport {
    let fixture:AptosSendFixture,status:Int
    var lookupHosts=[String]()
    init(plan:AptosSendPlan,signed:AptosSignedSend,status:Int) {
        fixture=AptosSendFixture(plan:plan,mode:"confirmed",signed:signed);self.status=status
    }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        if request.url!.path.contains("transactions/by_hash/") {
            let host=request.url!.host!;lookupHosts.append(host)
            if host != "archive.mainnet.aptoslabs.com" {
                return (Data("{\"error_code\":\"transaction_not_found\"}".utf8),status)
            }
        }
        return try await fixture.send(request)
    }
}

private actor AptosFallbackFixture:AnkrTransport {
    let mode:String;var hosts=[String]()
    init(mode:String="normal") { self.mode=mode }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let host=request.url!.host!;hosts.append(host)
        if mode=="cancel" { throw CancellationError() }
        if host=="rpc.ankr.com" { return (Data("temporarily unavailable".utf8),503) }
        if request.url!.path.hasSuffix("/view") { return (Data("[\"42\"]".utf8),200) }
        return (try JSONEncoder().encode(AptosJSON.object(["chain_id":.number(mode=="wrongChain" ? "2":"1")])),200)
    }
}
