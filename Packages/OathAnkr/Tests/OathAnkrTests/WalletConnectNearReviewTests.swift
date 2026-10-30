import XCTest
@testable import OathAnkr

private actor NearConnectTransport:AnkrTransport {
    enum Mode:Sendable { case valid,wrongChain,restricted,stale,lowFunds,hugeCost,existingKey,fullAccessDelegate }
    let mode:Mode
    let hash = SuiSendCrypto.base58(Data(repeating:3,count:32))
    init(_ mode:Mode) { self.mode = mode }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let input = try JSONDecoder().decode(NearJSON.self,from:request.httpBody!), params = input["params"]
        let cost:[String:Any] = ["send_not_sir":mode == .hugeCost ? UInt64.max:1,"execution":1]
        var actions = Dictionary(uniqueKeysWithValues:["create_account_cost","deploy_contract_cost","deploy_contract_cost_per_byte","function_call_cost","function_call_cost_per_byte","transfer_cost","stake_cost","delete_key_cost","delete_account_cost"].map{($0,cost as Any)})
        actions["add_key_cost"] = ["full_access_cost":cost,"function_call_cost":cost,"function_call_cost_per_byte":cost]
        let result:[String:Any]
        switch input["method"].string {
        case "EXPERIMENTAL_protocol_config": result = ["chain_id":mode == .wrongChain ? "mainnet":"testnet","transaction_validity_period":100,"runtime_config":["min_gas_purchase_price":"1","storage_amount_per_byte":"10","transaction_costs":["action_receipt_creation_config":cost,"action_creation_config":actions]]]
        case "gas_price": result = ["gas_price":"1"]
        case "block": result = ["header":["hash":hash,"height":params["block_id"].isNull ? 1000:mode == .stale ? 800:1000]]
        case "query":
            switch params["request_type"].string {
            case "view_account": result = ["block_hash":hash,"amount":mode == .lowFunds ? "0":"100000000000000000000000000","locked":"0","storage_usage":100]
            case "view_access_key": result = ["block_hash":hash,"permission":mode == .restricted ? "FunctionCall":"FullAccess","nonce":10]
            case "view_access_key_list":
                let permission:Any = mode == .fullAccessDelegate ? "FullAccess" : ["FunctionCall":["allowance":"1","receiver_id":"wrap.testnet","method_names":["ft_transfer"]]]
                result = ["block_hash":hash,"keys":[Mode.existingKey,.fullAccessDelegate].contains(mode) ? [["public_key":NearSendCrypto.keyString(Data(repeating:9,count:32)),"access_key":["nonce":0,"permission":permission]]] : []]
            default: throw NearSendError.malformed
            }
        default: throw NearSendError.malformed
        }
        return (try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":1,"result":result]),200)
    }
}
final class WalletConnectNearReviewTests:XCTestCase {
    private func client(_ mode:NearConnectTransport.Mode = .valid) throws -> NearSendClient { try .init(network:.testnet,endpoints:[URL(string:"https://near.test.invalid")!],transport:NearConnectTransport(mode)) }
    func access(_ method:String = "near_signIn",owner:String = "sender.testnet",key:Data = Data(repeating:9,count:32)) throws -> WalletConnectNearAccess {
        var fields:[String:NearJSON] = ["accounts":.array([.object(["accountId":.string(owner),"publicKey":.string(NearSendCrypto.keyString(key))])])]
        if method == "near_signIn" { fields["permission"] = .object(["receiverId":.string("wrap.testnet"),"methodNames":.array([.string("ft_transfer")])]) }
        return try .init(method:method,chain:"near:testnet",account:"sender.testnet",params:JSONEncoder().encode(NearJSON.object(fields)))
    }
    func testNetworkOwnershipFreshnessBalanceAndFeeBounds() async throws {
        let fixture = WalletConnectNearTests(), request = try fixture.request(fixture.raw(nonce:11)), key = try NearSendCrypto.publicKey(privateKey:fixture.key)
        let valid = try client(), review = try await valid.walletConnectReview(request,publicKey:key)
        XCTAssertEqual(review.transactions.count,1); try await valid.walletConnectPreflight(review,publicKey:key)
        for mode in [NearConnectTransport.Mode.wrongChain,.restricted,.stale,.lowFunds,.hugeCost] {
            do { _ = try await client(mode).walletConnectReview(request,publicKey:key); XCTFail("Invalid provider state accepted") } catch { XCTAssertTrue(error is NearSendError) }
        }
        for nonce:UInt64 in [10,1_000_000_000,UInt64.max] {
            do { _ = try await client().walletConnectReview(fixture.request(fixture.raw(nonce:nonce)),publicKey:key); XCTFail("Invalid nonce") } catch { XCTAssertEqual(error as? NearSendError,.changed) }
        }
    }
    func testAccessCreationRestrictedAllowanceAndSafeRevocation() async throws {
        let fixture = WalletConnectNearTests(), key = try NearSendCrypto.publicKey(privateKey:fixture.key), input = try access()
        let review = try await client().walletConnectAccessReview(input,publicKey:key,grants:[])
        try input.validate(review)
        XCTAssertFalse(review.transactions[0].actions[0].fullAccess)
        XCTAssertTrue(review.transactions[0].actions[0].description.contains(WalletConnectNearAccess.allowance))
        let response = try review.request.sign(privateKey:fixture.key,review:review)
        let signed = try WalletConnectNearAccess.signed(response,review:review); try WalletConnectNearAccess.verify(signed,review:review)
        XCTAssertThrowsError(try access(owner:"other.testnet"))
        do { _ = try await client().walletConnectAccessReview(access(key:key),publicKey:key,grants:[]); XCTFail("Own key") } catch { XCTAssertEqual(error as? NearSendError,.wrongOwner) }
        do { _ = try await client(.existingKey).walletConnectAccessReview(input,publicKey:key,grants:[]); XCTFail("Existing key") } catch { XCTAssertEqual(error as? NearSendError,.changed) }
        let revoke = try access("near_signOut"), grant = WalletConnectNearGrant(publicKey:Data(repeating:9,count:32),receiver:"wrap.testnet",methodNames:["ft_transfer"])
        do { _ = try await client(.existingKey).walletConnectAccessReview(revoke,publicKey:key,grants:[]); XCTFail("Unowned grant") } catch { XCTAssertEqual(error as? NearSendError,.wrongOwner) }
        do { _ = try await client(.fullAccessDelegate).walletConnectAccessReview(revoke,publicKey:key,grants:[grant]); XCTFail("Full access revoked") } catch { XCTAssertEqual(error as? NearSendError,.wrongOwner) }
        let revocation = try await client(.existingKey).walletConnectAccessReview(revoke,publicKey:key,grants:[grant]); XCTAssertEqual(revocation.transactions[0].actions[0].kind,6)
        XCTAssertThrowsError(try input.validate(revocation))
    }
}

