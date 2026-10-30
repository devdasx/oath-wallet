import XCTest
import OathDiagnostics
@testable import OathAnkr
@testable import OathDatabase

/// Real public testnet only. Fixture keys are disposable, local, never printed.
/// Deploy with Tools/PrepareIoTeXTestnetSend.cjs. No mainnet endpoint is accepted.
@MainActor final class IoTeXSendLiveTests: XCTestCase {
    struct Wallet: Decodable { let address:String; let privateKey:String }
    struct Wallets: Decodable { let network:UInt64;let wallets:[Wallet] }
    struct Contracts: Decodable { let network:UInt64;let contracts:[String:String] }
    let endpoint=URL(string:"https://babel-api.testnet.iotex.io")!
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
        guard ProcessInfo.processInfo.environment["OATH_IOTEX_SEND_LIVE"]=="1",let folder=ProcessInfo.processInfo.environment["OATH_IOTEX_SEND_FIXTURE"] else { throw XCTSkip("Opt-in disposable IoTeX testnet broadcast") }
        return URL(fileURLWithPath:folder)
    }
    func testRealNativeTokensMaxFeeAdjustmentAndDurableRecovery() async throws {
        let folder=try fixture()
        guard ProcessInfo.processInfo.environment["OATH_IOTEX_RECONCILE"] != "1" else { throw XCTSkip("Reconcile only") }
        let wallets=try JSONDecoder().decode(Wallets.self,from:Data(contentsOf:folder.appendingPathComponent("wallets.json")))
        let contracts=try JSONDecoder().decode(Contracts.self,from:Data(contentsOf:folder.appendingPathComponent("contracts.json")))
        XCTAssertEqual(wallets.network,4690);XCTAssertEqual(contracts.network,4690)
        guard wallets.network==4690,contracts.network==4690 else { throw EVMSendError.wrongNetwork }
        let chain=try await rpc("eth_chainId",[]);XCTAssertEqual(chain.string,"0x1252")
        let client=try EVMSendClient(network:.iotexTestnet,endpoints:[endpoint,URL(string:"https://babel-api.testnet.iotex.one")!],transport:IoTeXLiveSendTransport())
        let dbURL=folder.appendingPathComponent(ProcessInfo.processInfo.environment["OATH_IOTEX_SEND_JOURNAL"] ?? "send-journal.sqlite")
        let db=try await OathDatabase.open(at:dbURL)
        let refs=["native",try XCTUnwrap(contracts.contracts["Token6"]),try XCTUnwrap(contracts.contracts["Token18"])]
        try await db.seed(networks:[.init(id:"iotexTestnet",name:"IoTeX testnet",family:"account",symbol:"IOTX",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"iotex",sortOrder:0)],assets:refs.enumerated().map { i,ref in .init(id:"iotexTestnet:"+ref,networkID:"iotexTestnet",reference:ref,name:"Disposable test asset",symbol:i==0 ? "IOTX":"TEST",decimals:i==1 ? 6:18) })
        for (i,wallet) in wallets.wallets.enumerated() {
            try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Disposable test wallet",kind:"privateKey",vaultReference:"local-test-only-\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"iotexTestnet",address:wallet.address.lowercased(),derivationPath:"m/44'/60'/0'/0/0")])
        }
        let sender=wallets.wallets[0].address.lowercased(),recipient=wallets.wallets[3].address.lowercased()
        // Rejections are real RPC executions, before any signing/broadcast.
        for (ref,to,decimals,amount,expected) in [
            (try XCTUnwrap(contracts.contracts["FalseToken"]),recipient,6,"1","false"),
            ("native",try XCTUnwrap(contracts.contracts["Reject"]),18,"1","revert"),
            (refs[1],recipient,18,"1","decimals"),
            (refs[1],recipient,6,"1000000000000000000000000","balance")] {
            print("IOTEX_TESTNET rejection \(expected)")
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
        // A token-only address cannot send without IOTX (tested again after receipt below).
        let finalStage=ProcessInfo.processInfo.environment["OATH_IOTEX_SEND_STAGE"]=="final"
        var proofs=FileManager.default.fileExists(atPath:folder.appendingPathComponent("proof.json").path) ? try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("proof.json"))) as? [[String:String]]):[]
        let scenarios:[(String,Int,String,Int,String,Bool,String)] = finalStage ? [
            ("native-io-address",0,"native",18,"123",false,recipient),
            ("token18-final",0,refs[2],18,"123",false,recipient),
            ("token18-max",0,refs[2],18,"1",true,recipient),
            ("payable-max",0,"native",18,"1",true,try XCTUnwrap(contracts.contracts["Payable"]))] : [
            ("native",0,refs[0],18,"1000000000000000",false,recipient),
            ("token6",0,refs[1],6,"1234567",false,wallets.wallets[2].address.lowercased()),
            ("token18",0,refs[2],18,"1234567890123456789",false,recipient),
            ("token6-max",0,refs[1],6,"1",true,recipient),
            ("payable-positive",0,"native",18,"123",false,try XCTUnwrap(contracts.contracts["Payable"])),
            ("native-near-max",1,"native",18,"499999999999999999",false,recipient),
            ("native-max",2,"native",18,"1",true,recipient)]
        for (label,index,ref,decimals,amount,maximum,to) in scenarios {
            if proofs.contains(where: { $0["scenario"] == label }) { continue }
            print("IOTEX_TESTNET starting \(label)")
            let wallet=wallets.wallets[index],owner=wallet.address.lowercased()
            let hex=wallet.privateKey.hasPrefix("0x") ? String(wallet.privateKey.dropFirst(2)):wallet.privateKey
            guard hex.count==64 else { throw EVMSendError.malformed }
            let chars=Array(hex)
            let key=try Data(stride(from:0,to:64,by:2).map { try XCTUnwrap(UInt8(String(chars[$0...($0+1)]),radix:16)) })
            XCTAssertEqual(try EVMSendCrypto.address(privateKey:key),owner)
            let id="iotex-live-"+label
            let snapshotURL=folder.appendingPathComponent("before-"+label+".json")
            let existing=try await db.send(id)
            let fresh=existing?.signedPayload == nil
            let gasBefore:String,assetBefore:String,recipientBefore:String,plan:EVMSendPlan,signed:EVMSignedSend
            if let payload=existing?.signedPayload {
                let savedPlan=try await db.evmSendPlan(sendID:id)
                plan=try XCTUnwrap(savedPlan)
                signed=try JSONDecoder().decode(EVMSignedSend.self,from:payload)
                let before=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:snapshotURL))
                gasBefore=try XCTUnwrap(before["native"]);assetBefore=try XCTUnwrap(before["asset"]);recipientBefore=try XCTUnwrap(before["recipient"])
                guard plan.sender==owner,plan.recipient==to,plan.reference==ref,plan.network == .iotexTestnet else { throw EVMSendError.changed }
                try EVMSendCrypto.verify(signed,plan:plan)
            } else {
                async let gasBeforeTask=client.balance(owner:owner,reference:"native")
                async let assetBeforeTask=client.balance(owner:owner,reference:ref)
                async let recipientBeforeTask=client.balance(owner:to,reference:ref)
                (gasBefore,assetBefore,recipientBefore)=try await (gasBeforeTask,assetBeforeTask,recipientBeforeTask)
                plan=try await client.quote(sender:owner,recipient:label=="native-io-address" ? IoTeXIdentity.native(to):to,reference:ref,decimals:decimals,amount:amount,maximum:maximum)
                if label=="native",let expected=ProcessInfo.processInfo.environment["OATH_IOTEX_EXPECTED_START_NONCE"] {
                    // A corrected test may replace a definitively rejected fee envelope,
                    // but it must never allocate a new nonce and create a second payment.
                    guard plan.nonce == UInt64(expected) else { throw EVMSendError.changed }
                }
                if label=="native" { XCTAssertEqual(plan.amount,amount) }
                if label=="native-near-max" || label=="native-max" || label=="payable-max" { XCTAssertTrue(EVMSendAmount.less(plan.amount,plan.requestedAmount));XCTAssertEqual(try EVMSendAmount.add(plan.amount,String(plan.fee)),gasBefore) }
                try JSONEncoder().encode(["native":gasBefore,"asset":assetBefore,"recipient":recipientBefore]).write(to:snapshotURL,options:.atomic)
                try await db.saveDraft(.init(id:id,walletID:"w\(index)",accountID:"a\(index)",networkID:"iotexTestnet",assetID:"iotexTestnet:"+ref,idempotencyKey:id,recipient:to,amountAtomic:plan.amount,state:"draft",createdAt:Date.now.timeIntervalSince1970,updatedAt:Date.now.timeIntervalSince1970))
                try await db.queueValidatedEVMSend(sendID:id,plan:plan)
                try await client.preflight(plan)
                signed=try EVMSendCrypto.sign(plan,privateKey:key)
                try await db.journalEVMSignature(sendID:id,signed:signed,allowingTestnet:true)
            }
            // Reopen durable storage BEFORE broadcast, as the background recovery worker does.
            let reopened=try await OathDatabase.open(at:dbURL)
            let stored=try await reopened.send(id),restored=try await reopened.evmSendPlan(sendID:id)
            let recovered=try JSONDecoder().decode(EVMSignedSend.self,from:XCTUnwrap(stored?.signedPayload))
            XCTAssertTrue(recovered==signed);XCTAssertTrue(restored==plan)
            if stored?.state=="signed" { _ = try await reopened.transitionSend(id,from:"signed",to:"broadcast") }
            let accepted=try await client.submit(recovered,plan:plan,reconcileFirst:!fresh)
            XCTAssertTrue([EVMSendReceipt.Outcome.accepted,.confirmed].contains(accepted.outcome));try await reopened.settleEVMSend(sendID:id,receipt:accepted,allowingTestnet:true)
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
            print("IOTEX_TESTNET mined \(label) hash=\(signed.hash) exact_balance_deltas=true durable_recovery=true duplicate_safe=true")
        }
    }
    func testRealTokenWithInsufficientIOTEXHasActionableFeeError() async throws {
        let folder=try fixture()
        guard FileManager.default.fileExists(atPath:folder.appendingPathComponent("proof.json").path) else { throw XCTSkip("Run funded send scenarios first") }
        let wallets=try JSONDecoder().decode(Wallets.self,from:Data(contentsOf:folder.appendingPathComponent("wallets.json")))
        let contracts=try JSONDecoder().decode(Contracts.self,from:Data(contentsOf:folder.appendingPathComponent("contracts.json")))
        guard wallets.network==4690 else { throw EVMSendError.wrongNetwork }
        let client=try EVMSendClient(network:.iotexTestnet,endpoints:[endpoint,URL(string:"https://babel-api.testnet.iotex.one")!],transport:IoTeXLiveSendTransport())
        do {
            _ = try await client.quote(sender:wallets.wallets[2].address.lowercased(),recipient:wallets.wallets[0].address.lowercased(),reference:try XCTUnwrap(contracts.contracts["Token6"]),decimals:6,amount:"1")
            XCTFail("Token holder without enough IOTX must not sign")
        } catch { XCTAssertEqual(error as? SendFeeFundingError,.insufficientNativeBalance) }
    }
    func testReconcileRealTestnetJournalAfterFinality() async throws {
        let folder=try fixture()
        guard ProcessInfo.processInfo.environment["OATH_IOTEX_RECONCILE"]=="1" else { throw XCTSkip("Separate finality reconciliation") }
        let proofs=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("proof.json"))) as? [[String:String]])
        let db=try await OathDatabase.open(at:folder.appendingPathComponent(ProcessInfo.processInfo.environment["OATH_IOTEX_SEND_JOURNAL"] ?? "send-journal.sqlite"))
        let client=try EVMSendClient(network:.iotexTestnet,endpoints:[endpoint,URL(string:"https://babel-api.testnet.iotex.one")!],transport:IoTeXLiveSendTransport())
        var verified=proofs
        for (index,proof) in proofs.enumerated() {
            let id="iotex-live-"+(try XCTUnwrap(proof["scenario"]))
            let stored=try await db.send(id),savedPlan=try await db.evmSendPlan(sendID:id)
            let signed=try JSONDecoder().decode(EVMSignedSend.self,from:XCTUnwrap(stored?.signedPayload)),plan=try XCTUnwrap(savedPlan)
            let receipt=try await client.status(signed,plan:plan)
            XCTAssertEqual(receipt.outcome,.confirmed)
            XCTAssertEqual(receipt.fee.map(String.init),proof["fee"])
            try await db.settleEVMSend(sendID:id,receipt:receipt,allowingTestnet:true)
            let settled=try await db.send(id);XCTAssertEqual(settled?.state,"confirmed")
            verified[index]["status"]="confirmed"
            verified[index]["finalizedBlock"]=receipt.height.map(String.init)
            print("IOTEX_TESTNET finalized \(proof["scenario"]!) hash=\(signed.hash)")
        }
        try JSONSerialization.data(withJSONObject:verified,options:.prettyPrinted).write(to:folder.appendingPathComponent("proof.json"))
    }
    func testRejectedEnvelopeRecognizesItsFinalizedReplacementWithoutBroadcast() async throws {
        let folder=try fixture()
        guard let rejectedJournal=ProcessInfo.processInfo.environment["OATH_IOTEX_REJECTED_JOURNAL"] else { throw XCTSkip("Requires the preserved zero-tip rejection fixture") }
        let original=try await OathDatabase.open(at:folder.appendingPathComponent(rejectedJournal))
        let send=try await original.send("iotex-live-native"),storedPlan=try await original.evmSendPlan(sendID:"iotex-live-native")
        let plan=try XCTUnwrap(storedPlan)
        guard plan.network == .iotexTestnet,plan.maxPriorityFeePerGas==0 else { throw EVMSendError.changed }
        let signed=try JSONDecoder().decode(EVMSignedSend.self,from:XCTUnwrap(send?.signedPayload))
        let proofs=try JSONDecoder().decode([[String:String]].self,from:Data(contentsOf:folder.appendingPathComponent("proof.json")))
        let replacement=try XCTUnwrap(proofs.first{$0["scenario"]=="native"}?["hash"])
        let client=try EVMSendClient(network:.iotexTestnet,endpoints:[endpoint,URL(string:"https://babel-api.testnet.iotex.one")!],transport:IoTeXReadOnlySendTransport())
        let receipt=try await client.submit(signed,plan:plan)
        XCTAssertEqual(receipt.outcome,.replaced);XCTAssertEqual(receipt.replacementHash,replacement)
        try await original.settleEVMSend(sendID:"iotex-live-native",receipt:receipt,allowingTestnet:true)
        let settled=try await original.send("iotex-live-native")
        XCTAssertEqual(settled?.failureCode,"replaced")
        try JSONEncoder().encode(["original":signed.hash,"replacement":replacement,"outcome":receipt.outcome.rawValue,"broadcastAllowed":"false"]).write(to:folder.appendingPathComponent("replacement-proof.json"))
    }
}

private struct IoTeXReadOnlySendTransport: AnkrTransport {
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let calls=try JSONDecoder().decode(SolanaJSON.self,from:XCTUnwrap(request.httpBody))
        guard !(calls.array ?? [calls]).contains(where:{$0["method"].string=="eth_sendRawTransaction"}) else { throw EVMSendError.changed }
        return try await AnkrHTTPTransport().send(request)
    }
}

private struct IoTeXLiveSendTransport: AnkrTransport {
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let (data,status) = try await AnkrHTTPTransport().send(request)
        let calls = try JSONDecoder().decode(SolanaJSON.self,from:request.httpBody ?? Data())
        let replies = try JSONDecoder().decode(SolanaJSON.self,from:data)
        for row in replies.array ?? [replies] where !row["error"].isNull {
            let method = (calls.array ?? [calls]).first{$0["id"]==row["id"]}?["method"].string ?? "unknown"
            print("IOTEX_RPC \(method) \(DiagnosticPrivacy.text(row["error"]["message"].string ?? "RPC rejection"))")
        }
        return (data,status)
    }
}
