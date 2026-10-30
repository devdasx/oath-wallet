import XCTest
@testable import OathAnkr

final class XrplMultisigTests: XCTestCase {
    struct Vector: Decodable { let kind: String, bytes: String }
    struct Fixture: Decodable { let accountKey: String, account: String, keys: [String], signers: [String], vectors: [Vector] }
    func fixture() throws -> Fixture {
        let url = Bundle.module.url(forResource:"multisig-sdk-vector",withExtension:"json",subdirectory:"Fixtures/XrplSend")!
        return try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:url))
    }
    func plan(_ f: Fixture, kind: String) throws -> XrplSendPlan {
        let policy = try XrplMultisigPolicy(account:f.account,required:2,signers:f.signers)
        let setup = XrplMultisigSetup(rawValue:kind)
        let reference = ["issued","trust"].contains(kind) ? "OAT.rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh" : ["mpt","authorize"].contains(kind) ? "000000010000000000000000000000000000000000000000" : "native"
        let amount = setup != nil || kind == "authorize" ? "0" : ["issued","trust"].contains(kind) ? try XrplIdentity.issuedAmount("1.25") : kind == "mpt" ? "123" : "123456"
        return .init(network:.testnet,sender:f.account,recipient:setup != nil || ["trust","authorize"].contains(kind) ? f.account:"rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh",reference:reference,destinationTag:setup != nil || ["trust","authorize"].contains(kind) ? nil:0,
            requestedAmount:amount,amount:amount,assetDebit:["trust","authorize"].contains(kind) ? "0":amount,assetBalance:reference == "native" ? "10000000":amount,
            nativeBalance:10_000_000,reserve:1_200_000,fee:36,sequence:42,firstLedger:100,lastLedger:120,multisig:policy,multisigSetup:setup,tokenAuthorization:["trust","authorize"].contains(kind) ? true:nil)
    }
    func testIndependentSDKVectorsAndTampering() throws {
        let f = try fixture(), keys = try f.keys.map(TronIdentity.hex)
        for v in f.vectors {
            let p = try plan(f,kind:v.kind)
            let signed = try p.multisigSetup != nil ? XrplSendCrypto.sign(p,privateKey:TronIdentity.hex(f.accountKey)) : XrplMultisigCrypto.sign(p,privateKeys:Array(keys.prefix(2)))
            XCTAssertEqual(XrplSendCrypto.hex(signed.bytes),v.bytes,v.kind)
            try XrplSendCrypto.verify(signed,plan:p)
            let corrupt = XrplSignedSend(bytes:signed.bytes+Data([0]),publicKey:signed.publicKey,signature:signed.signature,hash:signed.hash,signers:signed.signers)
            XCTAssertThrowsError(try XrplSendCrypto.verify(corrupt,plan:p))
            if p.multisigSetup == nil {
                XCTAssertThrowsError(try XrplSendCrypto.sign(p,privateKey:TronIdentity.hex(f.accountKey)))
                XCTAssertThrowsError(try XrplMultisigCrypto.sign(p,privateKeys:[keys[0]]))
                XCTAssertThrowsError(try XrplMultisigCrypto.sign(p,privateKeys:[keys[0],keys[0]]))
                XCTAssertThrowsError(try XrplMultisigCrypto.sign(p,privateKeys:[keys[0],TronIdentity.hex(f.accountKey)]))
                XCTAssertThrowsError(try XrplMultisigCrypto.sign(p,privateKeys:keys))
                let reordered = try XrplMultisigCrypto.sign(p,privateKeys:Array(keys.prefix(2).reversed()))
                XCTAssertEqual(reordered,signed)
            }
        }
    }
    func testThresholdsAndPolicyValidation() throws {
        let f=try fixture()
        for threshold in 1...3 { XCTAssertNoThrow(try XrplMultisigPolicy(account:f.account,required:threshold,signers:f.signers.reversed())) }
        XCTAssertThrowsError(try XrplMultisigPolicy(account:f.account,required:0,signers:f.signers))
        XCTAssertThrowsError(try XrplMultisigPolicy(account:f.account,required:4,signers:f.signers))
        XCTAssertThrowsError(try XrplMultisigPolicy(account:f.account,required:2,signers:[f.signers[0],f.signers[0]]))
        XCTAssertThrowsError(try XrplMultisigPolicy(account:f.account,required:2,signers:[f.account,f.signers[0]]))
    }
    func testConfigurationHistoryKeepsFeesWithoutSyntheticTransfers() throws {
        let f = try fixture()
        for type in ["SignerListSet","AccountSet","TrustSet","MPTokenAuthorize"] {
            let row:XrplJSON = .object(["validated":.bool(true),"hash":.string(String(repeating:"A",count:64)),"ledger_index":.number("100"),
                "tx_json":.object(["TransactionType":.string(type),"Account":.string(f.account),"Fee":.string("36"),"date":.number("1")]),
                "meta":.object(["TransactionResult":.string("tesSUCCESS"),"AffectedNodes":.array([
                    .object(["ModifiedNode":.object(["LedgerEntryType":.string("AccountRoot"),
                        "FinalFields":.object(["Account":.string(f.account),"Balance":.string("9999964")]),
                        "PreviousFields":.object(["Balance":.string("10000000")])])])])])])
            let transaction = try XrplDecoding.transaction(row,owner:f.account)
            XCTAssertEqual(transaction.fee,"36")
            XCTAssertTrue(transaction.movements.isEmpty,type)
        }
    }
    func testOnChainPolicySetupAndNetworkGuards() async throws {
        let f=try fixture(), policy=try XrplMultisigPolicy(account:f.account,required:2,signers:f.signers)
        let recipient="rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
        let t=XrplRPCFixture(sender:f.account,recipient:recipient), client=try XrplSendClient(network:.testnet,transport:t)
        let initial=try await client.quoteMultisigSetup(policy)
        XCTAssertEqual(initial?.multisigSetup,.signerList)
        let list:XrplJSON = .object(["SignerQuorum":.number("2"),"SignerListID":.number("0"),"SignerEntries":policy.entries])
        await t.multisig(list:list,disabled:false)
        let disable=try await client.quoteMultisigSetup(policy)
        XCTAssertEqual(disable?.multisigSetup,.disableMaster)
        do { _ = try await client.quote(sender:f.account,recipient:recipient,reference:"native",amount:"100",multisig:policy);XCTFail("Master bypass still enabled") }
        catch { XCTAssertEqual(error as? XrplSendError,.unsupportedAccount) }
        await t.multisig(list:list,disabled:true)
        let active=try await client.multisigState(policy)
        XCTAssertTrue(active.configured)
        let payment=try await client.quote(sender:f.account,recipient:recipient,reference:"native",amount:"100",multisig:policy)
        XCTAssertEqual(payment.fee,36)
        let max=try await client.quote(sender:f.account,recipient:recipient,reference:"native",amount:"10000000",maximum:true,multisig:policy)
        XCTAssertEqual(max.amount,String(max.nativeBalance-max.reserve-max.fee))
        let token=try await client.quoteTokenAuthorization(policy,reference:"USD."+recipient,limit:"200000")
        XCTAssertEqual(token.tokenAuthorization,true)
        let signed=try XrplMultisigCrypto.sign(token,privateKeys:Array(f.keys.prefix(2)).map(TronIdentity.hex))
        guard case .object(var tx)=try token.transactionJSON(),case .object(var limit)=tx["LimitAmount"] else { return XCTFail("Token transaction missing") }
        limit["value"] = .string("200000");tx["LimitAmount"] = .object(limit)
        await t.response(.object(["status":.string("success"),"validated":.bool(true),"hash":.string(signed.hash),"ledger_index":.number("101"),"tx_json":.object(tx),"meta":.object(["TransactionResult":.string("tesSUCCESS")])]))
        let tokenReceipt=try await client.status(signed,plan:token)
        XCTAssertEqual(tokenReceipt.outcome,.confirmed)
        await t.multisig(list:list,disabled:true,regular:recipient)
        do { _ = try await client.multisigState(policy);XCTFail("Regular key bypass accepted") }
        catch { XCTAssertEqual(error as? XrplSendError,.unsupportedAccount) }
        await t.multisig(list:.object(["SignerQuorum":.number("1"),"SignerListID":.number("0"),"SignerEntries":policy.entries]),disabled:true)
        do { _ = try await client.multisigState(policy);XCTFail("Changed threshold accepted") }
        catch { XCTAssertEqual(error as? XrplSendError,.unsupportedAccount) }
        await t.configure(network:0)
        do { _ = try await client.multisigState(policy);XCTFail("Mainnet endpoint accepted as testnet") }
        catch { XCTAssertEqual(error as? XrplSendError,.wrongNetwork) }
        let writes=await t.submitted
        XCTAssertTrue(writes.isEmpty)
    }

}
