import XCTest
@testable import OathAnkr

@MainActor final class SolanaSendRPCRegressionTests:XCTestCase {
    private func setup(_ mode:String="normal",kind:String="native") throws -> (SolanaSendPlan,SolanaRPCFixture,SolanaSendClient) {
        let helper=SolanaSendTests(),v=try helper.fixtures().vectors.first { $0.kind==kind }!,p=helper.plan(v)
        let fixture=SolanaRPCFixture(plan:p,mode:mode)
        return (p,fixture,try SolanaSendClient(network:.devnet,transport:fixture))
    }
    func testRentFailuresIdentifyRecipientMinimumWithoutMislabelingSender() async throws {
        let(p,t,c)=try setup("rentRecipient")
        do { _ = try await c.quote(sender:p.sender,recipient:p.recipient,reference:"native",decimals:9,amount:"1");XCTFail() }
        catch { XCTAssertEqual(error as? SolanaSendError,.recipientMinimum(890_880)) }
        await t.setMode("rentSender")
        do { _ = try await c.quote(sender:p.sender,recipient:p.recipient,reference:"native",decimals:9,amount:"1");XCTFail() }
        catch { XCTAssertEqual(error as? SolanaSendError,.storageBalance) }
        await t.setMode("normal")
        let revised=try await c.quote(sender:p.sender,recipient:p.recipient,reference:"native",decimals:9,amount:"890880")
        XCTAssertEqual(revised.amount,890880);XCTAssertEqual(revised.accountCost?.atomic,"890880");XCTAssertEqual(revised.accountCost?.inclusion,.payment)
        let(token,_,client)=try setup("poor",kind:"spl")
        do { _ = try await client.quote(sender:token.sender,recipient:token.recipient,reference:token.reference,decimals:6,amount:"1");XCTFail() }
        catch { XCTAssertEqual(error as? SolanaSendError,.accountRent) }
    }
    func testAccountCostsUseRecipientStateAndPreserveSerializedTransaction() async throws {
        let(p,t,c)=try setup()
        let created=try await c.quote(sender:p.sender,recipient:p.recipient,reference:"native",decimals:9,amount:"1000000")
        XCTAssertEqual(created.accountCost?.atomic,"890880")
        let legacy=try withoutAccountCostMetadata(created);XCTAssertNil(legacy.accountCost)
        XCTAssertEqual(try SolanaSendCrypto.message(legacy),try SolanaSendCrypto.message(created))
        await t.setMode("activeRecipient")
        let active=try await c.quote(sender:p.sender,recipient:p.recipient,reference:"native",decimals:9,amount:"1000000")
        XCTAssertNil(active.accountCost)
        let(token,_,client)=try setup("existingATA",kind:"spl")
        let registered=try await client.quote(sender:token.sender,recipient:token.recipient,reference:token.reference,decimals:6,amount:"1000000")
        XCTAssertEqual(registered.rent,0);XCTAssertNil(registered.accountCost)
    }
    func testFreshSubmitSkipsHistoryButKeepsPreflight() async throws {
        let (p,t,c)=try setup(),s=try SolanaSendCrypto.sign(p,privateKey:Data(repeating:1,count:32))
        await t.setSigned(s)
        let result=try await c.submit(s,plan:p,reconcileFirst:false)
        XCTAssertEqual(result.outcome,.accepted)
        let methods=await t.methods;XCTAssertFalse(methods.contains("getSignatureStatuses"));XCTAssertTrue(methods.contains("sendTransaction"))
    }
    func testNativeMaximumFeeAndPreparation() async throws {
        let (p,t,c)=try setup()
        let q=try await c.quote(sender:p.sender,recipient:p.recipient,reference:"native",decimals:9,amount:"100000000",maximum:true)
        XCTAssertEqual(q.amount,99_995_000);XCTAssertEqual(q.transactionFee,5000);XCTAssertEqual(q.remaining,0)
        try await c.preflight(q)
        let methods=await t.methods;XCTAssertTrue(methods.contains("simulateTransaction"));XCTAssertTrue(methods.contains("getFeeForMessage"))
    }
    func testBothProgramsCreateCorrectATAAndSplitSources() async throws {
        for kind in ["spl","token2022","transferFee"] {
            let (p,_,c)=try setup(kind:kind)
            let q=try await c.quote(sender:p.sender,recipient:p.recipient,reference:p.reference,decimals:6,amount:"100000000",maximum:true)
            XCTAssertEqual(q.amount,100000000);XCTAssertEqual(q.sources.count,2);XCTAssertEqual(q.rent,2039280)
            XCTAssertEqual(q.accountCost?.atomic,"2039280");XCTAssertEqual(q.accountCost?.inclusion,.additional);XCTAssertEqual(q.fee,q.transactionFee+q.rent)
            XCTAssertEqual(q.program,p.program)
            if kind=="transferFee" { XCTAssertEqual(q.tokenFees,[600000,400000]);XCTAssertEqual(q.receivedAmount,99000000) }
        }
    }
    func testUnsafeMetadataFrozenHookAndWrongOwnerFailClosed() async throws {
        for mode in ["decimals","frozen","hook","mintOwner","recipientTokenAccount","stale","extensionType"] {
            let (p,_,c)=try setup(mode,kind:"spl")
            do { _ = try await c.quote(sender:p.sender,recipient:p.recipient,reference:p.reference,decimals:6,amount:"100");XCTFail("Accepted \(mode)") } catch { XCTAssertNotNil(error as? SolanaSendError) }
        }
        for mode in ["wrongNetwork","simulation","feeMissing","poor","senderProgram"] {
            let (p,_,c)=try setup(mode)
            do { _ = try await c.quote(sender:p.sender,recipient:p.recipient,reference:"native",decimals:9,amount:"1000");XCTFail("Accepted \(mode)") } catch { XCTAssertNotNil(error as? SolanaSendError) }
        }
    }
    func testFrozenSourceDoesNotBlockOtherSpendableAccounts() async throws {
        let (p,_,c)=try setup("partiallyFrozen",kind:"spl")
        let q=try await c.quote(sender:p.sender,recipient:p.recipient,reference:p.reference,decimals:6,amount:"100000000",maximum:true)
        XCTAssertEqual(q.amount,60_000_000);XCTAssertEqual(q.assetBalance,60_000_000);XCTAssertEqual(q.sources.count,1)
    }
    func testToken2022DefaultAccountStateUsesRPCFieldAndRejectsFrozenCreation() async throws {
        let (p,_,c)=try setup("defaultInitialized",kind:"token2022")
        let q=try await c.quote(sender:p.sender,recipient:p.recipient,reference:p.reference,decimals:6,amount:"1000")
        XCTAssertEqual(q.amount,1000)
        let (_,_,frozen)=try setup("defaultFrozen",kind:"token2022")
        do { _ = try await frozen.quote(sender:p.sender,recipient:p.recipient,reference:p.reference,decimals:6,amount:"1000");XCTFail() }
        catch { XCTAssertEqual(error as? SolanaSendError,.frozen) }
    }
    func testOverBalanceDoesNotSilentlyBecomeMaximum() async throws {
        let (p,_,c)=try setup()
        do { _ = try await c.quote(sender:p.sender,recipient:p.recipient,reference:"native",decimals:9,amount:"100000001");XCTFail() }
        catch { XCTAssertEqual(error as? SolanaSendError,.insufficientFunds) }
    }
    func testSimulationDiagnosticsNeverEchoProviderLogsOrAccounts() {
        let secret="private-address-or-transaction"
        for value:SolanaJSON in [.string(secret),.object(["InstructionError":.array([.number("0"),.string(secret)])]),.object(["logs":.array([.string(secret)])])] {
            XCTAssertFalse(SolanaSendClient.simulationError(value).localizedDescription.contains(secret))
        }
        XCTAssertEqual(SolanaSendClient.simulationError(.object(["InstructionError":.array([.number("2"),.object(["Custom":.number("17")])])])).code,17)
        XCTAssertEqual(SolanaSendClient.simulationError(.string("BlockhashNotFound")).localizedDescription,"BlockhashNotFound")
    }
    func testAcceptedPendingFinalizedFailureAndExactReplay() async throws {
        let (p,t,c)=try setup(),signed=try SolanaSendCrypto.sign(p,privateKey:Data(repeating:1,count:32));await t.setSigned(signed)
        for _ in 0..<2 { let result=try await c.submit(signed,plan:p);XCTAssertEqual(result.outcome,.accepted) }
        let payloads=await t.broadcasts;XCTAssertEqual(payloads,[signed.bytes,signed.bytes])
        await t.setMode("confirmed");let pending=try await c.status(signed,plan:p);XCTAssertEqual(pending.outcome,.accepted)
        await t.setMode("finalized");let final=try await c.status(signed,plan:p);XCTAssertEqual(final.outcome,.confirmed)
        await t.setMode("failed");let failed=try await c.status(signed,plan:p);XCTAssertEqual(failed.outcome,.failed)
        await t.setMode("forged");do { _ = try await c.status(signed,plan:p);XCTFail("Wrong bytes accepted") } catch { XCTAssertEqual(error as? SolanaSendError,.changed) }
    }
    func testExpiryRequiresFinalizedHeightAndHistoricalReceiptCheck() async throws {
        let (p,t,c)=try setup(),signed=try SolanaSendCrypto.sign(p,privateKey:Data(repeating:1,count:32));await t.setSigned(signed)
        let pending=try await c.status(signed,plan:p);XCTAssertEqual(pending.outcome,.unknown)
        await t.setMode("expired");let expired=try await c.status(signed,plan:p);XCTAssertEqual(expired.outcome,.expired)
        let methods=await t.methods;XCTAssertTrue(methods.contains("getTransaction"))
        await t.setMode("lateReceipt");let late=try await c.status(signed,plan:p);XCTAssertEqual(late.outcome,.confirmed)
        await t.setMode("pruned")
        do { _ = try await c.status(signed,plan:p);XCTFail("A pruned archive cannot release a possibly executed payment") }
        catch { XCTAssertEqual(error as? SolanaSendError,.rpc(-32001)) }
    }
    func testCancellationNeverFallsThroughToAnotherProvider() async throws {
        let (p,t,_)=try setup("cancel"),c=try SolanaSendClient(network:.mainnet,apiKey:"fixture",transport:t)
        do { _ = try await c.quote(sender:p.sender,recipient:p.recipient,reference:"native",decimals:9,amount:"1");XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let methods=await t.methods;XCTAssertEqual(methods,["getGenesisHash"])
    }
}
private actor SolanaRPCFixture:AnkrTransport {
    let p:SolanaSendPlan
    var mode:String,signed:SolanaSignedSend?
    var methods=[String](),broadcasts=[Data]()
    init(plan:SolanaSendPlan,mode:String) { p=plan;self.mode=mode }
    func setMode(_ m:String) { mode=m }
    func setSigned(_ s:SolanaSignedSend) { signed=s }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let body=try JSONDecoder().decode(SolanaJSON.self,from:request.httpBody!),method=body["method"].string!,params=body["params"].array!
        methods.append(method)
        if mode=="cancel" { throw CancellationError() }
        func n(_ x:UInt64)->SolanaJSON { .number(String(x)) }
        func wrap(_ value:SolanaJSON)->SolanaJSON { .object(["context":.object(["slot":n(mode=="stale" ? 1:p.slot)]),"value":value]) }
        func token(_ amount:UInt64,owner:String?=nil)->SolanaJSON {
            .object(["owner":.string(p.program),"data":.object(["parsed":.object(["type":.string("account"),"info":.object(["mint":.string(p.reference),"owner":.string(owner ?? p.sender),"state":.string(mode=="frozen" || (mode=="partiallyFrozen" && amount==40_000_000) ? "frozen":"initialized"),"tokenAmount":.object(["decimals":n(6),"amount":.string(String(amount))])])])])])
        }
        let result:SolanaJSON
        switch method {
        case "getGenesisHash":result = .string(mode=="wrongNetwork" ? SolanaSendNetwork.testnet.genesis:p.network.genesis)
        case "getLatestBlockhash":result = .object(["context":.object(["slot":n(p.slot)]),"value":.object(["blockhash":.string(p.blockhash),"lastValidBlockHeight":n(p.lastValidBlockHeight)])])
        case "getBalance":result=wrap(n(mode=="poor" ? 100:100_000_000))
        case "getAccountInfo":
            let address=params[0].string!
            if address==p.sender { result=wrap(.object(["owner":.string(mode=="senderProgram" ? SolanaIdentity.tokenProgram:SolanaSendCrypto.system),"space":n(0),"executable":.bool(false)])) }
            else if address==p.reference {
                let f:SolanaJSON = .object(["epoch":n(0),"transferFeeBasisPoints":n(100),"maximumFee":.string("1000000")])
                var extensions:[SolanaJSON]=mode=="hook" ? [.object(["extension":.string("transferHook")])]:p.tokenFees.isEmpty ? []:[.object(["extension":.string("transferFeeConfig"),"state":.object(["olderTransferFee":f,"newerTransferFee":f])])]
                if mode.hasPrefix("default") { extensions=[.object(["extension":.string("defaultAccountState"),"state":.object(["accountState":.string(mode=="defaultFrozen" ? "frozen":"initialized")])])] }
                result=wrap(.object(["owner":.string(mode=="mintOwner" ? SolanaSendCrypto.system:p.program),"data":.object(["parsed":.object(["type":.string("mint"),"info":.object(["isInitialized":.bool(true),"decimals":n(mode=="decimals" ? 9:6),"extensions":mode=="extensionType" ? .string("unexpected"):.array(extensions)])])])]))
            } else if address==p.recipient,mode=="recipientTokenAccount" { result=wrap(.object(["owner":.string(SolanaIdentity.tokenProgram)])) }
            else if address==p.recipient,mode=="activeRecipient" { result=wrap(.object(["owner":.string(SolanaSendCrypto.system),"space":n(0),"executable":.bool(false)])) }
            else if mode=="existingATA",address != p.recipient { result=wrap(token(0,owner:p.recipient)) }
            else { result=wrap(.null) }
        case "getEpochInfo":result = .object(["epoch":n(1)])
        case "getTokenAccountsByOwner":result=wrap(.array([.object(["pubkey":.string(p.sources[0].address),"account":token(60_000_000)]),.object(["pubkey":.string(p.blockhash),"account":token(40_000_000)])]))
        case "getMinimumBalanceForRentExemption":result=n(params[0].integer==0 ? 890880:2039280)
        case "getRecentPrioritizationFees":result = .array([.object(["prioritizationFee":n(1000)])])
        case "simulateTransaction":
            let error:SolanaJSON = mode.hasPrefix("rent") ? .object(["InsufficientFundsForRent":.object(["account_index":n(mode=="rentRecipient" ? 1:0)])]):mode=="simulation" ? .string("fixtureFailure"):.null
            result=wrap(.object(["err":error,"unitsConsumed":n(15000)]))
        case "getFeeForMessage":result=wrap(mode=="feeMissing" ? .null:n(5000))
        case "isBlockhashValid":result=wrap(.bool(true))
        case "getBlockHeight":result=n(["expired","lateReceipt","pruned"].contains(mode) ? p.lastValidBlockHeight+1:p.lastValidBlockHeight)
        case "getFirstAvailableBlock":result=n(mode=="pruned" ? p.slot+1:0)
        case "getSignatureStatuses":
            result=wrap(.array([(["finalized","failed","forged","confirmed"].contains(mode) ? .object(["slot":n(p.slot),"err":.null,"confirmationStatus":.string(mode=="confirmed" ? "confirmed":"finalized")]):.null)]))
        case "getTransaction":
            XCTAssertEqual(params[1]["maxSupportedTransactionVersion"], .number("1"))
            XCTAssertEqual(params[1]["encoding"].string, "base64")
            if ["expired","pruned"].contains(mode) { result = .null }
            else { result = .object(["transaction":.array([.string(mode=="forged" ? Data([0]).base64EncodedString():signed!.bytes.base64EncodedString()),.string("base64")]),"slot":n(p.slot),"blockTime":n(1_800_000_000),"meta":.object(["err":mode=="failed" ? .string("fixtureFailure"):.null,"fee":n(5000)])]) }
        case "sendTransaction":broadcasts.append(Data(base64Encoded:params[0].string!)!);result = .string(signed!.hash)
        default:throw SolanaSendError.malformed
        }
        return (try JSONEncoder().encode(SolanaJSON.object(["id":n(1),"jsonrpc":.string("2.0"),"result":result])),200)
    }
}
