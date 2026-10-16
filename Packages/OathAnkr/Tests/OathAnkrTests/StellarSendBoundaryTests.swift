import XCTest
@testable import OathAnkr

private actor StellarTransportFixture: AnkrTransport {
    let sender:String,recipient:String,issuer:String
    var native="10.0000000",selling="0.1000000",memoRequired=false,authorized=true,trust=true,limit="100",weight=1
    var wrongNetwork=false,stale=false,proxy404=false,unavailable=false,fee="100",height:UInt32=100,oldest:UInt32=1
    var missingRecipient=false,baseReserve:UInt64=5_000_000
    func activation(_ reserve:UInt64){missingRecipient=true;baseReserve=reserve}
    var tx:StellarJSON?,rpcError=false,writes=[Data]()
    var acknowledgement:StellarJSON = .object([:]), acknowledgementStatus=201, reads=0
    func ack(_ value:StellarJSON,status:Int=201) { acknowledgement=value;acknowledgementStatus=status }
    init(sender:String,recipient:String,issuer:String){self.sender=sender;self.recipient=recipient;self.issuer=issuer}
    func configure(native:String?=nil,memo:Bool?=nil,authorized:Bool?=nil,trust:Bool?=nil,limit:String?=nil,weight:Int?=nil,wrongNetwork:Bool?=nil,stale:Bool?=nil,proxy404:Bool?=nil,unavailable:Bool?=nil,fee:String?=nil,height:UInt32?=nil,oldest:UInt32?=nil,rpcError:Bool?=nil){
        if let native{self.native=native};if let memo{memoRequired=memo};if let authorized{self.authorized=authorized};if let trust{self.trust=trust};if let limit{self.limit=limit};if let weight{self.weight=weight};if let wrongNetwork{self.wrongNetwork=wrongNetwork};if let stale{self.stale=stale};if let proxy404{self.proxy404=proxy404};if let unavailable{self.unavailable=unavailable};if let fee{self.fee=fee};if let height{self.height=height};if let oldest{self.oldest=oldest};if let rpcError{self.rpcError=rpcError}
    }
    func receipt(_ value:StellarJSON){tx=value}
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        var result:StellarJSON,status=200
        let path=request.url!.path
        if request.httpMethod != "POST" { reads += 1 }
        if request.httpMethod == "POST",path.hasSuffix("/transactions_async") {
            writes.append(request.httpBody!);if unavailable {throw URLError(.timedOut)}
            result = acknowledgement;status=acknowledgementStatus
        } else if request.httpMethod == "POST" {
            let body=try JSONDecoder().decode(StellarJSON.self,from:request.httpBody!)
            if rpcError { result = .object(["error":.object(["code":.number("-32000"),"message":.string("PRIVATE_RESPONSE_MARKER"),"data":body])]) }
            else if body["method"].string == "getNetwork" { result = .object(["result":.object(["passphrase":.string(wrongNetwork ? "wrong":StellarSendNetwork.testnet.passphrase)])]) }
            else {result = .object(["result":.object(["inclusionFee":.object(["p95":.string(fee)]),"sorobanInclusionFee":.object(["p95":.string(fee)]),"latestLedger":.number(String(height))])])}
        } else if path.contains("/accounts/") {
            let owner=request.url!.lastPathComponent
            if owner==recipient,missingRecipient {
                return (try JSONEncoder().encode(StellarJSON.object(["status":.number("404"),"type":.string("https://stellar.org/horizon-errors/not_found")])),404)
            }
            var balances:[StellarJSON]=[.object(["asset_type":.string("native"),"balance":.string(native),"selling_liabilities":.string(selling)])]
            if owner==sender || trust {balances.append(.object(["asset_type":.string("credit_alphanum4"),"asset_code":.string("OAT"),"asset_issuer":.string(issuer),"balance":.string("10"),"selling_liabilities":.string("1"),"buying_liabilities":.string("2"),"limit":.string(limit),"is_authorized":.bool(authorized)]))}
            result = .object(["account_id":.string(owner),"sequence":.string("41"),"subentry_count":.number("2"),"num_sponsoring":.number("1"),"num_sponsored":.number("1"),"thresholds":.object(["med_threshold":.number("1")]),"signers":.array([.object(["key":.string(owner),"type":.string("ed25519_public_key"),"weight":.number(String(weight))])]),"balances":.array(balances),"data":memoRequired && owner==recipient ? .object(["config.memo_required":.string("MQ==")]):.object([:])])
        } else if path.hasSuffix("/ledgers") {
            result = .object(["_embedded":.object(["records":.array([.object(["sequence":.number(String(height)),"base_reserve_in_stroops":.number(String(baseReserve)),"base_fee_in_stroops":.number("100"),"closed_at":.string(ISO8601DateFormatter().string(from:Date.now.addingTimeInterval(stale ? -120:0)))])])])])
        } else if path.contains("/transactions/") {
            if let tx {result=tx} else {status=404;result=proxy404 ? .object(["detail":.string("proxy failure PRIVATE_RESPONSE_MARKER")]):.object(["status":.number("404"),"type":.string("https://stellar.org/horizon-errors/not_found")])}
        } else {
            result = .object(["network_passphrase":.string(wrongNetwork ? "wrong":StellarSendNetwork.testnet.passphrase),"history_latest_ledger":.number(String(height)),"history_elder_ledger":.number(String(oldest))])
        }
        return (try JSONEncoder().encode(result),status)
    }
}
final class StellarSendBoundaryTests:XCTestCase {
    let key=Data(repeating:21,count:32)
    private func fixture() throws -> (StellarSendClient,StellarTransportFixture,String,String,String) {
        let sender=try StellarSendCrypto.address(privateKey:key),recipient=try StellarSendCrypto.address(privateKey:Data(repeating:22,count:32)),issuer=try StellarSendCrypto.address(privateKey:Data(repeating:23,count:32))
        let t=StellarTransportFixture(sender:sender,recipient:recipient,issuer:issuer)
        return (try StellarSendClient(network:.testnet,transport:t),t,sender,recipient,issuer)
    }
    func testNewRecipientMinimumAndTokenRequirement() async throws {
        for reserve:UInt64 in [5_000_000,7_500_000] {
            let(c,t,a,b,issuer)=try fixture();await t.activation(reserve)
            do { _ = try await c.quote(sender:a,recipient:b,reference:"native",decimals:7,amount:String(2*reserve-1));XCTFail() }
            catch { XCTAssertEqual(error as? StellarSendError,.recipientMinimum(2*reserve)) }
            let plan=try await c.quote(sender:a,recipient:b,reference:"native",decimals:7,amount:String(2*reserve))
            XCTAssertEqual(plan.kind,.createAccount);XCTAssertEqual(plan.amount,String(2*reserve))
            XCTAssertEqual(plan.accountCost?.atomic,String(2*reserve));XCTAssertEqual(plan.accountCost?.inclusion,.payment)
            let legacy=try withoutAccountCostMetadata(plan);XCTAssertNil(legacy.accountCost)
            XCTAssertEqual(try StellarSendXDR.transaction(legacy),try StellarSendXDR.transaction(plan))
            do { _ = try await c.quote(sender:a,recipient:b,reference:StellarIdentity.contract(code:"OAT",issuer:issuer,network:StellarSendNetwork.testnet.passphrase),decimals:7,amount:"1");XCTFail() }
            catch { XCTAssertEqual(error as? StellarSendError,.recipientUnfunded) }
            let writes=await t.writes;XCTAssertTrue(writes.isEmpty)
        }
    }
    func testFreshAcknowledgementSkipsHistoryAndRejectsWrongHashOrUnacceptedStatus() async throws {
        let(c,t,a,b,_)=try fixture(),p=try await c.quote(sender:a,recipient:b,reference:"native",decimals:7,amount:"1"),s=try StellarSendCrypto.sign(p,privateKey:key)
        XCTAssertNil(p.accountCost,"Existing Stellar recipient must not show reserve funding")
        let reads=await t.reads
        for (status,code) in [(201,"PENDING"),(409,"DUPLICATE")] {
            await t.ack(.object(["hash":.string(s.hash),"tx_status":.string(code)]),status:status)
            let receipt=try await c.submit(s,plan:p,reconcileFirst:false)
            XCTAssertEqual(receipt.outcome,.accepted);XCTAssertNil(receipt.ledger);XCTAssertNil(receipt.fee)
        }
        let after=await t.reads;XCTAssertEqual(after,reads,"Fresh submission performed recovery/ledger reads")
        for (hash,code,status) in [("wrong","PENDING",201),(s.hash,"ERROR",201),(s.hash,"TRY_AGAIN_LATER",503)] {
            await t.ack(.object(["hash":.string(hash),"tx_status":.string(code)]),status:status)
            let receipt=try await c.submit(s,plan:p,reconcileFirst:false);XCTAssertEqual(receipt.outcome,.unknown)
        }
    }
    func testMaximumProtectsSponsorshipReserveLiabilitiesAndFees() async throws {
        let(c,t,a,b,_)=try fixture()
        let p=try await c.quote(sender:a,recipient:b,reference:"native",decimals:7,amount:"100000000",maximum:true)
        XCTAssertEqual(p.reserve,20000000);XCTAssertEqual(p.nativeLiabilities,1000000);XCTAssertEqual(p.fee,120)
        XCTAssertEqual(p.amount,"78999880");XCTAssertEqual(p.remaining,"21000000")
        await t.configure(native:"2.1000001")
        do{_=try await c.quote(sender:a,recipient:b,reference:"native",decimals:7,amount:"1");XCTFail("Spent reserve")}catch{XCTAssertEqual(error as? StellarSendError,.reserve)}
    }
    func testMemoIDZeroAndMaximumArePreservedAndOmissionRejected() async throws {
        let(c,t,a,b,_)=try fixture();await t.configure(memo:true)
        do{_=try await c.quote(sender:a,recipient:b,reference:"native",decimals:7,amount:"1");XCTFail("Missing memo")}catch{XCTAssertEqual(error as? StellarSendError,.memoRequired)}
        for value in ["0","18446744073709551615"] {
            let p=try await c.quote(sender:a,recipient:b,reference:"native",decimals:7,amount:"1",memo:.init(type:.id,value:value))
            XCTAssertEqual(p.memo.value,value);try StellarSendCrypto.verify(StellarSendCrypto.sign(p,privateKey:key),plan:p)
        }
    }
    func testClassicTrustAuthorizationCapacityAndAvailableBalance() async throws {
        let(c,t,a,b,i)=try fixture(),ref=try StellarIdentity.contract(code:"OAT",issuer:i,network:StellarSendNetwork.testnet.passphrase)
        let p=try await c.quote(sender:a,recipient:b,reference:ref,decimals:7,amount:"100000000",maximum:true)
        XCTAssertEqual(p.amount,"90000000")
        await t.configure(trust:false)
        do{_=try await c.quote(sender:a,recipient:b,reference:ref,decimals:7,amount:"1");XCTFail("No trust line")}catch{XCTAssertEqual(error as? StellarSendError,.trustline)}
        await t.configure(trust:true,limit:"12")
        do{_=try await c.quote(sender:a,recipient:b,reference:ref,decimals:7,amount:"1");XCTFail("Buying liabilities ignored")}catch{XCTAssertEqual(error as? StellarSendError,.trustline)}
        await t.configure(authorized:false)
        do{_=try await c.quote(sender:a,recipient:b,reference:ref,decimals:7,amount:"1");XCTFail("Frozen line")}catch{XCTAssertEqual(error as? StellarSendError,.restricted)}
    }
    func testWrongNetworkStaleLedgerUnavailableSignerAndFeeLimit() async throws {
        let(c,t,a,b,_)=try fixture()
        await t.configure(wrongNetwork:true)
        do{_=try await c.quote(sender:a,recipient:b,reference:"native",decimals:7,amount:"1");XCTFail()}catch{XCTAssertEqual(error as? StellarSendError,.wrongNetwork)}
        await t.configure(wrongNetwork:false,stale:true)
        do{_=try await c.quote(sender:a,recipient:b,reference:"native",decimals:7,amount:"1");XCTFail()}catch{XCTAssertEqual(error as? StellarSendError,.malformed)}
        await t.configure(weight:0,stale:false)
        do{_=try await c.quote(sender:a,recipient:b,reference:"native",decimals:7,amount:"1");XCTFail()}catch{XCTAssertEqual(error as? StellarSendError,.unsupportedAccount)}
        await t.configure(weight:1,fee:"10000001")
        do{_=try await c.quote(sender:a,recipient:b,reference:"native",decimals:7,amount:"1");XCTFail()}catch{XCTAssertEqual(error as? StellarSendError,.feeTooHigh)}
        let writes=await t.writes;XCTAssertTrue(writes.isEmpty)
    }
    func testExpiryNeedsCompleteTypedHistoryAndNeverBroadcastsExpiredBytes() async throws {
        let(c,t,a,b,_)=try fixture(),p=try await c.quote(sender:a,recipient:b,reference:"native",decimals:7,amount:"1"),signed=try StellarSendCrypto.sign(p,privateKey:key)
        await t.configure(height:125,oldest:101)
        let unknown=try await c.status(signed,plan:p);XCTAssertEqual(unknown.outcome,.unknown)
        await t.configure(proxy404:true,oldest:1)
        do{_=try await c.status(signed,plan:p);XCTFail("Proxy 404 counted as proof")}catch{XCTAssertEqual(error as? StellarSendError,.http(404))}
        await t.configure(proxy404:false)
        let expired=try await c.submit(signed,plan:p);XCTAssertEqual(expired.outcome,.expired)
        let writes=await t.writes;XCTAssertTrue(writes.isEmpty)
    }
    func testAmbiguousBroadcastRetriesIdenticalEnvelopeAndNeverReportsSuccess() async throws {
        let(c,t,a,b,_)=try fixture(),p=try await c.quote(sender:a,recipient:b,reference:"native",decimals:7,amount:"1"),signed=try StellarSendCrypto.sign(p,privateKey:key)
        await t.configure(unavailable:true)
        for _ in 0..<2 {let r=try await c.submit(signed,plan:p);XCTAssertEqual(r.outcome,.unknown)}
        let writes=await t.writes;XCTAssertEqual(writes.count,2);XCTAssertEqual(writes.first,writes.last)
        let query=URLComponents(string:"https://example.test/?"+String(decoding:writes[0],as:UTF8.self))
        XCTAssertEqual(query?.queryItems?.first?.value,signed.bytes.base64EncodedString())
    }
    func testReceiptRequiresExactEnvelopeFeeAndExecution() async throws {
        let(c,t,a,b,_)=try fixture(),p=try await c.quote(sender:a,recipient:b,reference:"native",decimals:7,amount:"1"),signed=try StellarSendCrypto.sign(p,privateKey:key)
        var r:[String:StellarJSON]=["hash":.string(signed.hash),"envelope_xdr":.string(signed.bytes.base64EncodedString()),"fee_charged":.string("100"),"ledger":.number("101"),"successful":.bool(false)]
        await t.receipt(.object(r));let failed=try await c.status(signed,plan:p);XCTAssertEqual(failed.outcome,.failed)
        r["successful"] = .bool(true);r["fee_charged"] = .string("121")
        await t.receipt(.object(r));do{_=try await c.status(signed,plan:p);XCTFail("Fee mismatch")}catch{XCTAssertEqual(error as? StellarSendError,.changed)}
        r["fee_charged"] = .string("100");r["envelope_xdr"] = .string("")
        await t.receipt(.object(r));do{_=try await c.status(signed,plan:p);XCTFail("Envelope mismatch")}catch{XCTAssertEqual(error as? StellarSendError,.changed)}
    }
    func testProviderFailureNeverEscapesAsUntrustedText() async throws {
        let(c,t,a,b,_)=try fixture();await t.configure(rpcError:true)
        do{_=try await c.quote(sender:a,recipient:b,reference:"native",decimals:7,amount:"1");XCTFail()}catch{
            XCTAssertEqual(error as? StellarSendError,.rpc(-32000));XCTAssertFalse(String(describing:error).contains("PRIVATE"))
        }
    }
}
