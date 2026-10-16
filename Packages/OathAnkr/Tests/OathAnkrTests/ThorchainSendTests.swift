import XCTest
import OathDiagnostics
@testable import OathAnkr

@MainActor final class ThorchainSendTests:XCTestCase {
    let key=Data(repeating:1,count:32)
    func plan(reference:String="native",sequence:UInt64=7,now:Date = .now) throws -> ThorchainSendPlan {
        let pub=try ThorchainSendCrypto.publicKey(privateKey:key),other=try ThorchainSendCrypto.publicKey(privateKey:Data(repeating:2,count:32))
        return .init(network:.mainnet,sender:try ThorchainSendCrypto.address(publicKey:pub,network:.mainnet),recipient:try ThorchainSendCrypto.address(publicKey:other,network:.mainnet),reference:reference,memo:"Oath test",publicKey:pub,decimals:reference=="x/oath-test" ? 6:8,requestedAmount:"123456",amount:"123456",assetBalance:"10000000000",nativeBalance:"10000000000",accountNumber:123,sequence:sequence,fee:2000000,height:100,timeoutHeight:130,createdAt:now)
    }
    func testIndependentWalletCoreVectorsNativeTokensAndZeroSequence() throws {
        struct Vector:Decodable {let reference:String,sequence:UInt64,sender:String,recipient:String,publicKey:String,bytes:String,hash:String}
        let url=Bundle.module.url(forResource:"vectors",withExtension:"json",subdirectory:"Fixtures/ThorchainSend")!
        for v in try JSONDecoder().decode([Vector].self,from:Data(contentsOf:url)) {
            let p=try plan(reference:v.reference,sequence:v.sequence),signed=try ThorchainSendCrypto.sign(p,privateKey:key)
            XCTAssertEqual(p.sender,v.sender);XCTAssertEqual(p.recipient,v.recipient)
            XCTAssertEqual(signed.bytes,try TronIdentity.hex(v.bytes));XCTAssertEqual(signed.hash,v.hash)
            XCTAssertEqual(try ThorchainSendCrypto.committedSequence(signed.bytes,publicKey:p.publicKey,accountNumber:p.accountNumber,network:p.network),p.sequence)
            var broken=signed.bytes;broken[broken.count-1]^=1
            XCTAssertThrowsError(try ThorchainSendCrypto.verify(.init(bytes:broken,signature:signed.signature,hash:signed.hash),plan:p))
            XCTAssertThrowsError(try ThorchainSendCrypto.committedSequence(signed.bytes,publicKey:p.publicKey,accountNumber:p.accountNumber+1,network:p.network))
        }
    }
    func testStrictAmountsAddressesAgeAndKeyOwnership() throws {
        let p=try plan(),signed=try ThorchainSendCrypto.sign(p,privateKey:key)
        for n in ["-1","01","1.0",String(repeating:"9",count:79),"١"] {XCTAssertThrowsError(try ThorchainSendAmount.checked(n))}
        XCTAssertEqual(try ThorchainSendAmount.add("999999999999999999999","1"),"1000000000000000000000")
        XCTAssertEqual(try ThorchainSendAmount.subtract("1000000000000000000000","1"),"999999999999999999999")
        XCTAssertThrowsError(try ThorchainSendAmount.subtract("0","1"))
        XCTAssertThrowsError(try ThorchainSendCrypto.addressBytes(p.sender,network:.localTestnet))
        XCTAssertThrowsError(try ThorchainSendCrypto.addressBytes(String(p.sender.dropLast())+"x",network:.mainnet))
        XCTAssertThrowsError(try ThorchainSendCrypto.sign(p,privateKey:Data(repeating:2,count:32)))
        XCTAssertThrowsError(try p.validate(now:p.createdAt.addingTimeInterval(91)))
        try ThorchainSendCrypto.verify(signed,plan:p) // Recovery never expires signed evidence.
        XCTAssertThrowsError(try ThorchainSendClient(network:.localTestnet,localAPI:URL(string:"https://example.com")!,localRPC:URL(string:"http://localhost")!))
        XCTAssertThrowsError(try ThorchainSendClient(localAPI:URL(string:"http://localhost")!))
    }
    func testReceiptRequiresExactBytesPaymentAndFee() async throws {
        let p=try plan(),s=try ThorchainSendCrypto.sign(p,privateKey:key),c=try ThorchainSendClient()
        func transfer(_ to:String,_ amount:String)->SolanaJSON { .object(["type":.string("transfer"),"attributes":.array([.object(["key":.string("sender"),"value":.string(p.sender)]),.object(["key":.string("recipient"),"value":.string(to)]),.object(["key":.string("amount"),"value":.string(amount)])])]) }
        let fee=transfer("thor1dheycdevq39qlkxs2a6wuuzyn4aqxhve4qxtxt","2000000rune")
        func response(payment:String="123456rune",code:String="0",bytes:Data=s.bytes,events:Bool=true)->SolanaJSON {
            .object(["hash":.string(s.hash),"tx":.string(bytes.base64EncodedString()),"height":.string("101"),"tx_result":.object(["code":.number(code),"events":.array(events ? [fee,transfer(p.recipient,payment)]:[])])])
        }
        let receipt=try await c.receipt(response(),signed:s,plan:p);XCTAssertEqual(receipt.outcome,.confirmed);XCTAssertEqual(receipt.fee,p.fee)
        let failed=try await c.receipt(response(payment:"0rune",code:"5"),signed:s,plan:p);XCTAssertEqual(failed.outcome,.failed)
        for bad in [response(payment:"123457rune"),response(bytes:Data([1])),response(events:false)] {
            do {_ = try await c.receipt(bad,signed:s,plan:p);XCTFail("Accepted incorrect receipt")} catch {}
        }
    }
}

