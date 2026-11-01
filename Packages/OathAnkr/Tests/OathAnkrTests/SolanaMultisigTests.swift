import XCTest
@testable import OathAnkr

final class SolanaMultisigTests: XCTestCase {
    func testPrivateKeyImportAndIndependentBIP39Vector() throws {
        let seed = Data(repeating:42,count:32), pair = seed + (try SolanaSendCrypto.publicKey(privateKey:seed))
        XCTAssertEqual(try SolanaMultisigCrypto.importSigner(SolanaSendCrypto.encode(pair)),seed)
        XCTAssertEqual(try SolanaMultisigCrypto.importSigner(String(decoding:JSONEncoder().encode(Array(pair)),as:UTF8.self)),seed)
        var wrong=pair;wrong[63] ^= 1
        XCTAssertThrowsError(try SolanaMultisigCrypto.importSigner(SolanaSendCrypto.encode(wrong)))
        XCTAssertThrowsError(try SolanaMultisigCrypto.importSigner(SolanaSendCrypto.encode(seed)))
        XCTAssertThrowsError(try SolanaMultisigCrypto.importSigner("[256]"))
        // Published BIP39 vector: 12-word zero entropy mnemonic, TREZOR passphrase.
        let hex="c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"
        let bytes=Data(stride(from:0,to:hex.count,by:2).map { i in UInt8(hex.dropFirst(i).prefix(2),radix:16)! })
        XCTAssertEqual(try SolanaSendCrypto.address(privateKey:SolanaMultisigCrypto.deriveSigner(seed:bytes)),"7zSmbu6gKkb6HB7UDPtHYjwCWuBHU1D4TpNZFm4sndQe")
    }
    func fixture() throws -> SolanaJSON {
        try JSONDecoder().decode(SolanaJSON.self, from: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource:"sdk-vectors",withExtension:"json",subdirectory:"Fixtures/SolanaMultisig"))))
    }
    func plan(_ row: SolanaJSON) throws -> SolanaSendPlan {
        let policy = try SolanaMultisigPolicy(createKey: XCTUnwrap(row["createKey"].string), required: Int(XCTUnwrap(row["required"].integer)), members: XCTUnwrap(row["members"].array).map { try XCTUnwrap($0.string) })
        let setup = row["kind"].string == "setup", native = row["kind"].string == "native" || setup
        return .init(network:.devnet,sender:try policy.vault,recipient:setup ? try policy.vault : try XCTUnwrap(row["recipient"].string),reference:native ? "native":try XCTUnwrap(row["mint"].string),program:native ? "":try XCTUnwrap(row["program"].string),decimals:native ? 9:6,requestedAmount:setup ? 0:1234567,amount:setup ? 0:1234567,assetBalance:1_000_000_000,nativeBalance:1_000_000_000,blockhash:policy.createKey,lastValidBlockHeight:100,slot:50,transactionFee:30000,sources:native ? []:[.init(address:try XCTUnwrap(row["source"].string),amount:1234567)],multisig:.init(policy:policy,index:setup ? 0:1,payerBalance:1_000_000_000,storageRent:10000000,setupTreasury:setup ? row["treasury"].string:nil,feePayer:row["feePayer"].string))
    }
    func testPaymentReferencesStayInMultisigInnerTransfer() throws {
        let rows = try XCTUnwrap(fixture()["vectors"].array)
        let reference = try SolanaSendCrypto.address(privateKey: Data(repeating: 87, count: 32))
        for kind in ["native", "spl", "token2022"] {
            guard let row = rows.first(where: { $0["kind"].string == kind }) else { XCTFail("Missing kind"); continue }
            let original = try plan(row)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            json["paymentReferences"] = [reference, reference]
            let updated = try JSONDecoder().decode(SolanaSendPlan.self, from: JSONSerialization.data(withJSONObject: json))
            let inner = try SolanaMultisigCrypto.inner(updated)
            XCTAssertEqual(inner.instructions.last?.keys.suffix(2).map(\.key), [reference, reference])
            XCTAssertEqual(inner.keys.first(where: { $0.key == reference })?.signer, false)
            XCTAssertEqual(inner.keys.first(where: { $0.key == reference })?.writable, false)
            XCTAssertNotEqual(try SolanaMultisigCrypto.messages(original), try SolanaMultisigCrypto.messages(updated))
        }
    }
    // Each independent SDK vector is one bounded host test. This preserves all
    // 76 signing/verification cases without charging 19 vectors to one timeout.
    func testOfficialSquadsSetupVector00() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 0) }
    func testOfficialSquadsSetupVector01() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 1) }
    func testOfficialSquadsSetupVector02() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 2) }
    func testOfficialSquadsSetupVector03() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 3) }
    func testOfficialSquadsSetupVector04() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 4) }
    func testOfficialSquadsSetupVector05() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 5) }
    func testOfficialSquadsSetupVector06() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 6) }
    func testOfficialSquadsSetupVector07() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 7) }
    func testOfficialSquadsSetupVector08() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 8) }
    func testOfficialSquadsSetupVector09() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 9) }
    func testOfficialSquadsSetupVector10() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 10) }
    func testOfficialSquadsSetupVector11() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 11) }
    func testOfficialSquadsSetupVector12() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 12) }
    func testOfficialSquadsSetupVector13() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 13) }
    func testOfficialSquadsSetupVector14() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 14) }
    func testOfficialSquadsSetupVector15() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 15) }
    func testOfficialSquadsSetupVector16() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 16) }
    func testOfficialSquadsSetupVector17() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 17) }
    func testOfficialSquadsSetupVector18() throws { try verifyOfficialSquadsVectors(kind: "setup", index: 18) }
    func testOfficialSquadsNativeVector00() throws { try verifyOfficialSquadsVectors(kind: "native", index: 0) }
    func testOfficialSquadsNativeVector01() throws { try verifyOfficialSquadsVectors(kind: "native", index: 1) }
    func testOfficialSquadsNativeVector02() throws { try verifyOfficialSquadsVectors(kind: "native", index: 2) }
    func testOfficialSquadsNativeVector03() throws { try verifyOfficialSquadsVectors(kind: "native", index: 3) }
    func testOfficialSquadsNativeVector04() throws { try verifyOfficialSquadsVectors(kind: "native", index: 4) }
    func testOfficialSquadsNativeVector05() throws { try verifyOfficialSquadsVectors(kind: "native", index: 5) }
    func testOfficialSquadsNativeVector06() throws { try verifyOfficialSquadsVectors(kind: "native", index: 6) }
    func testOfficialSquadsNativeVector07() throws { try verifyOfficialSquadsVectors(kind: "native", index: 7) }
    func testOfficialSquadsNativeVector08() throws { try verifyOfficialSquadsVectors(kind: "native", index: 8) }
    func testOfficialSquadsNativeVector09() throws { try verifyOfficialSquadsVectors(kind: "native", index: 9) }
    func testOfficialSquadsNativeVector10() throws { try verifyOfficialSquadsVectors(kind: "native", index: 10) }
    func testOfficialSquadsNativeVector11() throws { try verifyOfficialSquadsVectors(kind: "native", index: 11) }
    func testOfficialSquadsNativeVector12() throws { try verifyOfficialSquadsVectors(kind: "native", index: 12) }
    func testOfficialSquadsNativeVector13() throws { try verifyOfficialSquadsVectors(kind: "native", index: 13) }
    func testOfficialSquadsNativeVector14() throws { try verifyOfficialSquadsVectors(kind: "native", index: 14) }
    func testOfficialSquadsNativeVector15() throws { try verifyOfficialSquadsVectors(kind: "native", index: 15) }
    func testOfficialSquadsNativeVector16() throws { try verifyOfficialSquadsVectors(kind: "native", index: 16) }
    func testOfficialSquadsNativeVector17() throws { try verifyOfficialSquadsVectors(kind: "native", index: 17) }
    func testOfficialSquadsNativeVector18() throws { try verifyOfficialSquadsVectors(kind: "native", index: 18) }
    func testOfficialSquadsSPLVector00() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 0) }
    func testOfficialSquadsSPLVector01() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 1) }
    func testOfficialSquadsSPLVector02() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 2) }
    func testOfficialSquadsSPLVector03() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 3) }
    func testOfficialSquadsSPLVector04() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 4) }
    func testOfficialSquadsSPLVector05() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 5) }
    func testOfficialSquadsSPLVector06() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 6) }
    func testOfficialSquadsSPLVector07() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 7) }
    func testOfficialSquadsSPLVector08() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 8) }
    func testOfficialSquadsSPLVector09() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 9) }
    func testOfficialSquadsSPLVector10() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 10) }
    func testOfficialSquadsSPLVector11() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 11) }
    func testOfficialSquadsSPLVector12() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 12) }
    func testOfficialSquadsSPLVector13() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 13) }
    func testOfficialSquadsSPLVector14() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 14) }
    func testOfficialSquadsSPLVector15() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 15) }
    func testOfficialSquadsSPLVector16() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 16) }
    func testOfficialSquadsSPLVector17() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 17) }
    func testOfficialSquadsSPLVector18() throws { try verifyOfficialSquadsVectors(kind: "spl", index: 18) }
    func testOfficialSquadsToken2022Vector00() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 0) }
    func testOfficialSquadsToken2022Vector01() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 1) }
    func testOfficialSquadsToken2022Vector02() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 2) }
    func testOfficialSquadsToken2022Vector03() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 3) }
    func testOfficialSquadsToken2022Vector04() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 4) }
    func testOfficialSquadsToken2022Vector05() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 5) }
    func testOfficialSquadsToken2022Vector06() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 6) }
    func testOfficialSquadsToken2022Vector07() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 7) }
    func testOfficialSquadsToken2022Vector08() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 8) }
    func testOfficialSquadsToken2022Vector09() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 9) }
    func testOfficialSquadsToken2022Vector10() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 10) }
    func testOfficialSquadsToken2022Vector11() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 11) }
    func testOfficialSquadsToken2022Vector12() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 12) }
    func testOfficialSquadsToken2022Vector13() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 13) }
    func testOfficialSquadsToken2022Vector14() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 14) }
    func testOfficialSquadsToken2022Vector15() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 15) }
    func testOfficialSquadsToken2022Vector16() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 16) }
    func testOfficialSquadsToken2022Vector17() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 17) }
    func testOfficialSquadsToken2022Vector18() throws { try verifyOfficialSquadsVectors(kind: "token2022", index: 18) }
    private func verifyOfficialSquadsVectors(kind: String, index: Int) throws {
        let f = try fixture(), all = try XCTUnwrap(f["vectors"].array)
        XCTAssertEqual(all.count, 76)
        XCTAssertEqual(Set(all.compactMap { $0["kind"].string }), Set(["setup", "native", "spl", "token2022"]))
        let rows = all.filter { $0["kind"].string == kind }
        XCTAssertEqual(rows.count, 19)
        let row = try XCTUnwrap(rows.indices.contains(index) ? rows[index] : nil)
        do {
            let p = try plan(row), policy = try XCTUnwrap(p.multisig?.policy)
            XCTAssertEqual(try policy.multisig,row["multisig"].string)
            XCTAssertEqual(try policy.vault,row["vault"].string)
            XCTAssertEqual(try policy.transactionIndex(account:XCTUnwrap(Data(base64Encoded:XCTUnwrap(row["account"].string)))) ,0)
            let expected = try XCTUnwrap(row["messages"].array).map { try XCTUnwrap($0.string) }
            XCTAssertEqual(try SolanaMultisigCrypto.messages(p).map { $0.base64EncodedString() },expected)
            let seeds = try XCTUnwrap(row["seeds"].array).map { try XCTUnwrap(Data(base64Encoded:XCTUnwrap($0.string))) }
            let context = try XCTUnwrap(p.multisig)
            var keys = try context.signingMembers.map { member in seeds[try XCTUnwrap(policy.members.firstIndex(of: member))] }
            if context.setupTreasury != nil { keys.append(try XCTUnwrap(Data(base64Encoded:XCTUnwrap(f["createSeed"].string)))) }
            let stages = try SolanaMultisigCrypto.stages(p)
            XCTAssertTrue(stages.allSatisfy { $0.keys.first?.key == context.payer })
            XCTAssertEqual(stages.map(\.signerCount).reduce(0,+), context.setupTreasury != nil ? 2 : policy.required+1)
            let signed = try SolanaMultisigCrypto.sign(p,privateKeys:keys)
            let transactions = (signed.preparations ?? []) + [.init(bytes:signed.bytes,hash:signed.hash)]
            // Verify independently generated SDK signatures too. Ed25519 signing
            // implementations may randomize their nonce; message bytes must match.
            let sdk = try XCTUnwrap(row["transactions"].array).map { value -> SolanaSignedStage in
                let bytes = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(value.string)))
                return .init(bytes: bytes, hash: SolanaSendCrypto.encode(Data(bytes[1..<65])))
            }
            let final = try XCTUnwrap(sdk.last)
            try SolanaSendCrypto.verify(.init(bytes:final.bytes,publicKey:signed.publicKey,signature:Data(final.bytes[1..<65]),hash:final.hash,preparations:sdk.count > 1 ? Array(sdk.dropLast()) : nil),plan:p)
            try SolanaSendCrypto.verify(signed,plan:p)
            XCTAssertEqual(try JSONDecoder().decode(SolanaSignedSend.self,from:JSONEncoder().encode(signed)),signed)
            XCTAssertTrue(transactions.allSatisfy { $0.bytes.count <= 1232 })
        }
    }
    func testMainnetAndDevnetUseIdenticalInstructionsAndRejectUnsupportedCluster() throws {
        let f=try fixture(),row=try XCTUnwrap(f["vectors"].array?.first { $0["kind"].string=="native" }),p=try plan(row)
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as? [String:Any])
        json["network"]="mainnet"
        let mainnet=try JSONDecoder().decode(SolanaSendPlan.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertEqual(try SolanaMultisigCrypto.messages(mainnet),try SolanaMultisigCrypto.messages(p))
        json["network"]="testnet"
        XCTAssertThrowsError(try JSONDecoder().decode(SolanaSendPlan.self,from:JSONSerialization.data(withJSONObject:json)).validate())
        json["network"]="mainnet"
        var context=try XCTUnwrap(json["multisig"] as? [String:Any]);context["payerBalance"]=0;json["multisig"]=context
        XCTAssertThrowsError(try JSONDecoder().decode(SolanaSendPlan.self,from:JSONSerialization.data(withJSONObject:json)).validate()) { XCTAssertEqual($0 as? SolanaSendError,.multisigFunding) }
    }
    func testMissingDuplicateAndForeignKeysCannotSign() throws {
        let f=try fixture(), row=try XCTUnwrap(f["vectors"].array?.first { $0["required"].integer==3 && $0["kind"].string=="spl" }), p=try plan(row)
        let keys=try XCTUnwrap(row["seeds"].array).prefix(3).map { try XCTUnwrap(Data(base64Encoded:XCTUnwrap($0.string))) }
        XCTAssertThrowsError(try SolanaMultisigCrypto.sign(p,privateKeys:Array(keys.prefix(2))))
        XCTAssertThrowsError(try SolanaMultisigCrypto.sign(p,privateKeys:[keys[0],keys[0],keys[2]]))
        XCTAssertThrowsError(try SolanaMultisigCrypto.sign(p,privateKeys:[keys[0],keys[1],Data(repeating:99,count:32)]))
        let signed=try SolanaMultisigCrypto.sign(p,privateKeys:keys)
        var bytes=signed.bytes;bytes[5] ^= 1
        XCTAssertThrowsError(try SolanaMultisigCrypto.verify(.init(bytes:bytes,publicKey:signed.publicKey,signature:signed.signature,hash:signed.hash,preparations:signed.preparations),plan:p))
        XCTAssertThrowsError(try SolanaMultisigCrypto.verify(.init(bytes:signed.bytes,publicKey:signed.publicKey,signature:signed.signature,hash:signed.hash),plan:p))
        var account=try XCTUnwrap(Data(base64Encoded:XCTUnwrap(row["account"].string)))
        account[40]=1
        XCTAssertThrowsError(try XCTUnwrap(p.multisig).policy.transactionIndex(account:account))
    }
}