private actor NearAccessSubmissionTransport:AnkrTransport {
    let base = NearConnectTransport(.valid)
    let signed:NearSignedSend
    let failed:Bool
    var submitted = false
    var queries = 0
    var broadcasts = 0
    init(_ signed:NearSignedSend,failed:Bool) { self.signed = signed; self.failed = failed }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let input = try JSONDecoder().decode(NearJSON.self,from:request.httpBody!), params = input["params"]
        let method = input["method"].string
        if method != "tx", method != "send_tx" { return try await base.send(request) }
        if method == "tx" {
            XCTAssertEqual(params["wait_until"].string,"NONE")
            queries += 1
            if !submitted {
                return (try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":1,"error":["code":-32000,"cause":["name":"UNKNOWN_TRANSACTION"]]]),200)
            }
        } else {
            XCTAssertEqual(params["signed_tx_base64"].string,signed.bytes.base64EncodedString())
            XCTAssertEqual(params["wait_until"].string,"INCLUDED")
            broadcasts += 1; submitted = true
        }
        let final = queries >= 3
        let status:[String:Any] = failed ? ["Failure":["ActionError":"test failure"]]:["SuccessValue":""]
        let result:[String:Any] = ["transaction":["hash":signed.hash],"final_execution_status":final ? "FINAL":"EXECUTED_OPTIMISTIC","status":status]
        return (try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":1,"result":result]),200)
    }
}
extension WalletConnectNearReviewTests {
    func testAccessSubmissionChecksImmediatelyAndWaitsForFinality() async throws {
        let fixture = WalletConnectNearTests(), key = try NearSendCrypto.publicKey(privateKey:fixture.key), input = try access()
        let review = try await client().walletConnectAccessReview(input,publicKey:key,grants:[])
        let signed = try WalletConnectNearAccess.signed(review.request.sign(privateKey:fixture.key,review:review),review:review)
        for failed in [false,true] {
            let transport = NearAccessSubmissionTransport(signed,failed:failed)
            let client = try NearSendClient(network:.testnet,endpoints:[URL(string:"https://near.test.invalid")!],transport:transport)
            let first = try await client.walletConnectAccessSubmit(signed,review:review)
            XCTAssertEqual(first,.accepted)
            let optimistic = try await client.walletConnectAccessSubmit(signed,review:review)
            XCTAssertEqual(optimistic,.accepted)
            let final = try await client.walletConnectAccessSubmit(signed,review:review)
            XCTAssertEqual(final,failed ? .failed:.confirmed)
            let count = await transport.broadcasts; XCTAssertEqual(count,1)
        }
    }
}