extension ThorchainSendTests {
    func testParallelQuoteMaxAndFeeCurrencyForEveryTokenType() async throws {
        for ref in ["native","tcy","x/ruji","x/oath-test"] {
            let p=try plan(reference:ref),t=ThorchainSendFixture(plan:p),c=try ThorchainSendClient(transport:t)
            let q=try await c.quote(sender:p.sender,recipient:p.recipient,reference:ref,publicKey:p.publicKey,decimals:p.decimals,amount:p.amount,memo:p.memo)
            XCTAssertEqual(q.amount,p.amount);XCTAssertEqual(q.fee,p.fee)
            let max=try await c.quote(sender:p.sender,recipient:p.recipient,reference:ref,publicKey:p.publicKey,decimals:p.decimals,amount:p.amount,maximum:true)
            XCTAssertEqual(max.amount,ref=="native" ? "9998000000":"10000000000")
            try await c.preflight(q)
            await t.mode("sequence")
            do {try await c.preflight(q);XCTFail("Changed sequence accepted")} catch {XCTAssertEqual(error as? ThorchainSendError,.changed)}
        }
    }
    func testMalformedProviderWrongNetworkModuleRecipientsAndCancellationFailClosed() async throws {
        let p=try plan()
        for mode in ["network","height","account","module","fee","balance","halted","http","cancel"] {
            let t=ThorchainSendFixture(plan:p),c=try ThorchainSendClient(transport:t);await t.mode(mode)
            do {_ = try await c.quote(sender:p.sender,recipient:p.recipient,reference:p.reference,publicKey:p.publicKey,decimals:p.decimals,amount:p.amount);XCTFail("Accepted \(mode)")} catch {if mode=="cancel" {XCTAssertTrue(error is CancellationError)}}
        }
        let t=ThorchainSendFixture(plan:p),c=try ThorchainSendClient(transport:t)
        do {_ = try await c.quote(sender:p.sender,recipient:p.recipient,reference:p.reference,publicKey:p.publicKey,decimals:6,amount:p.amount);XCTFail("Wrong decimals")} catch {XCTAssertEqual(error as? ThorchainSendError,.metadataChanged)}
    }
    func testFreshSubmitAcknowledgesWithoutPollingAndRecoveryReusesExactBytes() async throws {
        let p=try plan(),s=try ThorchainSendCrypto.sign(p,privateKey:key),t=ThorchainSendFixture(plan:p,signed:s),c=try ThorchainSendClient(transport:t)
        let ack=try await c.submit(s,plan:p,reconcileFirst:false);XCTAssertEqual(ack.outcome,.accepted)
        let paths=await t.paths;XCTAssertFalse(paths.contains(where:{$0.hasSuffix("/tx") || $0.contains("accounts/")}))
        let sent=await t.sent;XCTAssertEqual(sent,[s.bytes])
        let unknown=try await c.status(s,plan:p);XCTAssertEqual(unknown.outcome,.unknown)
        _ = try await c.submit(s,plan:p);let replay=await t.sent;XCTAssertEqual(replay,[s.bytes,s.bytes])
        await t.mode("expired");let expired=try await c.status(s,plan:p);XCTAssertEqual(expired.outcome,.expired)
    }
}
private actor ThorchainSendFixture:AnkrTransport {
    let p:ThorchainSendPlan,signed:ThorchainSignedSend?
    var kind="normal",paths=[String](),sent=[Data]()
    init(plan:ThorchainSendPlan,signed:ThorchainSignedSend?=nil){p=plan;self.signed=signed}
    func mode(_ value:String){kind=value}
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        try Task.checkCancellation();if kind=="cancel" {throw CancellationError()}
        let path=request.url!.path;paths.append(path)
        if kind=="http" {return (Data("{}".utf8),503)}
        let j:[String:Any]
        if request.httpMethod=="POST" {
            let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
            let params=body["params"] as! [String:String];sent.append(Data(base64Encoded:params["tx"]!)!)
            j=["result":["hash":signed!.hash,"code":0]]
        } else if path.hasSuffix("/status") {
            if kind == "invalid_json" { return (Data("{\"private\":\"do-not-upload-response-body\"".utf8), 200) }
            if kind == "head_schema" { return (Data("{\"result\":{\"node_info\":{\"network\":\"thorchain-1\"},\"sync_info\":{\"catching_up\":false,\"latest_block_time\":\"invalid\"}}}".utf8), 200) }
            j=["result":["node_info":["network":kind=="network" ? "wrong":"thorchain-1"],"sync_info":["catching_up":false,"latest_block_time":ISO8601DateFormatter().string(from:kind=="height" ? .distantPast:.now),"latest_block_height":kind=="expired" ? "200":"100","earliest_block_height":"1"]]]
        } else if path.contains("/accounts/") {
            let recipient=path.hasSuffix(p.recipient)
            if recipient,kind != "module" {return (Data("{\"code\":5}".utf8),404)}
            if kind == "account_schema" { return (try JSONSerialization.data(withJSONObject: ["account": ["@type": "/cosmos.auth.v1beta1.BaseAccount", "address": p.sender, "account_number": "invalid", "sequence": "7"]]), 200) }
            j=["account":["@type":kind=="module" && recipient ? "/cosmos.auth.v1beta1.ModuleAccount":"/cosmos.auth.v1beta1.BaseAccount","address":kind=="account" ? "wrong":p.sender,"account_number":"123","sequence":kind=="sequence" ? "8":"7"]]
        } else if path.contains("/by_denom") {
            if kind == "balance_schema" { return (Data("{\"balance\":{\"amount\":\"do-not-upload-response-body\"}}".utf8), 200) }
            let denom=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!.first{$0.name=="denom"}!.value!
            j=["balance":["denom":denom,"amount":kind=="balance" ? "1":"10000000000"]]
        } else if path.hasSuffix("/network") {j=["native_tx_fee_rune":kind=="fee_schema" ? "invalid":(kind=="fee" ? "100000001":"2000000")]}
        else if path.hasSuffix("/mimir") {
            if kind == "mimir_schema" { return (Data("[]".utf8), 200) }
            j=kind=="halted" ? ["HALTTHORCHAIN":1]:[:]
        }
        else if path.hasSuffix("/denoms_metadata") {
            if kind == "metadata_schema" { return (Data("{\"metadatas\":null}".utf8), 200) }
            j=["metadatas":[["base":"x/oath-test","denom_units":[["denom":"x/oath-test","exponent":0],["denom":"TEST","exponent":6]]]],"pagination":["next_key":""]]
        }
        else if path.hasSuffix("/tx") {j=["error":["code":-32603,"message":"Internal error","data":"tx not found"]]}
        else {throw ThorchainSendError.malformed}
        return (try JSONSerialization.data(withJSONObject:j),200)
    }
}

