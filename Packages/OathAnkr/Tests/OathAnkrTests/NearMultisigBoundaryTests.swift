import XCTest
@testable import OathAnkr

private actor NearMultisigMock: AnkrTransport {
    let plan:NearSendPlan
    let fault:String
    var broadcasts=0
    init(_ plan:NearSendPlan,fault:String="") { self.plan=plan;self.fault=fault }
    func send(_ req:URLRequest) async throws -> (Data,Int) {
        let j=try JSONDecoder().decode(NearJSON.self,from:req.httpBody!),p=j["params"],policy=plan.multisig!.policy
        let value:NearJSON
        switch j["method"].string {
        case "EXPERIMENTAL_protocol_config":value = .object(["chain_id":.string(fault=="network" ? "mainnet":"testnet")])
        case "block":value = .object(["header":.object(["hash":.string(plan.blockHash),"height":.number("1")])])
        case "tx":
            XCTAssertEqual(p["wait_until"].string,"NONE","Status checks must not wait for an unbroadcast transaction")
            return (try JSONEncoder().encode(NearJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"error":.object(["cause":.object(["name":.string("UNKNOWN_TRANSACTION")])])])),200)
        case "broadcast_tx_async":broadcasts+=1;throw NearSendError.execution
        case "query":
            var fields:[String:NearJSON]=["block_hash":.string(plan.blockHash)]
            switch p["request_type"].string {
            case "view_account":fields["code_hash"] = .string(fault=="code" ? "wrong":try NearMultisigPolicy.codeHash);fields["amount"] = .string(plan.nativeBalance)
            case "view_access_key_list":
                var keys=policy.publicKeys.map { pub -> NearJSON in
                    .object(["public_key":.string(NearSendCrypto.keyString(pub)),"access_key":.object(["nonce":.number("99"),"permission":.object(["FunctionCall":.object(["allowance":fault=="allowance" ? .string("1"):.null,"receiver_id":.string(fault=="receiver" ? "other.testnet":plan.sender),"method_names":.array((fault=="methods" ? ["anything"]:NearMultisigPolicy.methods).map { .string($0) })])])])])
                }
                if fault=="fullAccess" { keys[0] = .object(["public_key":.string(NearSendCrypto.keyString(policy.publicKeys[0])),"access_key":.object(["nonce":.number("99"),"permission":.string("FullAccess")])]) }
                if fault=="extra" { keys.append(.object(["public_key":.string("unknown")])) }
                fields["keys"] = .array(keys)
            case "call_function":
                let response:NearJSON
                switch p["method_name"].string {
                case "get_members":response = .array((fault=="members" ? Array(policy.publicKeys.dropFirst()):policy.publicKeys).map { .object(["public_key":.string(NearSendCrypto.keyString($0))]) })
                case "get_num_confirmations":response = .number(String(fault=="threshold" ? 1:policy.required))
                case "get_request":response = .object(["receiver_id":.string("attacker.testnet"),"actions":.array([])])
                default:throw NearSendError.malformed
                }
                fields["result"] = .array(try JSONEncoder().encode(response).map { .number(String($0)) })
            default:throw NearSendError.malformed
            }
            value = .object(fields)
        default:throw NearSendError.malformed
        }
        return (try JSONEncoder().encode(NearJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"result":value])),200)
    }
}
private extension NearSendClient {
    func cacheFixture(hash:String,receipt:NearSendReceipt,id:UInt32) { multisigFinalParts[hash] = .init(receipt:receipt,returnedID:id) }
}
final class NearMultisigBoundaryTests:XCTestCase,@unchecked Sendable {
    func testExactContractAndAllKeyPermissionsAreRequired() async throws {
        let (p,_)=try NearMultisigTests().fixture()
        for fault in ["code","allowance","receiver","methods","fullAccess","extra","members","threshold","network"] {
            let client=try NearSendClient(network:.testnet,endpoints:[URL(string:"https://mock.test")!],transport:NearMultisigMock(p,fault:fault))
            do { _=try await client.multisigState(p.multisig!.policy,block:p.blockHash);XCTFail("Accepted invalid policy: \(fault)") }
            catch { XCTAssertTrue(error as? NearSendError == .changed || error as? NearSendError == .wrongNetwork) }
        }
        let client=try NearSendClient(network:.testnet,endpoints:[URL(string:"https://mock.test")!],transport:NearMultisigMock(p))
        let (state,nonces)=try await client.multisigState(p.multisig!.policy,block:p.blockHash)
        XCTAssertTrue(state.configured);XCTAssertEqual(nonces,[100,100,100])
    }
    func testRequestPayloadBindingPreventsSigningDifferentPayment() async throws {
        let (p,keys)=try NearMultisigTests().fixture(),s=try NearSendCrypto.sign(p,privateKeys:keys)
        let mock=NearMultisigMock(p),client=try NearSendClient(network:.testnet,endpoints:[URL(string:"https://mock.test")!],transport:mock)
        let first=s.multisigParts![0]
        await client.cacheFixture(hash:first.hash,receipt:.init(hash:first.hash,outcome:.confirmed,fee:"1",block:1),id:5)
        do { _=try await client.submit(s,plan:p);XCTFail("Confirmed a different proposal") }
        catch { XCTAssertEqual(error as? NearSendError,.changed) }
        let count=await mock.broadcasts;XCTAssertEqual(count,0)
    }
    func testConflictingProposalIDTerminatesWithoutAnyConfirmation() async throws {
        let (p,keys)=try NearMultisigTests().fixture(),s=try NearSendCrypto.sign(p,privateKeys:keys)
        let mock=NearMultisigMock(p),client=try NearSendClient(network:.testnet,endpoints:[URL(string:"https://mock.test")!],transport:mock)
        let first=s.multisigParts![0]
        await client.cacheFixture(hash:first.hash,receipt:.init(hash:first.hash,outcome:.confirmed,fee:"1",block:1),id:6)
        let r=try await client.submit(s,plan:p);XCTAssertEqual(r.outcome,.failed);XCTAssertEqual(r.fee,"1")
        let count=await mock.broadcasts;XCTAssertEqual(count,0)
    }
    func testNodeNoneStatusIsPendingWithoutTransactionObject() async throws {
        let (p,keys)=try NearMultisigTests().fixture(),s=try NearSendCrypto.sign(p,privateKeys:keys)
        let client=try NearSendClient(network:.testnet)
        for status in ["NONE","INCLUDED","INCLUDED_FINAL","EXECUTED_OPTIMISTIC","EXECUTED"] {
            let r=try await client.receipt(.object(["final_execution_status":.string(status)]),signed:s.multisigParts![0].signed,plan:p)
            XCTAssertEqual(r.outcome,.unknown)
        }
    }
}
