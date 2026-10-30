import XCTest
import CryptoKit
@testable import OathAnkr

final class StellarMultisigTests: XCTestCase {
    func vector() throws -> StellarJSON {
        let url = try XCTUnwrap(Bundle.module.url(forResource:"multisig-sdk",withExtension:"json",subdirectory:"Fixtures/StellarSend"))
        return try JSONDecoder().decode(StellarJSON.self,from:Data(contentsOf:url))
    }
    func plan(_ row: StellarJSON, fixture: StellarJSON) throws -> StellarSendPlan {
        let p=row["policy"], kind=row["kind"].string!, configuration=kind == "configureMultisig" || kind == "changeTrust"
        let policy = try StellarMultisigPolicy(account:p["account"].string!,required:Int(p["required"].integer!),signers:p["signers"].array!.map{$0.string!})
        let token=kind == "classic" || kind == "changeTrust"
        return .init(network:.testnet,kind:configuration ? StellarSendPlan.Kind(rawValue:kind)!:.payment,
            sender:policy.account,recipient:configuration ? policy.account:fixture["recipient"].string!,reference:token ? row["reference"].string!:"native",
            assetCode:token ? "OATHLONG":nil,issuer:token ? fixture["issuer"].string!:nil,
            requestedAmount:configuration ? "0":"12500000",amount:configuration ? "0":"12500000",assetBalance:"1000000000",
            nativeBalance:1000000000,reserve:110000000,fee:UInt32(row["fee"].integer!),sequence:42,firstLedger:1000,lastLedger:1025,maxTime:1700000120,
            createdAt:Date(timeIntervalSince1970:1700000000),multisig:policy)
    }
    func testSDKVectorsForFivePoliciesAndFourOperations() throws {
        let f=try vector(),now=Date(timeIntervalSince1970:1700000000)
        for row in f["vectors"].array! {
            let p=try plan(row,fixture:f)
            let signed:StellarSignedSend
            if p.kind == .configureMultisig { signed=try StellarSendCrypto.sign(p,privateKey:Data(repeating:99,count:32),now:now) }
            else { signed=try StellarSendCrypto.sign(p,privateKeys:(1...p.multisig!.required).map{Data(repeating:UInt8($0),count:32)},now:now) }
            XCTAssertEqual(signed.hash,row["hash"].string)
            // Signatures may use randomized nonces; unsigned XDR must match exactly.
            let envelope=Data(base64Encoded:row["envelope"].string!)!,tx=try StellarSendXDR.transaction(p)
            XCTAssertEqual(Data(envelope.dropFirst(4).prefix(tx.count)),tx)
            var offset=4+tx.count+4
            let count=p.kind == .configureMultisig ? 1:p.multisig!.required
            let keys=p.kind == .configureMultisig ? [Data(repeating:99,count:32)]:(1...count).map{Data(repeating:UInt8($0),count:32)}
            let pubs=try keys.map { try Curve25519.Signing.PrivateKey(rawRepresentation:$0).publicKey }.sorted{$0.rawRepresentation.lexicographicallyPrecedes($1.rawRepresentation)}
            for pub in pubs {
                XCTAssertEqual(envelope.subdata(in:offset..<offset+4),pub.rawRepresentation.suffix(4))
                XCTAssertTrue(pub.isValidSignature(envelope.subdata(in:offset+8..<offset+72),for:StellarSendCrypto.digest(tx,network:.testnet)))
                offset += 72
            }
            try StellarSendCrypto.verify(signed,plan:p)
        }
    }
    func testRejectsInsufficientDuplicateForeignAndTamperedSignatures() throws {
        let f=try vector(),row=f["vectors"].array!.first{$0["kind"].string == "native" && $0["policy"]["required"].integer == 2}!,p=try plan(row,fixture:f),now=p.createdAt
        for keys in [[Data(repeating:1,count:32)],[Data(repeating:1,count:32),Data(repeating:1,count:32)],[Data(repeating:1,count:32),Data(repeating:90,count:32)]] {
            XCTAssertThrowsError(try StellarSendCrypto.sign(p,privateKeys:keys,now:now))
        }
        XCTAssertThrowsError(try StellarSendCrypto.sign(p,privateKey:Data(repeating:99,count:32),now:now))
        let signed=try StellarSendCrypto.sign(p,privateKeys:[Data(repeating:1,count:32),Data(repeating:2,count:32)],now:now)
        XCTAssertThrowsError(try StellarSendCrypto.verify(.init(bytes:signed.bytes+Data([0]),publicKey:Data(),signature:Data(),hash:signed.hash,signatures:signed.signatures),plan:p))
        XCTAssertThrowsError(try StellarSendCrypto.sign(p,privateKeys:[Data(repeating:1,count:32),Data(repeating:2,count:32)],now:now.addingTimeInterval(121)))
    }
    func testChangedPolicyAndWrongNetworkNeverBroadcast() async throws {
        let owner=try StellarSendCrypto.address(privateKey:Data(repeating:99,count:32)),recipient=try StellarSendCrypto.address(privateKey:Data(repeating:98,count:32)),issuer=try StellarSendCrypto.address(privateKey:Data(repeating:97,count:32))
        let keys=[Data(repeating:1,count:32),Data(repeating:2,count:32)]
        let policy=try StellarMultisigPolicy(account:owner,required:2,signers:keys.map { try StellarSendCrypto.address(privateKey:$0) })
        let transport=StellarTransportFixture(sender:owner,recipient:recipient,issuer:issuer)
        await transport.multisig(policy)
        let client=try StellarSendClient(network:.testnet,transport:transport)
        let plan=try await client.quote(sender:owner,recipient:recipient,reference:"native",decimals:7,amount:"1",multisig:policy)
        let signed=try StellarSendCrypto.sign(plan,privateKeys:keys)
        await transport.multisig(nil)
        let changed=try await client.submit(signed,plan:plan,reconcileFirst:false)
        XCTAssertEqual(changed.outcome,.unknown)
        let writes=await transport.writes
        XCTAssertTrue(writes.isEmpty)
        let mainnet=try StellarSendClient(network:.mainnet,transport:transport)
        do { _ = try await mainnet.submit(signed,plan:plan);XCTFail("Cross-network submission") }
        catch { XCTAssertEqual(error as? StellarSendError,.wrongNetwork) }
        await transport.multisig(policy)
        await transport.configure(wrongNetwork:true)
        do { _ = try await client.quote(sender:owner,recipient:recipient,reference:"native",decimals:7,amount:"1",multisig:policy);XCTFail("Wrong provider identity") }
        catch { XCTAssertEqual(error as? StellarSendError,.wrongNetwork) }
    }
    func testInvalidPolicies() throws {
        let owner=try StellarSendCrypto.address(privateKey:Data(repeating:99,count:32)),a=try StellarSendCrypto.address(privateKey:Data(repeating:1,count:32)),b=try StellarSendCrypto.address(privateKey:Data(repeating:2,count:32))
        for (required,keys) in [(0,[a,b]),(3,[a,b]),(1,[a]),(2,[a,a]),(1,[owner,b])] { XCTAssertThrowsError(try StellarMultisigPolicy(account:owner,required:required,signers:keys)) }
    }
}