private actor ThorchainDiagnosticCapture: DiagnosticTransport {
    var events = [DiagnosticEvent]()
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

extension ThorchainSendTests {
    func testInvalidQuoteResponsesRetainStageAndOriginalDecodeFailurePrivately() async throws {
        let capture = ThorchainDiagnosticCapture()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: capture)
        let p = try plan(reference: "x/oath-test")
        let validID = UUID(), validClient = try ThorchainSendClient(transport: ThorchainSendFixture(plan: p))
        _ = try await OathDiagnostics.$operationID.withValue(validID) {
            try await validClient.quote(sender: p.sender, recipient: p.recipient, reference: p.reference,
                publicKey: p.publicKey, decimals: p.decimals, amount: p.amount)
        }
        var cases = [(id: UUID, operation: String, stage: String)]()
        for (mode, operation, stage) in [
            ("invalid_json", "status_head", "decode_response"),
            ("head_schema", "status_head", "validate_response"),
            ("account_schema", "account", "validate_response"),
            ("balance_schema", "balance", "validate_response"),
            ("fee_schema", "fee", "validate_response"),
            ("mimir_schema", "chain_status", "validate_response"),
            ("metadata_schema", "metadata", "validate_response")
        ] {
            let id = UUID(), transport = ThorchainSendFixture(plan: p)
            await transport.mode(mode)
            let client = try ThorchainSendClient(transport: transport)
            cases.append((id, operation, stage))
            do {
                _ = try await OathDiagnostics.$operationID.withValue(id) {
                    try await client.quote(sender: p.sender, recipient: p.recipient, reference: p.reference,
                        publicKey: p.publicKey, decimals: p.decimals, amount: p.amount, memo: "private-user-memo")
                }
                XCTFail("Accepted invalid \(mode)")
            } catch {
                XCTAssertNotNil(error as? ThorchainSendError, "Preserve the domain error presented to the app")
            }
        }
        let cancelledID = UUID(), cancelledTransport = ThorchainSendFixture(plan: p)
        await cancelledTransport.mode("cancel")
        let cancelledClient = try ThorchainSendClient(transport: cancelledTransport)
        do {
            _ = try await OathDiagnostics.$operationID.withValue(cancelledID) {
                try await cancelledClient.quote(sender: p.sender, recipient: p.recipient, reference: p.reference,
                    publicKey: p.publicKey, decimals: p.decimals, amount: p.amount)
            }
            XCTFail("Cancellation was ignored")
        } catch { XCTAssertTrue(error is CancellationError) }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            let ids = Set(await capture.events.compactMap(\.operationID))
            if cases.allSatisfy({ ids.contains($0.id) }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.events
        for item in cases {
            let reports = events.filter { $0.operationID == item.id && $0.operation == item.operation && $0.context["stage"] == item.stage }
            XCTAssertFalse(reports.isEmpty, "Lost \(item.operation)/\(item.stage) before the generic quote error")
            XCTAssertTrue(reports.allSatisfy { $0.context["chain"] == "thorchain" })
            if item.stage == "decode_response" {
                XCTAssertEqual(reports.count, 1)
                XCTAssertEqual(reports.first?.error.domain, "NSCocoaErrorDomain")
            }
        }
        XCTAssertFalse(events.contains { $0.operationID == validID }, "An unfunded recipient is expected, not a diagnostic error")
        XCTAssertFalse(events.contains { $0.operationID == cancelledID })
        let report = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for forbidden in [p.sender, p.recipient, p.publicKey.base64EncodedString(), "private-user-memo", "do-not-upload-response-body", "by_denom", "https://"] {
            XCTAssertFalse(report.contains(forbidden), "Diagnostic payload included private request/response material")
        }
    }
}

extension ThorchainSendTests {
    func testWalletConnectReviewChecksLiveSequenceFeesBalancesAndDecimals() async throws {
        for ref in ["native", "tcy", "x/ruji", "x/oath-test"] {
            let p = try plan(reference: ref)
            let doc: SolanaJSON = .object(["chain_id": .string(p.network.chainID), "account_number": .string(String(p.accountNumber)), "sequence": .string(String(p.sequence)), "fee": .object(["gas": .string("500000000"), "amount": .array([])]), "memo": .string(""), "msgs": .array([.object(["type": .string("thorchain/MsgSend"), "value": .object(["from_address": .string(p.sender), "to_address": .string(p.recipient), "amount": .array([.object(["denom": .string(p.denom), "amount": .string(p.amount)])])])])])])
            let request = try ThorchainWalletConnectRequest(method: "cosmos_signAmino", params: .object(["signerAddress": .string(p.sender), "signDoc": doc]), sender: p.sender, publicKey: p.publicKey)
            let transport = ThorchainSendFixture(plan: p)
            let client = try ThorchainSendClient(transport: transport)
            let review = try await client.walletConnectReview(request)
            XCTAssertEqual(review.fee, p.fee)
            XCTAssertEqual(review.decimals[ref], p.decimals)
            for kind in ["sequence", "fee", "balance", "halted", "network", "module", "http", "cancel"] {
                await transport.mode(kind)
                do { _ = try await client.walletConnectReview(request); XCTFail("Accepted invalid \(kind)") }
                catch { if kind == "cancel" { XCTAssertTrue(error is CancellationError) } }
            }
        }
    }
}
