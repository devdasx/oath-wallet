import XCTest
@testable import OathAnkr

actor NearSendMock:AnkrTransport {
    var config=try! JSONDecoder().decode(NearJSON.self,from:NearSendTests.fixture("protocol"))
    var permission:NearJSON = .string("FullAccess"),balance="10000000000000000000000000",locked="0",storage:UInt64=182
    var missingRecipient=false,registered=false,decimals:UInt64=24,network="testnet",nonce:UInt64=123456789000000,price="100000000"
    var height:UInt64=101
    var optionalStorage=false,storagePanic=false,disabledPrimary=false
    var response:NearJSON = .null,failPrimary=false,wrongBlock=false,malformed=false
    var calls=[String](),broadcasts=[Data]()
    func configure(_ name:String,_ value:NearJSON) {
        switch name {
        case "disabledPrimary":disabledPrimary=value == .bool(true)
        case "height":height=value.integer!
        case "optionalStorage":optionalStorage=value == .bool(true)
        case "storagePanic":storagePanic=value == .bool(true)
        case "permission":permission=value
        case "balance":balance=value.string!
        case "locked":locked=value.string!
        case "missing":missingRecipient=value == .bool(true)
        case "registered":registered=value == .bool(true)
        case "decimals":decimals=value.integer!
        case "network":network=value.string!
        case "nonce":nonce=value.integer!
        case "price":price=value.string!
        case "response":response=value
        case "fallback":failPrimary=value == .bool(true)
        case "wrongBlock":wrongBlock=value == .bool(true)
        case "malformed":malformed=value == .bool(true)
        default:break
        }
    }
    func send(_ req:URLRequest) async throws -> (Data,Int) {
        let j=try JSONDecoder().decode(NearJSON.self,from:req.httpBody!),m=j["method"].string!,p=j["params"]
        calls.append(m)
        if failPrimary && req.url!.host=="primary.test" { return (Data(),503) }
        if disabledPrimary && req.url!.host=="primary.test" {
            return (try JSONEncoder().encode(NearJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"error":.object(["code":.number("-32075"),"message":.string("Method disabled, reason: restricted by blockchain schema")])])),200)
        }
        let hash=try NearSendTests.plan().blockHash
        var result:NearJSON
        switch m {
        case "status":result = .object(["chain_id":.string(network)])
        case "block":result = .object(["header":.object(["hash":.string(hash),"height":.number(String(height))])])
        case "EXPERIMENTAL_protocol_config":
            guard case .object(var values)=config else { throw NearSendError.malformed };values["chain_id"] = .string(network);result = .object(values)
        case "gas_price":result = .object(["gas_price":.string(price)])
        case "query":
            let id=p["account_id"].string!,method=p["request_type"].string!
            if method=="view_account",missingRecipient,id != NearSendTests.sender {
                return (try JSONEncoder().encode(NearJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"error":.object(["code":.number("-32000"),"cause":.object(["name":.string("UNKNOWN_ACCOUNT"),"info":.object(["requested_account_id":.string(id)])])])])),200)
            }
            var fields:[String:NearJSON]=["block_hash":.string(wrongBlock ? "wrong":hash),"block_height":.number("101")]
            if method=="view_account" { fields.merge(["amount":.string(balance),"locked":.string(locked),"storage_usage":.number(String(storage))]) { _,new in new } }
            else if method=="view_access_key" { fields["nonce"] = .number(String(nonce));fields["permission"]=permission }
            else {
                let value:NearJSON
                switch p["method_name"].string! {
                case "ft_metadata":value = .object(["spec":.string("ft-1.0.0"),"name":.string("Wrapped NEAR"),"symbol":.string("wNEAR"),"decimals":.number(String(decimals))])
                case "ft_balance_of":value = .string("1000000000000000000000000")
                case "storage_balance_of":value = registered ? .object(["total":.string("1250000000000000000000"),"available":.string("0")]):.null
                case "storage_balance_bounds":value = .object(["min":.string("1250000000000000000000"),"max":.string("1250000000000000000000")])
                default:throw NearSendError.malformed
                }
                fields["result"] = .array(try JSONEncoder().encode(value).map { .number(String($0)) })
            }
            if method=="call_function",p["method_name"].string=="storage_balance_of",optionalStorage || storagePanic {
                fields.removeValue(forKey:"result")
                fields["error"] = .string(storagePanic ? "wasm execution failed with error: HostError(GuestPanic)":"wasm execution failed with error: MethodResolveError(MethodNotFound)")
            }
            result = .object(fields)
        case "broadcast_tx_async":broadcasts.append(Data(base64Encoded:p.array![0].string!)!); result=response
        case "tx":result=response
        default:throw NearSendError.malformed
        }
        return (try JSONEncoder().encode(NearJSON.object(["jsonrpc":.string("2.0"),"id":.number(malformed ? "2":"1"),"result":result])),200)
    }
}
final class NearSendBoundaryTests:XCTestCase,@unchecked Sendable {
    private func client(_ m:NearSendMock) throws -> NearSendClient { try NearSendClient(network:.testnet,endpoints:[URL(string:"https://primary.test")!,URL(string:"https://fallback.test")!],transport:m) }
    private func quote(_ c:NearSendClient,token:Bool=false,recipient:String=NearSendTests.recipient,maximum:Bool=false,amount:String="100000000000000000000000") async throws -> NearSendPlan {
        try await c.quote(sender:NearSendTests.sender,recipient:recipient,reference:token ? "wrap.testnet":"native",publicKey:NearSendCrypto.publicKey(privateKey:NearSendTests.seed),decimals:24,amount:amount,maximum:maximum)
    }
    func testFreshBroadcastReturnsExactHashWithoutWaitingForFinality() async throws {
        let m=NearSendMock(),c=try client(m),p=try await quote(c),s=try NearSendCrypto.sign(p,privateKey:NearSendTests.seed)
        await m.configure("response",.string(s.hash));let before=await m.calls.count
        let accepted=try await c.submit(s,plan:p,reconcileFirst:false);XCTAssertEqual(accepted.outcome,.accepted);XCTAssertNil(accepted.fee)
        let calls=await m.calls;XCTAssertEqual(Array(calls.dropFirst(before)),["broadcast_tx_async"])
        await m.configure("response",.string("wrong"))
        do { _=try await c.submit(s,plan:p,reconcileFirst:false);XCTFail("Wrong hash accepted") } catch { XCTAssertEqual(error as? NearSendError,.changed) }
        await m.configure("response",.null)
        let unknown=try await c.submit(s,plan:p,reconcileFirst:false);XCTAssertEqual(unknown.outcome,.unknown)
    }
    func testSixDecimalTokenKeepsExactAtomicAmount() async throws {
        let m=NearSendMock(),c=try client(m);await m.configure("decimals",.number("6"))
        let p=try await c.quote(sender:NearSendTests.sender,recipient:NearSendTests.recipient,reference:"usdt.testnet",
            publicKey:NearSendCrypto.publicKey(privateKey:NearSendTests.seed),decimals:6,amount:"1234567")
        XCTAssertEqual(p.amount,"1234567");XCTAssertEqual(p.decimals,6)
        let args=try JSONDecoder().decode(NearJSON.self,from:NearSendCrypto.transferArgs(p))
        XCTAssertEqual(args["amount"].string,"1234567")
        XCTAssertNoThrow(try NearSendCrypto.sign(p,privateKey:NearSendTests.seed))
    }
    func testModernProtocolPurchaseFloorAndAccountCreationCharge() async throws {
        let m=NearSendMock(),c=try client(m),existing=try await quote(c)
        XCTAssertEqual(existing.gasPriceCeiling,"2000000000")
        let to=String(repeating:"a",count:64),implicit=try await quote(c,recipient:to)
        await m.configure("missing",.bool(true))
        let fresh=try await quote(c,recipient:to)
        XCTAssertEqual(try NearSendAmount.subtract(fresh.fee,implicit.fee),"7000000000000000000000")
        XCTAssertFalse(XrplSendAmount.less(fresh.fee,"7114989537500000000000"))
    }
    func testOptionalStorageInterfaceButNeverSuppressContractPanic() async throws {
        let m=NearSendMock(),c=try client(m);await m.configure("optionalStorage",.bool(true))
        let p=try await quote(c,token:true);XCTAssertEqual(p.storageDeposit,"0");XCTAssertEqual(p.storageGas,0)
        await m.configure("storagePanic",.bool(true))
        do { _ = try await quote(c,token:true);XCTFail() } catch { XCTAssertEqual(error as? NearSendError,.execution) }
    }
    func testRestartReplaysOldAuthorizedBytesOnlyWhileProtocolValid() async throws {
        let m=NearSendMock(),c=try client(m),fresh=try await quote(c)
        var fields=try JSONSerialization.jsonObject(with:JSONEncoder().encode(fresh)) as! [String:Any]
        fields["createdAt"] = Date.now.addingTimeInterval(-3600).timeIntervalSinceReferenceDate
        let old=try JSONDecoder().decode(NearSendPlan.self,from:JSONSerialization.data(withJSONObject:fields))
        let signed=try NearSendCrypto.sign(old,privateKey:NearSendTests.seed,now:old.createdAt)
        _ = try await c.submit(signed,plan:old)
        let broadcasts=await m.broadcasts
        XCTAssertEqual(broadcasts,[signed.bytes])
        await m.configure("height",.number(String(old.blockHeight+old.validityPeriod+1)))
        let expired=try await c.submit(signed,plan:old)
        XCTAssertEqual(expired.outcome,.expired)
        let after=await m.broadcasts
        XCTAssertEqual(after,[signed.bytes],"Expired authorization must never produce another broadcast")
    }
    func testExpiredTransactionRequiresProofOfUnusedNonce() async throws {
        let m=NearSendMock(),c=try client(m),p=try await quote(c),s=try NearSendCrypto.sign(p,privateKey:NearSendTests.seed)
        await m.configure("height",.number(String(p.blockHeight+p.validityPeriod+1)))
        let expired=try await c.status(s,plan:p);XCTAssertEqual(expired.outcome,.expired)
        await m.configure("nonce",.number(String(p.nonce)))
        let ambiguous=try await c.status(s,plan:p);XCTAssertEqual(ambiguous.outcome,.unknown)
    }
    func testSpendableBalanceReservesStorageAndExcludesStakedNEAR() async throws {
        let m=NearSendMock(),c=try client(m),p=try await quote(c,maximum:true)
        XCTAssertEqual(p.reserve,"1820000000000000000000")
        XCTAssertEqual(try NearSendAmount.add(p.amount,p.fee),try NearSendAmount.subtract(p.nativeBalance,p.reserve))
        await m.configure("locked",.string("2000000000000000000000"))
        let withStake=try await quote(c,maximum:true);XCTAssertEqual(withStake.reserve,"0");XCTAssertEqual(withStake.nativeBalance,p.nativeBalance)
        do { _ = try await quote(c,amount:"10000000000000000000000001");XCTFail() } catch { XCTAssertEqual(error as? NearSendError,.insufficientFunds) }
    }
    func testTokenRegistrationCostsNEARAndMaxKeepsTokenUnits() async throws {
        let m=NearSendMock(),c=try client(m),p=try await quote(c,token:true,maximum:true)
        XCTAssertEqual(p.accountCost?.atomic,"1250000000000000000000");XCTAssertEqual(p.accountCost?.inclusion,.additional)
        XCTAssertEqual(p.storageDeposit,"1250000000000000000000");XCTAssertEqual(p.amount,p.assetBalance);XCTAssertEqual(p.remaining,"0")
        XCTAssertEqual(p.nativeDebit,try NearSendAmount.add(try NearSendAmount.add(p.storageDeposit,"1"),p.fee))
        await m.configure("registered",.bool(true));let registered=try await quote(c,token:true)
        XCTAssertNil(registered.accountCost)
        XCTAssertEqual(registered.storageDeposit,"0");XCTAssertEqual(registered.storageGas,0);XCTAssertTrue(XrplSendAmount.less(registered.fee,p.fee))
        await m.configure("balance",.string("1000000000000000000000"))
        do { _ = try await quote(c,token:true);XCTFail() } catch { XCTAssertEqual(error as? NearSendError,.insufficientFunds) }
        await m.configure("registered",.bool(false))
        do { _ = try await quote(c,token:true);XCTFail() } catch { XCTAssertEqual(error as? NearSendError,.storageFunds);XCTAssertEqual(SendAccountGuidance.failure(error,native:false)?.topic,.nearStorage) }
    }
    func testMissingNamedRecipientRejectedButImplicitNativeActivationAllowed() async throws {
        let m=NearSendMock(),c=try client(m);await m.configure("missing",.bool(true))
        do { _ = try await quote(c);XCTFail() } catch { XCTAssertEqual(error as? NearSendError,.recipientMissing) }
        let to=String(repeating:"a",count:64);let p=try await quote(c,recipient:to);XCTAssertEqual(p.recipient,to)
        do { _ = try await quote(c,token:true,recipient:to);XCTFail() } catch { XCTAssertEqual(error as? NearSendError,.recipientMissing) }
    }
    func testRestrictedKeysMetadataMismatchAndWrongNetworkRejected() async throws {
        let m=NearSendMock(),c=try client(m);await m.configure("permission",.object(["FunctionCall":.object([:])]))
        do { _ = try await quote(c);XCTFail() } catch { XCTAssertEqual(error as? NearSendError,.unsupportedAccount) }
        await m.configure("permission",.string("FullAccess"));await m.configure("decimals",.number("6"))
        do { _ = try await quote(c,token:true);XCTFail() } catch { XCTAssertEqual(error as? NearSendError,.metadataChanged) }
        let other=NearSendMock();await other.configure("network",.string("mainnet"))
        do { _ = try await quote(client(other));XCTFail() } catch { XCTAssertEqual(error as? NearSendError,.wrongNetwork) }
    }
    func testChangedNonceGasAndMismatchedSnapshotCannotSend() async throws {
        let m=NearSendMock(),c=try client(m),p=try await quote(c)
        await m.configure("nonce",.number(String(p.nonce)))
        do { try await c.preflight(p);XCTFail() } catch { XCTAssertEqual(error as? NearSendError,.changed) }
        await m.configure("nonce",.number("123456789000000"));await m.configure("price",.string("9999999999"))
        do { try await c.preflight(p);XCTFail() } catch { XCTAssertEqual(error as? NearSendError,.changed) }
        await m.configure("wrongBlock",.bool(true))
        do { _ = try await quote(c);XCTFail() } catch { XCTAssertEqual(error as? NearSendError,.malformed) }
        let sends=await m.broadcasts;XCTAssertTrue(sends.isEmpty)
    }
    func testDisabledProviderMethodFallsBackAndNeverRequiresStatus() async throws {
        let m=NearSendMock(),c=try client(m);await m.configure("disabledPrimary",.bool(true))
        let p=try await quote(c);XCTAssertEqual(p.network,.testnet)
        let calls=await m.calls;XCTAssertFalse(calls.contains("status"))
    }
    func testProviderFallbackAndMalformedEnvelope() async throws {
        let m=NearSendMock(),c=try client(m);await m.configure("fallback",.bool(true))
        let p=try await quote(c);XCTAssertEqual(p.network,.testnet)
        await m.configure("malformed",.bool(true))
        do { _ = try await quote(c);XCTFail() } catch { XCTAssertEqual(error as? NearSendError,.malformed) }
    }
    func testUnknownRetriesIdenticalBytesIncludingOldAuthorizedPlan() async throws {
        let m=NearSendMock(),c=try client(m),p=try await quote(c),s=try NearSendCrypto.sign(p,privateKey:NearSendTests.seed)
        let a=try await c.submit(s,plan:p,reconcileFirst:false),b=try await c.submit(s,plan:p,reconcileFirst:false);XCTAssertEqual(a.outcome,.unknown);XCTAssertEqual(b.outcome,.unknown)
        let sent=await m.broadcasts;XCTAssertEqual(sent,[s.bytes,s.bytes])
        let old=try NearSendTests.changing(p,["createdAt":0]);let oldReceipt=try await c.submit(s,plan:old);XCTAssertEqual(oldReceipt.outcome,.unknown)
        let after=await m.broadcasts;XCTAssertEqual(after,[s.bytes,s.bytes,s.bytes])
    }
}
