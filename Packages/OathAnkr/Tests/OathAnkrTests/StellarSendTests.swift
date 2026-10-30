import XCTest
import CryptoKit
@testable import OathAnkr

final class StellarSendTests: XCTestCase {
    func testHighSimulationFeeIsNotMisreportedAsMalformedData() throws {
        XCTAssertEqual(try StellarSendClient.minimumResourceFee(.object(["minResourceFee": .string("6319")])), 6319)
        for fee in ["10000001", "14286346", "18446744073709551615"] {
            XCTAssertThrowsError(try StellarSendClient.minimumResourceFee(.object(["minResourceFee": .string(fee)]))) {
                XCTAssertEqual($0 as? StellarSendError, .feeTooHigh)
            }
        }
        XCTAssertEqual(try StellarSendClient.minimumResourceFee(.object(["minResourceFee": .number("10000000")])), 10000000)
        for value: StellarJSON in [.null, .string("-1"), .string("invalid"), .string("18446744073709551616")] {
            XCTAssertThrowsError(try StellarSendClient.minimumResourceFee(.object(["minResourceFee": value]))) {
                XCTAssertEqual($0 as? StellarSendError, .malformed)
            }
        }
    }
    func vector() throws -> StellarJSON {
        let url=Bundle.module.url(forResource:"sdk-vector",withExtension:"json",subdirectory:"Fixtures/StellarSend")!
        return try JSONDecoder().decode(StellarJSON.self,from:Data(contentsOf:url))
    }
    func testOfficialSDKSigningVectors() throws {
        let v=try vector(),seed=try XCTUnwrap(Data(base64Encoded:v["testOnlySeed"].string!)),now=Date(timeIntervalSince1970:1700000000)
        XCTAssertEqual(try StellarSendCrypto.address(privateKey:seed),v["sender"].string)
        for row in v["vectors"].array! {
            let kind=row["kind"].string!,contract=kind == "contract",classic=kind == "classic"
            let plan=StellarSendPlan(network:.testnet,kind:contract ? .contract:kind == "createAccount" ? .createAccount:.payment,
                sender:v["sender"].string!,recipient:v["recipient"].string!,reference:contract ? v["contract"].string!:classic ? v["classicReference"].string!:"native",
                assetCode:classic ? "OATHLONG":nil,issuer:classic ? v["issuer"].string!:nil,decimals:contract ? 6:7,
                memo:contract ? .init():.init(type:.id,value:"18446744073709551615"),requestedAmount:contract ? "12345":"12500000",amount:contract ? "12345":"12500000",
                assetBalance:"1000000000",nativeBalance:1000000000,reserve:10000000,fee:contract ? 1120:120,sequence:42,firstLedger:1000,lastLedger:1025,maxTime:1700000120,
                sorobanData:contract ? Data(base64Encoded:v["resources"].string!):nil,authorization:contract ? [Data(base64Encoded:v["auth"].string!)!]:[],createdAt:now)
            let signed=try StellarSendCrypto.sign(plan,privateKey:seed,now:now)
            XCTAssertEqual(signed.hash,row["hash"].string,kind)
            // CryptoKit may randomize Ed25519 nonces; compare the complete unsigned
            // envelope, and independently verify the SDK's signature over our digest.
            let referenceEnvelope = Data(base64Encoded:row["envelope"].string!)!
            XCTAssertEqual(signed.bytes.dropLast(64), referenceEnvelope.dropLast(64), kind)
            let referenceSignature = Data(base64Encoded:row["signature"].string!)!
            let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation:seed).publicKey
            XCTAssertTrue(publicKey.isValidSignature(referenceSignature, for: try StellarSendCrypto.digest(StellarSendXDR.transaction(plan), network:plan.network)), kind)
            try StellarSendCrypto.verify(signed,plan:plan)
        }
    }
    func testOfficialSDKShortAssetCodeAndAllMemoEncodings() throws {
        let v=try vector(),key=Data(base64Encoded:v["testOnlySeed"].string!)!,now=Date(timeIntervalSince1970:1700000000)
        for row in v["memoVectors"].array! {
            let plan=StellarSendPlan(network:.testnet,sender:v["sender"].string!,recipient:v["recipient"].string!,
                reference:try StellarIdentity.contract(code:"OAT",issuer:v["issuer"].string!,network:StellarSendNetwork.testnet.passphrase),assetCode:"OAT",issuer:v["issuer"].string!,
                memo:.init(type:StellarSendMemoType(rawValue:row["type"].string!)!,value:row["value"].string!),requestedAmount:"12500000",amount:"12500000",assetBalance:"1000000000",nativeBalance:1000000000,reserve:10000000,fee:120,sequence:42,firstLedger:1000,lastLedger:1025,maxTime:1700000120,createdAt:now)
            let signed=try StellarSendCrypto.sign(plan,privateKey:key,now:now)
            XCTAssertEqual(signed.hash,row["hash"].string)
            XCTAssertEqual(signed.bytes.dropLast(64),Data(base64Encoded:row["envelope"].string!)!.dropLast(64))
        }
    }
    func testExactI128MemosAndResourceBounds() throws {
        for n in ["0","1","18446744073709551615","170141183460469231731687303715884105727"] {
            let bytes=try StellarSendXDR.scAmount(n)
            XCTAssertEqual(try StellarDecoding.scAmount(.string(bytes.base64EncodedString())),n)
        }
        XCTAssertThrowsError(try StellarSendXDR.scAmount("170141183460469231731687303715884105728"))
        XCTAssertThrowsError(try StellarSendMemo(type:.id,value:"18446744073709551616").validate())
        XCTAssertThrowsError(try StellarSendMemo(value:String(repeating:"💠",count:8)).validate())
        try StellarSendMemo(value:String(repeating:"💠",count:7)).validate()
        let v=try vector(),data=Data(base64Encoded:v["resources"].string!)!
        XCTAssertEqual(try StellarSendXDR.resourceFee(data),1000)
        XCTAssertThrowsError(try StellarSendXDR.resourceFee(data+Data([0,0,0,0])))
    }
    private func liveFixture() throws -> StellarJSON {
        guard let path=ProcessInfo.processInfo.environment["OATH_STELLAR_TESTNET_FIXTURE"] else { throw XCTSkip("Opt-in public Testnet transfers") }
        return try JSONDecoder().decode(StellarJSON.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
    }
    private func account(_ owner:String) async throws -> StellarJSON {
        let (data,response)=try await URLSession.shared.data(from:URL(string:"https://horizon-testnet.stellar.org/accounts/"+owner)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StellarSendError.transport }
        return try JSONDecoder().decode(StellarJSON.self,from:data)
    }
    private func balance(_ account:StellarJSON,code:String? = nil) throws -> String {
        let row=try XCTUnwrap(account["balances"].array?.first{code == nil ? $0["asset_type"].string == "native":$0["asset_code"].string == code})
        return try StellarIdentity.atomic(XCTUnwrap(row["balance"].string))
    }
    private func settle(_ client:StellarSendClient,_ signed:StellarSignedSend,_ plan:StellarSendPlan) async throws -> StellarSendReceipt {
        var result=try await client.submit(signed,plan:plan)
        for _ in 0..<20 where result.outcome == .unknown || result.outcome == .accepted { try await Task.sleep(for:.seconds(1));result=try await client.status(signed,plan:plan) }
        XCTAssertEqual(result.outcome,.confirmed);return result
    }
    func testLiveTestnetNativeAndClassicTokens() async throws {
        let f=try liveFixture(),sender=f["sender"]["address"].string!,recipient=f["recipient"]["address"].string!,key=Data(base64Encoded:f["sender"]["seed"].string!)!
        let client=try StellarSendClient(network:.testnet)
        for (reference,code) in [("native",nil as String?),(f["classicReference"].string!,"OATHLONG")] {
            let before=try await balance(account(recipient),code:code)
            let plan=try await client.quote(sender:sender,recipient:recipient,reference:reference,decimals:7,amount:"1234567",memo:.init(type:.id,value:"0"))
            let signed=try StellarSendCrypto.sign(plan,privateKey:key),receipt=try await settle(client,signed,plan)
            let after=try await balance(account(recipient),code:code)
            XCTAssertEqual(after,StellarIdentity.sum(before,plan.amount));XCTAssertLessThanOrEqual(receipt.fee!,UInt64(plan.fee))
            let retry=try await client.submit(signed,plan:plan);XCTAssertEqual(retry.outcome,.confirmed)
            let final=try await balance(account(recipient),code:code);XCTAssertEqual(final,after)
            print("STELLAR_TESTNET_CONFIRMED kind=\(code == nil ? "XLM":"classic") hash=\(signed.hash) exact_delivery=true retry_idempotent=true fee=\(receipt.fee!)")
        }
    }
    private func contractBalance(_ owner:String,plan:StellarSendPlan) async throws -> String {
        let tx=try StellarSendXDR.transaction(plan,readFunction:"balance",readArgs:[StellarSendXDR.scAddress(owner)])
        var request=URLRequest(url:StellarSendNetwork.testnet.rpc);request.httpMethod="POST";request.timeoutInterval=15
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try JSONEncoder().encode(StellarJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string("simulateTransaction"),"params":.object(["transaction":.string(StellarSendXDR.envelope(tx).base64EncodedString())])]))
        let (data,_)=try await URLSession.shared.data(for:request)
        let r=try JSONDecoder().decode(StellarJSON.self,from:data)["result"]
        guard r["error"].isNull,let raw=r["results"].array?.first?["xdr"] else { throw StellarSendError.simulation }
        return try StellarDecoding.scAmount(raw)
    }
    func testLiveTestnetContractTokenAndMaximum() async throws {
        let f=try liveFixture(),sender=f["sender"]["address"].string!,recipient=f["issuer"]["address"].string!,key=Data(base64Encoded:f["sender"]["seed"].string!)!
        let contract=try XCTUnwrap(f["contract"].string),client=try StellarSendClient(network:.testnet)
        for maximum in [false,true] {
            let plan=try await client.quote(sender:sender,recipient:recipient,reference:contract,decimals:6,amount:"1234567",maximum:maximum)
            XCTAssertEqual(plan.kind,.contract);XCTAssertNotNil(plan.sorobanData)
            let before=try await contractBalance(recipient,plan:plan)
            let signed=try StellarSendCrypto.sign(plan,privateKey:key),receipt=try await settle(client,signed,plan)
            let after=try await contractBalance(recipient,plan:plan)
            XCTAssertEqual(after,StellarIdentity.sum(before,plan.amount));XCTAssertLessThanOrEqual(receipt.fee!,UInt64(plan.fee))
            if maximum { let left=try await contractBalance(sender,plan:plan);XCTAssertEqual(left,"0") }
            let retry=try await client.submit(signed,plan:plan);XCTAssertEqual(retry.outcome,.confirmed)
            print("STELLAR_TESTNET_CONFIRMED kind=contract max=\(maximum) hash=\(signed.hash) exact_delivery=true fee=\(receipt.fee!) maximum_fee=\(plan.fee)")
        }
    }
    func testLiveTestnetActivationMaximumAndRequiredMemo() async throws {
        let f=try liveFixture(),sender=f["sender"]["address"].string!,recipient=f["recipient"]["address"].string!,key=Data(base64Encoded:f["sender"]["seed"].string!)!
        let client=try StellarSendClient(network:.testnet)
        do { _=try await client.quote(sender:sender,recipient:recipient,reference:"native",decimals:7,amount:"1");XCTFail("Required memo ignored") }
        catch { XCTAssertEqual(error as? StellarSendError,.memoRequired) }
        let fresh=Curve25519.Signing.PrivateKey(),destination=try StellarSendCrypto.address(privateKey:fresh.rawRepresentation)
        let plan=try await client.quote(sender:sender,recipient:destination,reference:"native",decimals:7,amount:"30000000")
        XCTAssertEqual(plan.kind,.createAccount)
        let signed=try StellarSendCrypto.sign(plan,privateKey:key),created=try await settle(client,signed,plan)
        XCTAssertEqual(created.outcome,.confirmed)
        let newBalance=try await balance(account(destination));XCTAssertEqual(newBalance,"30000000")
        let maximum=try await client.quote(sender:destination,recipient:recipient,reference:"native",decimals:7,amount:newBalance,memo:.init(type:.id,value:"0"),maximum:true)
        XCTAssertEqual(maximum.remaining,String(maximum.reserve))
        let before=try await balance(account(recipient))
        let maxSigned=try StellarSendCrypto.sign(maximum,privateKey:fresh.rawRepresentation),sent=try await settle(client,maxSigned,maximum)
        let after=try await balance(account(recipient)),remaining=try await balance(account(destination))
        XCTAssertEqual(after,StellarIdentity.sum(before,maximum.amount));XCTAssertGreaterThanOrEqual(UInt64(remaining)!,maximum.reserve)
        XCTAssertEqual(remaining,String(maximum.nativeBalance-UInt64(maximum.amount)!-sent.fee!))
        print("STELLAR_TESTNET_CONFIRMED kind=createAccount hash=\(signed.hash) exact_delivery=true")
        print("STELLAR_TESTNET_CONFIRMED kind=nativeMax hash=\(maxSigned.hash) reserve_preserved=true fee=\(sent.fee!)")
    }

    func testLiveTestnetFailedActivationIsNeverReportedAsSuccess() async throws {
        let f=try liveFixture(),a=f["sender"]["address"].string!,b=f["issuer"]["address"].string!
        let keyA=Data(base64Encoded:f["sender"]["seed"].string!)!,keyB=Data(base64Encoded:f["issuer"]["seed"].string!)!
        let recipient=try StellarSendCrypto.address(privateKey:Curve25519.Signing.PrivateKey().rawRepresentation),client=try StellarSendClient(network:.testnet)
        let first=try await client.quote(sender:a,recipient:recipient,reference:"native",decimals:7,amount:"20000000")
        let second=try await client.quote(sender:b,recipient:recipient,reference:"native",decimals:7,amount:"20000000")
        _=try await settle(client,StellarSendCrypto.sign(second,privateKey:keyB),second)
        let signed=try StellarSendCrypto.sign(first,privateKey:keyA)
        var result=try await client.submit(signed,plan:first)
        for _ in 0..<20 where result.outcome == .unknown || result.outcome == .accepted {try await Task.sleep(for:.seconds(1));result=try await client.status(signed,plan:first)}
        XCTAssertEqual(result.outcome,.failed);XCTAssertNotNil(result.fee)
        let actual=try await balance(account(recipient));XCTAssertEqual(actual,"20000000")
        print("STELLAR_TESTNET_CONFIRMED kind=failedActivation hash=\(signed.hash) outcome=\(result.outcome.rawValue) no_extra_delivery=true fee=\(result.fee ?? 0)")
    }
    func testSignerRejectsMissingOrAlteredContractAuthorizationAndWrongKey() throws {
        let v=try vector(),key=Data(base64Encoded:v["testOnlySeed"].string!)!,now=Date(timeIntervalSince1970:1700000000)
        let plan=StellarSendPlan(network:.testnet,kind:.contract,sender:v["sender"].string!,recipient:v["recipient"].string!,reference:v["contract"].string!,decimals:6,
            requestedAmount:"12345",amount:"12345",assetBalance:"1000000",nativeBalance:100000000,reserve:10000000,fee:1120,sequence:42,firstLedger:1000,lastLedger:1025,maxTime:1700000120,
            sorobanData:Data(base64Encoded:v["resources"].string!),authorization:[Data(base64Encoded:v["auth"].string!)!],createdAt:now)
        let original=try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan)) as! [String:Any]
        for field in ["authorization","sorobanData","amount","recipient","fee"] {
            var changed=original
            switch field {
            case "authorization":changed[field]=[Data(repeating:0,count:4).base64EncodedString()]
            case "sorobanData":changed[field]=NSNull()
            case "amount":changed[field]="12344"
            case "recipient":changed[field]=v["issuer"].string!
            default:changed[field]=1000
            }
            let invalid=try JSONDecoder().decode(StellarSendPlan.self,from:JSONSerialization.data(withJSONObject:changed))
            XCTAssertThrowsError(try StellarSendCrypto.sign(invalid,privateKey:key,now:now),field)
        }
        XCTAssertThrowsError(try StellarSendCrypto.sign(plan,privateKey:Data(repeating:1,count:32),now:now))
        let signed=try StellarSendCrypto.sign(plan,privateKey:key,now:now)
        var bytes=signed.bytes;bytes[20] ^= 1
        XCTAssertThrowsError(try StellarSendCrypto.verify(.init(bytes:bytes,publicKey:signed.publicKey,signature:signed.signature,hash:signed.hash),plan:plan))
    }

}
