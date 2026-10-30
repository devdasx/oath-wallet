import XCTest
@testable import OathAnkr
@testable import OathDatabase

/// Real public testnet only. Fixture keys are disposable, local, never printed.
/// Deploy with Tools/PrepareZeroGTestnetSend.cjs. No mainnet endpoint is accepted.
@MainActor final class ZeroGSendLiveTests: XCTestCase {
    struct Wallet: Decodable { let address:String; let privateKey:String }
    struct Wallets: Decodable { let network:UInt64;let wallets:[Wallet] }
    struct Contracts: Decodable { let network:UInt64;let contracts:[String:String] }
    let endpoint=URL(string:"https://evmrpc-testnet.0g.ai")!
    func rpc(_ method:String,_ params:[SolanaJSON]) async throws -> SolanaJSON {
        var request=URLRequest(url:endpoint);request.httpMethod="POST";request.timeoutInterval=20
        request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.setValue("OathWallet/1.0",forHTTPHeaderField:"User-Agent")
        request.httpBody=try JSONEncoder().encode(SolanaJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string(method),"params":.array(params)]))
        let (data,status)=try await AnkrHTTPTransport().send(request);XCTAssertEqual(status,200)
        let result=try JSONDecoder().decode(SolanaJSON.self,from:data)
        guard result["error"].isNull else { throw EVMSendError.transport }
        return result["result"]
    }
    func fixture() throws -> URL {
        guard ProcessInfo.processInfo.environment["OATH_ZEROG_SEND_LIVE"]=="1",let folder=ProcessInfo.processInfo.environment["OATH_ZEROG_SEND_FIXTURE"] else { throw XCTSkip("Opt-in disposable 0G Galileo broadcast") }
        return URL(fileURLWithPath:folder)
    }
    func testRealNativeTokensMaxFeeAdjustmentAndDurableRecovery() async throws {
        let folder=try fixture()
        guard ProcessInfo.processInfo.environment["OATH_ZEROG_RECONCILE"] != "1" else { throw XCTSkip("Reconcile only") }
        let wallets=try JSONDecoder().decode(Wallets.self,from:Data(contentsOf:folder.appendingPathComponent("wallets.json")))
        let contracts=try JSONDecoder().decode(Contracts.self,from:Data(contentsOf:folder.appendingPathComponent("contracts.json")))
        XCTAssertEqual(wallets.network,16602);XCTAssertEqual(contracts.network,16602)
        guard wallets.network==16602,contracts.network==16602 else { throw EVMSendError.wrongNetwork }
        let chain=try await rpc("eth_chainId",[]);XCTAssertEqual(chain.string,"0x40da")
        let client=try EVMSendClient(network:.zerogGalileo,endpoints:[endpoint])
        let dbURL=folder.appendingPathComponent("send-journal.sqlite")
        let db=try await OathDatabase.open(at:dbURL)
        let refs=["native",try XCTUnwrap(contracts.contracts["Token6"]),try XCTUnwrap(contracts.contracts["Token18"])]
        try await db.seed(networks:[.init(id:"zerogGalileo",name:"0G Galileo",family:"account",symbol:"0G",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"zerog",sortOrder:0)],assets:refs.enumerated().map { i,ref in .init(id:"zerogGalileo:"+ref,networkID:"zerogGalileo",reference:ref,name:"Disposable test asset",symbol:i==0 ? "0G":"TEST",decimals:i==1 ? 6:18) })
        for (i,wallet) in wallets.wallets.enumerated() {
            try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Disposable test wallet",kind:"privateKey",vaultReference:"local-test-only-\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"zerogGalileo",address:wallet.address.lowercased(),derivationPath:"m/44'/60'/0'/0/0")])
        }
        let sender=wallets.wallets[0].address.lowercased(),recipient=wallets.wallets[3].address.lowercased()
        // Rejections are real RPC executions, before any signing/broadcast.
        for (ref,to,decimals,amount,expected) in [
            (try XCTUnwrap(contracts.contracts["FalseToken"]),recipient,6,"1","false"),
            ("native",try XCTUnwrap(contracts.contracts["Reject"]),18,"1","revert"),
            (refs[1],recipient,18,"1","decimals"),
            (refs[1],recipient,6,"1000000000000000000000000","balance")] {
            do { _ = try await client.quote(sender:sender,recipient:to,reference:ref,decimals:decimals,amount:amount);XCTFail("Expected \(expected) rejection") }
            catch {
                switch expected {
                case "false":XCTAssertEqual(error as? EVMSendError,.simulationFailed)
                case "decimals":XCTAssertEqual(error as? EVMSendError,.metadataChanged)
                case "balance":XCTAssertEqual(error as? EVMSendError,.insufficientFunds)
                default:guard case EVMSendError.rpc = error else { return XCTFail("Expected contract execution rejection") }
                }
            }
        }
        // A token-only address cannot send without ZEROG (tested again after receipt below).
        let finalStage=ProcessInfo.processInfo.environment["OATH_ZEROG_SEND_STAGE"]=="final"
        var proofs=finalStage ? try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("proof.json"))) as? [[String:String]]):[]
        let scenarios:[(String,Int,String,Int,String,Bool,String)] = finalStage ? [
            ("token18-final",0,refs[2],18,"123",false,recipient),
            ("token18-max",0,refs[2],18,"1",true,recipient),
            ("payable-max",0,"native",18,"1",true,try XCTUnwrap(contracts.contracts["Payable"]))] : [
            ("native",0,refs[0],18,"1000000000000000",false,recipient),
            ("token6",0,refs[1],6,"1234567",false,wallets.wallets[2].address.lowercased()),
            ("token18",0,refs[2],18,"1234567890123456789",false,recipient),
            ("token6-max",0,refs[1],6,"1",true,recipient),
            ("payable-positive",0,"native",18,"123",false,try XCTUnwrap(contracts.contracts["Payable"])),
            ("native-near-max",1,"native",18,"4999999999999999",false,recipient),
            ("native-max",2,"native",18,"1",true,recipient)]
        for (label,index,ref,decimals,amount,maximum,to) in scenarios {
            let wallet=wallets.wallets[index],owner=wallet.address.lowercased()
            let hex=wallet.privateKey.hasPrefix("0x") ? String(wallet.privateKey.dropFirst(2)):wallet.privateKey
            guard hex.count==64 else { throw EVMSendError.malformed }
            let chars=Array(hex)
            let key=try Data(stride(from:0,to:64,by:2).map { try XCTUnwrap(UInt8(String(chars[$0...($0+1)]),radix:16)) })
            XCTAssertEqual(try EVMSendCrypto.address(privateKey:key),owner)
            async let gasBeforeTask=client.balance(owner:owner,reference:"native")
            async let assetBeforeTask=client.balance(owner:owner,reference:ref)
            async let recipientBeforeTask=client.balance(owner:to,reference:ref)
            let (gasBefore,assetBefore,recipientBefore)=try await (gasBeforeTask,assetBeforeTask,recipientBeforeTask)
            let plan=try await client.quote(sender:owner,recipient:to,reference:ref,decimals:decimals,amount:amount,maximum:maximum)
            if label=="native" { XCTAssertEqual(plan.amount,amount) }
            if label=="native-near-max" || label=="native-max" || label=="payable-max" { XCTAssertTrue(EVMSendAmount.less(plan.amount,plan.requestedAmount));XCTAssertEqual(try EVMSendAmount.add(plan.amount,String(plan.fee)),gasBefore) }
            let id="zerog-live-"+label
            try await db.saveDraft(.init(id:id,walletID:"w\(index)",accountID:"a\(index)",networkID:"zerogGalileo",assetID:"zerogGalileo:"+ref,idempotencyKey:id,recipient:to,amountAtomic:plan.amount,state:"draft",createdAt:Date.now.timeIntervalSince1970,updatedAt:Date.now.timeIntervalSince1970))
            try await db.queueValidatedEVMSend(sendID:id,plan:plan)
            try await client.preflight(plan)
            let signed=try EVMSendCrypto.sign(plan,privateKey:key)
            try await db.journalEVMSignature(sendID:id,signed:signed,allowingTestnet:true)
            // Reopen durable storage BEFORE broadcast, as the background recovery worker does.
            let reopened=try await OathDatabase.open(at:dbURL)
            let stored=try await reopened.send(id),restored=try await reopened.evmSendPlan(sendID:id)
            let recovered=try JSONDecoder().decode(EVMSignedSend.self,from:XCTUnwrap(stored?.signedPayload))
            XCTAssertTrue(recovered==signed);XCTAssertTrue(restored==plan)
            _ = try await reopened.transitionSend(id,from:"signed",to:"broadcast")
            let accepted=try await client.submit(recovered,plan:plan,reconcileFirst:false)
            XCTAssertEqual(accepted.outcome,.accepted);try await reopened.settleEVMSend(sendID:id,receipt:accepted,allowingTestnet:true)
            var mined=SolanaJSON.null
            for _ in 0..<30 {
                mined=try await rpc("eth_getTransactionReceipt",[.string(signed.hash)])
                if !mined.isNull { break };try await Task.sleep(for:.seconds(2))
            }
            XCTAssertEqual(mined["status"].string,"0x1")
            let gas=try XCTUnwrap(mined["gasUsed"].string).dropFirst(2),price=try XCTUnwrap(mined["effectiveGasPrice"].string).dropFirst(2)
            let actualFee=try XCTUnwrap(UInt64(gas,radix:16))*XCTUnwrap(UInt64(price,radix:16))
            // A receipt can arrive before all public RPC replicas advance latest.
            // Compare exact post-receipt state at one pinned, stable block.
            try await Task.sleep(for:.seconds(3))
            let receiptHeight=try XCTUnwrap(UInt64(XCTUnwrap(mined["blockNumber"].string).dropFirst(2),radix:16))
            let post=try await client.balancesAfter(plan,minimumHeight:receiptHeight)
            let gasAfter=post.native,assetAfter=post.asset
            let recipientAfter=try await client.balance(owner:to,reference:ref,tag:.string("0x"+String(post.height,radix:16)))
            XCTAssertEqual(try EVMSendAmount.subtract(recipientAfter,recipientBefore),plan.amount)
            XCTAssertEqual(try EVMSendAmount.subtract(assetBefore,assetAfter),try EVMSendAmount.add(plan.amount,ref=="native" ? String(actualFee):"0"))
            XCTAssertEqual(try EVMSendAmount.subtract(gasBefore,gasAfter),try EVMSendAmount.add(ref=="native" ? plan.amount:"0",String(actualFee)))
            XCTAssertLessThanOrEqual(actualFee,plan.fee)
            if maximum,ref != "native" { XCTAssertEqual(assetAfter,"0") }
            let duplicate=try await client.submit(recovered,plan:plan)
            XCTAssertTrue([EVMSendReceipt.Outcome.accepted,.confirmed].contains(duplicate.outcome))
            let afterReplay=try await client.balance(owner:to,reference:ref);XCTAssertEqual(afterReplay,recipientAfter)
            try await reopened.settleEVMSend(sendID:id,receipt:duplicate,allowingTestnet:true)
            proofs.append(["scenario":label,"hash":signed.hash,"amount":plan.amount,"fee":String(actualFee),"status":duplicate.outcome.rawValue,"exactBalanceDeltas":"true"])
            try JSONSerialization.data(withJSONObject:proofs,options:.prettyPrinted).write(to:folder.appendingPathComponent("proof.json"))
            print("ZEROG_TESTNET mined \(label) hash=\(signed.hash) exact_balance_deltas=true durable_recovery=true duplicate_safe=true")
        }
    }
    func testRealTokenWithInsufficientZEROGHasActionableFeeError() async throws {
        let folder=try fixture()
        guard FileManager.default.fileExists(atPath:folder.appendingPathComponent("proof.json").path) else { throw XCTSkip("Run funded send scenarios first") }
        let wallets=try JSONDecoder().decode(Wallets.self,from:Data(contentsOf:folder.appendingPathComponent("wallets.json")))
        let contracts=try JSONDecoder().decode(Contracts.self,from:Data(contentsOf:folder.appendingPathComponent("contracts.json")))
        guard wallets.network==16602 else { throw EVMSendError.wrongNetwork }
        let client=try EVMSendClient(network:.zerogGalileo,endpoints:[endpoint])
        do {
            _ = try await client.quote(sender:wallets.wallets[2].address.lowercased(),recipient:wallets.wallets[0].address.lowercased(),reference:try XCTUnwrap(contracts.contracts["Token6"]),decimals:6,amount:"1")
            XCTFail("Token holder without enough ZEROG must not sign")
        } catch { XCTAssertEqual(error as? SendFeeFundingError,.insufficientNativeBalance) }
    }
    func testReconcileRealTestnetJournalAfterFinality() async throws {
        let folder=try fixture()
        guard ProcessInfo.processInfo.environment["OATH_ZEROG_RECONCILE"]=="1" else { throw XCTSkip("Separate finality reconciliation") }
        let proofs=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("proof.json"))) as? [[String:String]])
        let db=try await OathDatabase.open(at:folder.appendingPathComponent("send-journal.sqlite"))
        let client=try EVMSendClient(network:.zerogGalileo,endpoints:[endpoint])
        var verified=proofs
        for (index,proof) in proofs.enumerated() {
            let id="zerog-live-"+(try XCTUnwrap(proof["scenario"]))
            let stored=try await db.send(id),savedPlan=try await db.evmSendPlan(sendID:id)
            let signed=try JSONDecoder().decode(EVMSignedSend.self,from:XCTUnwrap(stored?.signedPayload)),plan=try XCTUnwrap(savedPlan)
            let receipt=try await client.status(signed,plan:plan)
            XCTAssertEqual(receipt.outcome,.confirmed)
            XCTAssertEqual(receipt.fee.map(String.init),proof["fee"])
            try await db.settleEVMSend(sendID:id,receipt:receipt,allowingTestnet:true)
            let settled=try await db.send(id);XCTAssertEqual(settled?.state,"confirmed")
            verified[index]["status"]="confirmed"
            verified[index]["finalizedBlock"]=receipt.height.map(String.init)
            print("ZEROG_TESTNET finalized \(proof["scenario"]!) hash=\(signed.hash)")
        }
        try JSONSerialization.data(withJSONObject:verified,options:.prettyPrinted).write(to:folder.appendingPathComponent("proof.json"))
    }
}

