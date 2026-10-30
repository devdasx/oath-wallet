import XCTest
import CryptoKit
@testable import OathAnkr

final class WalletConnectTonTests: XCTestCase {
    let key = Data(repeating:1,count:32)
    struct Vectors: Decodable {
        struct Transfer: Decodable { let deploy:Bool,count:Int,bodyHash:String,hash:String,signingHash:String,signature:String,params:TonJSON }
        struct SignedData: Decodable { let payload:TonJSON,digest:String,signature:String }
        struct Proof: Decodable { let payload:String,digest:String,signature:String }
        let sender:String,domain:String,timestamp:UInt64,publicKey:String,stateInit:String
        let vectors:[Transfer],dataVectors:[SignedData],proof:Proof
    }
    func vectors() throws -> Vectors {
        let path=try XCTUnwrap(Bundle.module.url(forResource:"vectors",withExtension:"json",subdirectory:"Fixtures/WalletConnectTon"))
        return try JSONDecoder().decode(Vectors.self,from:Data(contentsOf:path))
    }
    func testTONReferenceSigningForDeployedAndNewWalletsAndFourMessages() throws {
        let v=try vectors(),now=Date(timeIntervalSince1970:Double(v.timestamp))
        XCTAssertEqual(try TonSendCrypto.address(publicKey:TonSendCrypto.publicKey(privateKey:key)),v.sender)
        XCTAssertEqual(try TonCell.parse(TonIdentity.base64(WalletConnectTonCrypto.stateInit(publicKey:TonSendCrypto.publicKey(privateKey:key)))!).hash,
                       try TonCell.parse(TonIdentity.base64(v.stateInit)!).hash)
        for vector in v.vectors {
            let r=try WalletConnectTonRequest(method:"ton_sendMessage",chain:"ton:-3",account:v.sender,domain:v.domain,params:JSONEncoder().encode(vector.params),now:now)
            let p=WalletConnectTonPlan(request:r,publicKey:try TonSendCrypto.publicKey(privateKey:key),sequence:vector.deploy ? 0:7,expiration:UInt32(v.timestamp)+300,deploy:vector.deploy,fee:1_000_000,feeReserve:2_000_000,createdAt:now)
            let signed=try WalletConnectTonCrypto.sign(p,privateKey:key,now:now)
            XCTAssertEqual(TronSendCrypto.hex(try WalletConnectTonCrypto.signingCell(p).hash),vector.signingHash)
            let referenceSignature = try XCTUnwrap(Data(base64Encoded:vector.signature))
            let referenceBody = try WalletConnectTonCrypto.body(p,signature:referenceSignature)
            let reference = TonSignedSend(bytes:try WalletConnectTonCrypto.external(p,body:referenceBody).boc(), signature:referenceSignature,hash:vector.hash,bodyHash:vector.bodyHash)
            try WalletConnectTonCrypto.verify(reference,plan:p)
            try WalletConnectTonCrypto.verify(signed,plan:p)
            XCTAssertThrowsError(try WalletConnectTonCrypto.sign(p,privateKey:Data(repeating:2,count:32),now:now))
        }
    }
    func testTextBinaryCellAndConnectionProofReferenceSignatures() throws {
        let v=try vectors()
        for vector in v.dataVectors {
            let r=try WalletConnectTonRequest(method:"ton_signData",chain:"ton:-3",account:v.sender,domain:v.domain,params:JSONEncoder().encode(vector.payload))
            let result=try WalletConnectTonCrypto.signData(r,privateKey:key,timestamp:v.timestamp)
            let digest = try WalletConnectTonCrypto.signDataDigest(r,timestamp:v.timestamp)
            XCTAssertEqual(TronSendCrypto.hex(digest),vector.digest)
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation:TonSendCrypto.publicKey(privateKey:key))
            XCTAssertTrue(publicKey.isValidSignature(try XCTUnwrap(Data(base64Encoded:vector.signature)),for:digest))
            XCTAssertTrue(publicKey.isValidSignature(try XCTUnwrap(Data(base64Encoded:result["signature"].string!)),for:digest))
            XCTAssertEqual(result["payload"],vector.payload);XCTAssertEqual(result["address"].string,v.sender)
        }
        let p=try WalletConnectTonProofRequest(chain:"ton:-3",account:v.sender,domain:v.domain,payload:v.proof.payload)
        let digest = try WalletConnectTonCrypto.proofDigest(p,timestamp:v.timestamp)
        XCTAssertEqual(TronSendCrypto.hex(digest),v.proof.digest)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation:TonSendCrypto.publicKey(privateKey:key))
        XCTAssertTrue(publicKey.isValidSignature(try XCTUnwrap(Data(base64Encoded:v.proof.signature)),for:digest))
        XCTAssertTrue(publicKey.isValidSignature(try WalletConnectTonCrypto.signProof(p,privateKey:key,timestamp:v.timestamp),for:digest))
    }
    func testUntrustedRequestsCannotChangeOwnerNetworkOrAmount() throws {
        let v=try vectors(),now=Date(timeIntervalSince1970:Double(v.timestamp)),base=v.vectors[0].params
        func parse(_ json:TonJSON,chain:String="ton:-3") throws -> WalletConnectTonRequest {
            try .init(method:"ton_sendMessage",chain:chain,account:v.sender,domain:v.domain,params:JSONEncoder().encode(json),now:now)
        }
        guard case .object(var d)=base else { return XCTFail() }
        d["network"] = .string("-239");XCTAssertThrowsError(try parse(.object(d)));d.removeValue(forKey:"network")
        d["from"] = .string("0:"+String(repeating:"1",count:64));XCTAssertThrowsError(try parse(.object(d)));d.removeValue(forKey:"from")
        d["valid_until"] = .number(String(v.timestamp));XCTAssertThrowsError(try parse(.object(d)))
        XCTAssertThrowsError(try parse(base,chain:"ton:1"));XCTAssertThrowsError(try parse(base,chain:"ton:-239"))
        for amount in ["-1","1.2","1e9","18446744073709551616"] {
            let msg=TonJSON.object(["address":.string(v.sender),"amount":.string(amount)])
            XCTAssertThrowsError(try parse(.object(["valid_until":.number(String(v.timestamp+300)),"messages":.array([msg])])))
        }
        let msg=TonJSON.object(["address":.string(v.sender),"amount":.string("1")])
        for count in [0,5] { XCTAssertThrowsError(try parse(.object(["valid_until":.number(String(v.timestamp+300)),"messages":.array(Array(repeating:msg,count:count))]))) }
        let friendly=try TonSendNetwork.testnet.walletConnectAddress(v.sender)
        XCTAssertEqual(try TonSendNetwork.testnet.address(friendly),v.sender)
        XCTAssertThrowsError(try TonSendNetwork.mainnet.address(friendly))
    }

    func testMissingExpiryIsBoundedAndOpaquePayloadsRemainExact() throws {
        let v = try vectors(), now = Date(timeIntervalSince1970: Double(v.timestamp))
        let payload = try TonCell([1, 0, 1], []).boc().base64EncodedString()
        let params: TonJSON = .object(["messages": .array([
            .object(["address": .string(v.sender), "amount": .string("0"), "payload": .string(payload)])
        ])])
        let request = try WalletConnectTonRequest(method: "ton_sendMessage", chain: "ton:-3", account: v.sender,
                                                domain: v.domain, params: JSONEncoder().encode(params), now: now)
        XCTAssertNil(request.expiration)
        XCTAssertEqual(request.messages[0].payload, Data(base64Encoded: payload))
        let plan = WalletConnectTonPlan(request: request, publicKey: try TonSendCrypto.publicKey(privateKey: key),
            sequence: 7, expiration: UInt32(v.timestamp) + 300, deploy: false, fee: 1, feeReserve: 2, createdAt: now)
        try plan.validate(now: now)
        XCTAssertThrowsError(try plan.validate(now: now.addingTimeInterval(301)))
    }

    func testLiveBatchReceiptRequiresEveryChildAndRejectsTampering() throws {
        struct Fixture: Decodable { let plan: WalletConnectTonPlan, signed: TonSignedSend, trace: TonJSON }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "batch-receipt", withExtension: "json", subdirectory: "Fixtures/WalletConnectTon"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        try WalletConnectTonCrypto.verify(fixture.signed, plan: fixture.plan)
        func proof(_ trace: TonJSON) throws -> WalletConnectTonProof {
            try .decode(trace, plan: fixture.plan, bytes: fixture.signed.bytes, emulated: false)
        }
        func replacing(_ value: TonJSON, _ key: String, _ replacement: TonJSON) -> TonJSON {
            guard case .object(var fields) = value else { return value }
            fields[key] = replacement; return .object(fields)
        }
        let complete = try proof(fixture.trace)
        XCTAssertTrue(complete.complete); XCTAssertTrue(complete.success); XCTAssertGreaterThan(complete.fee, 0)
        XCTAssertGreaterThan(complete.walletFee, 0)
        XCTAssertLessThan(complete.walletFee, complete.fee)
        let children = try XCTUnwrap(fixture.trace["children"].array)
        XCTAssertEqual(children.count, 4)
        let partial = try proof(replacing(fixture.trace, "children", .array(Array(children.dropLast()))))
        XCTAssertFalse(partial.complete)
        XCTAssertThrowsError(try proof(replacing(fixture.trace, "children", .array(children + [children[0]]))))
        XCTAssertThrowsError(try proof(replacing(fixture.trace, "emulated", .bool(true))))
        let changedRoot = replacing(fixture.trace["transaction"], "hash", .string(String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try proof(replacing(fixture.trace, "transaction", changedRoot)))
        var failed = children
        let rejected = replacing(replacing(children[0]["transaction"], "success", .bool(false)), "credit_phase", .null)
        failed[0] = replacing(children[0], "transaction", rejected)
        let failure = try proof(replacing(fixture.trace, "children", .array(failed)))
        XCTAssertTrue(failure.complete); XCTAssertFalse(failure.success)
        var expensive = children
        expensive[0] = replacing(children[0], "transaction", replacing(children[0]["transaction"], "total_fees", .number("300000000")))
        let contractFees = try proof(replacing(fixture.trace, "children", .array(expensive)))
        XCTAssertGreaterThan(contractFees.fee, 300_000_000)
        XCTAssertEqual(contractFees.walletFee, complete.walletFee)
    }
}
