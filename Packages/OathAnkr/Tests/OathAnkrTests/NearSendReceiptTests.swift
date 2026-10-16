import XCTest
@testable import OathAnkr

final class NearSendReceiptTests:XCTestCase,@unchecked Sendable {
    func testEveryRealTestnetReceiptUsingCurrentVerifier() async throws {
        let rows=try JSONDecoder().decode(NearJSON.self,from:NearSendTests.fixture("executions")).array!
        XCTAssertEqual(rows.count,8)
        for row in rows {
            let response=row["response"],tx=response["transaction"],expected=row["expected"]
            let pub=try SuiSendCrypto.unbase58(String(tx["public_key"].string!.dropFirst(8)))
            let p=try NearSendTests.changing(NearSendTests.plan(),[
                "sender":tx["signer_id"].string!,"recipient":tx["receiver_id"].string!,"publicKey":pub.base64EncodedString(),"nonce":tx["nonce"].integer!])
            // These are public final RPC receipts fetched independently with near-api-js.
            // Signature/Borsh validation is covered separately and by the live broadcaster.
            let signed=NearSignedSend(bytes:Data(),publicKey:pub,signature:Data(),hash:tx["hash"].string!)
            let client=try NearSendClient(network:.testnet,endpoints:[URL(string:"https://fixture.test")!],transport:NearReceiptBlockTransport(block:row["block"]))
            let result=try await client.receipt(response,signed:signed,plan:p)
            XCTAssertEqual(result.outcome.rawValue,expected["outcome"].string)
            XCTAssertEqual(result.fee,expected["fee"].string)
        }
    }
    private func envelope(_ p:NearSendPlan,_ s:NearSignedSend,failed:Bool=false) -> NearJSON {
        let id=SuiSendCrypto.base58(Data(repeating:9,count:32))
        let terminal:NearJSON=failed ? .object(["Failure":.object(["ActionError":.object([:])])]):.object(["SuccessValue":.string("")])
        func outcome(_ id:String,_ executor:String,_ children:[String],_ status:NearJSON) -> NearJSON {
            .object(["id":.string(id),"block_hash":.string(p.blockHash),"outcome":.object([
                "executor_id":.string(executor),"tokens_burnt":.string("3"),"receipt_ids":.array(children.map(NearJSON.string)),"status":status])])
        }
        return .object(["transaction":.object(["hash":.string(s.hash),"signer_id":.string(p.sender),"receiver_id":.string(p.receiver),
            "public_key":.string(NearSendCrypto.keyString(p.publicKey)),"nonce":.number(String(p.nonce))]),
            "final_execution_status":.string("FINAL"),"status":terminal,
            "transaction_outcome":outcome(s.hash,p.sender,[id],.object(["SuccessReceiptId":.string(id)])),
            "receipts_outcome":.array([outcome(id,p.receiver,[],terminal)])])
    }
    private func changing(_ value:NearJSON,_ edit:(inout [String:Any])->Void) throws -> NearJSON {
        var j=try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any]
        edit(&j);return try JSONDecoder().decode(NearJSON.self,from:JSONSerialization.data(withJSONObject:j))
    }
    func testFinalSuccessAndContractFailureAreDistinctFromInclusion() async throws {
        let p=try NearSendTests.plan(),s=try NearSendCrypto.sign(p,privateKey:NearSendTests.seed)
        let c=try NearSendClient(network:.testnet,endpoints:[URL(string:"https://primary.test")!],transport:NearSendMock())
        for failed in [false,true] {
            let j=envelope(p,s,failed:failed),r=try await c.receipt(j,signed:s,plan:p)
            XCTAssertEqual(r.outcome,failed ? .failed:.confirmed);XCTAssertEqual(r.fee,"6");XCTAssertEqual(r.block,101)
            let included=try changing(j){$0["final_execution_status"]="EXECUTED"}
            let pending=try await c.receipt(included,signed:s,plan:p);XCTAssertEqual(pending.outcome,.unknown)
        }
    }
    func testWrongIntentIncompleteOrContradictoryReceiptsCannotConfirm() async throws {
        let p=try NearSendTests.plan(),s=try NearSendCrypto.sign(p,privateKey:NearSendTests.seed),valid=envelope(p,s)
        let c=try NearSendClient(network:.testnet,endpoints:[URL(string:"https://primary.test")!],transport:NearSendMock())
        let edits:[(inout [String:Any])->Void]=[
            {var tx=$0["transaction"] as! [String:Any];tx["receiver_id"]="wrong.testnet";$0["transaction"]=tx},
            {$0["receipts_outcome"]=[]},
            {var rows=$0["receipts_outcome"] as! [[String:Any]];rows.append(rows[0]);$0["receipts_outcome"]=rows},
            {$0["status"]=["Failure":["ActionError":"contradiction"]]},
            {var root=$0["transaction_outcome"] as! [String:Any];var o=root["outcome"] as! [String:Any];o["receipt_ids"]=[];root["outcome"]=o;$0["transaction_outcome"]=root},
            {var rows=$0["receipts_outcome"] as! [[String:Any]];var o=rows[0]["outcome"] as! [String:Any];o["tokens_burnt"]="-1";rows[0]["outcome"]=o;$0["receipts_outcome"]=rows}
        ]
        for edit in edits {
            do {_ = try await c.receipt(changing(valid,edit),signed:s,plan:p);XCTFail("Invalid receipt confirmed")}
            catch { XCTAssertTrue(error is NearSendError || error is NearError) }
        }
    }
}

private struct NearReceiptBlockTransport:AnkrTransport {
    let block:NearJSON
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let call=try JSONDecoder().decode(NearJSON.self,from:request.httpBody!)
        let result:NearJSON
        switch call["method"].string {
        case "EXPERIMENTAL_protocol_config":result = .object(["chain_id":.string("testnet")])
        case "block":guard call["params"]["block_id"].string==block["hash"].string else { throw NearSendError.malformed };result = .object(["header":block])
        default:throw NearSendError.configuration
        }
        return (try JSONEncoder().encode(NearJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"result":result])),200)
    }
}