extension ZeroGSendLiveTests {
    func testRecoverMinedMaxTransferAfterLaggingBalanceRead() async throws {
        let folder = try fixture()
        guard ProcessInfo.processInfo.environment["OATH_ZEROG_RECOVER_MAX"] == "1" else { throw XCTSkip("Read-only recovery of the saved Max transfer") }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("send-journal.sqlite"))
        let id = "zerog-live-payable-max"
        let saved = try await db.send(id), savedPlan = try await db.evmSendPlan(sendID: id)
        let plan = try XCTUnwrap(savedPlan)
        guard plan.network == .zerogGalileo else { throw EVMSendError.wrongNetwork }
        let signed = try JSONDecoder().decode(EVMSignedSend.self, from: XCTUnwrap(saved?.signedPayload))
        let client = try EVMSendClient(network: .zerogGalileo, endpoints: [endpoint])
        let receipt = try await client.status(signed, plan: plan)
        XCTAssertEqual(receipt.outcome, .confirmed)
        let fee = try XCTUnwrap(receipt.fee), height = try XCTUnwrap(receipt.height)
        let post = try await client.balancesAfter(plan, minimumHeight: height)
        async let beforeWork = client.balance(owner: plan.recipient, reference: "native", tag: .string("0x" + String(plan.blockHeight, radix: 16)))
        async let afterWork = client.balance(owner: plan.recipient, reference: "native", tag: .string("0x" + String(post.height, radix: 16)))
        let (before, after) = try await (beforeWork, afterWork)
        XCTAssertEqual(try EVMSendAmount.subtract(after, before), plan.amount)
        XCTAssertEqual(try EVMSendAmount.subtract(plan.nativeBalance, post.native), try EVMSendAmount.add(plan.amount, String(fee)))
        XCTAssertEqual(try EVMSendAmount.add(plan.amount, String(plan.fee)), plan.nativeBalance)
        XCTAssertLessThanOrEqual(fee, plan.fee)
        let replay = try await client.submit(signed, plan: plan)
        XCTAssertEqual(replay, receipt)
        try await db.settleEVMSend(sendID: id, receipt: receipt, allowingTestnet: true)
        let settled = try await db.send(id)
        XCTAssertEqual(settled?.state, "confirmed")
        var proofs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("proof.json"))) as? [[String:String]])
        proofs.removeAll { $0["scenario"] == "payable-max" }
        proofs.append(["scenario":"payable-max", "hash":signed.hash, "amount":plan.amount, "fee":String(fee), "status":"confirmed", "exactBalanceDeltas":"true", "recoveredAfterReplicaLag":"true"])
        try JSONSerialization.data(withJSONObject: proofs, options: .prettyPrinted).write(to: folder.appendingPathComponent("proof.json"))
    }
}
