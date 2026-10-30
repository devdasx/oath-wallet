import XCTest
import CryptoKit
@testable import OathAnkr

/// Uses opt-in, isolated test-only seeds outside the repository. The production
/// Swift planner/signer/client performs transfers; the JS SDK only mints fixtures.
@MainActor final class SolanaSendLiveTests:XCTestCase {
    struct Fixture:Decodable {
        let seed:String,recipientSeed:String,recipient:String,sender:String,network:String
        let splMint:String?,token2022Mint:String?,feeMint:String?
    }
    private func rpc(_ network:SolanaSendNetwork,_ method:String,_ params:[SolanaJSON]) async throws -> SolanaJSON {
        var request=URLRequest(url:network.endpoint);request.httpMethod="POST";request.timeoutInterval=15
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try JSONEncoder().encode(SolanaJSON.object(["id":.number("1"),"jsonrpc":.string("2.0"),"method":.string(method),"params":.array(params)]))
        let (data,status)=try await AnkrHTTPTransport().send(request)
        XCTAssertEqual(status,200)
        let j=try JSONDecoder().decode(SolanaJSON.self,from:data)
        guard j["error"].isNull else { throw SolanaSendError.malformed }
        return j["result"]
    }
    private func balance(_ network:SolanaSendNetwork,_ owner:String) async throws -> UInt64 {
        let j=try await rpc(network,"getBalance",[.string(owner),.object(["commitment":.string("finalized")])])
        return try XCTUnwrap(j["value"].integer)
    }
    private func tokenBalance(_ network:SolanaSendNetwork,owner:String,mint:String) async throws -> UInt64 {
        let j=try await rpc(network,"getTokenAccountsByOwner",[.string(owner),.object(["mint":.string(mint)]),.object(["encoding":.string("jsonParsed"),"commitment":.string("finalized")])])
        return try XCTUnwrap(j["value"].array).reduce(0) { total,a in
            total + (try XCTUnwrap(a["account"]["data"]["parsed"]["info"]["tokenAmount"]["amount"].string.flatMap(UInt64.init)))
        }
    }
    /// No spending or keys: exercises real devnet fee/preflight responses with
    /// signature verification disabled by the quote simulator. This is not
    /// counted as a signed/broadcast transfer integration test.
    func testLiveDevnetReadOnlyPreparation() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SOLANA_PUBLIC_QUOTE"]=="1" else { throw XCTSkip("Opt-in public read-only devnet check") }
        // Public example account from Solana's requestAirdrop documentation.
        // No private key is known or used; no transaction is signed/submitted.
        let sender="83astBRguLMdt2h5U1Tpdq5tjFoJ6noeGwaY3mDLVcri"
        let recipient=SolanaSendCrypto.encode(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let client=try SolanaSendClient(network:.devnet)
        // Classic SPL fixture was discovered in that public example account's
        // parsed devnet inventory. These are independent read-only preparations.
        for reference in ["native","4n7cMdNE3nqHoTD8R8iG2eZvVgZoPBH9dforQAPUCEs9"] {
            let plan=try await client.quote(sender:sender,recipient:recipient,reference:reference,decimals:9,amount:"1000000",memo:"Read-only Oath preparation check")
            XCTAssertEqual(plan.amount,1_000_000);XCTAssertGreaterThan(plan.transactionFee,0)
            if reference != "native" { XCTAssertGreaterThan(plan.rent,0) }
            try await client.preflight(plan)
            print("SOLANA_DEVNET_READ_ONLY_QUOTE kind=\(reference=="native" ? "SOL":"SPL") fee=\(plan.transactionFee) rent=\(plan.rent) computeUnits=\(plan.computeUnits) simulated=true broadcast=false")
        }
    }
    private func execute(_ plan:SolanaSendPlan,key:Data,client:SolanaSendClient,name:String) async throws -> SolanaSendReceipt {
        try await client.preflight(plan)
        let signed=try SolanaSendCrypto.sign(plan,privateKey:key)
        let directory=URL(fileURLWithPath:"/tmp/oath-solana-live")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try JSONEncoder().encode(plan).write(to:directory.appendingPathComponent("plan-\(name).json"))
        try JSONEncoder().encode(signed).write(to:directory.appendingPathComponent("signed-\(name).json"))
        let submitted=try await client.submit(signed,plan:plan)
        XCTAssertTrue([.accepted,.confirmed].contains(submitted.outcome))
        // New client has no ephemeral state, and follows the saved signature.
        let resumed=try SolanaSendClient(network:plan.network)
        var receipt=submitted
        for _ in 0..<60 {
            if [.confirmed,.failed,.expired].contains(receipt.outcome) { break }
            try await Task.sleep(for:.seconds(2));receipt=try await resumed.status(signed,plan:plan)
        }
        XCTAssertEqual(receipt.outcome,.confirmed)
        XCTAssertNotNil(receipt.slot);XCTAssertNotNil(receipt.fee)
        let duplicate=try await resumed.submit(signed,plan:plan)
        XCTAssertEqual(duplicate.outcome,.confirmed,"Replaying the journal must not pay twice")
        print("SOLANA_TESTNET_CONFIRMED kind=\(name) hash=\(signed.hash) fee=\(receipt.fee ?? 0)")
        return receipt
    }
    func testLiveNativeSPLToken2022AndFeeToken() async throws {
        guard let path=ProcessInfo.processInfo.environment["OATH_SOLANA_TESTNET_FIXTURE"] else { throw XCTSkip("Opt-in free test funds only") }
        let f=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        guard let network=SolanaSendNetwork(rawValue:f.network),network != .mainnet else { throw SolanaSendError.wrongNetwork }
        var key=try TronIdentity.hex(f.seed);defer { key.resetBytes(in:0..<key.count) }
        let client=try SolanaSendClient(network:network)
        XCTAssertEqual(try SolanaSendCrypto.address(privateKey:key),f.sender)
        let tokens=["native",try XCTUnwrap(f.splMint),try XCTUnwrap(f.token2022Mint),try XCTUnwrap(f.feeMint)]
        for (index,reference) in tokens.enumerated() {
            let nativeBefore=try await balance(network,f.sender),recipientBefore=try await balance(network,f.recipient)
            let tokenBefore=reference=="native" ? 0:try await tokenBalance(network,owner:f.sender,mint:reference)
            let receivedBefore=reference=="native" ? 0:try await tokenBalance(network,owner:f.recipient,mint:reference)
            // SPL Max consumes both fixture accounts, exercising source aggregation.
            let plan=try await client.quote(sender:f.sender,recipient:f.recipient,reference:reference,decimals:reference=="native" ? 9:6,amount:reference=="native" ? "1000000":"1234567",maximum:index==1,memo:"Oath test transfer")
            XCTAssertGreaterThan(plan.transactionFee,0)
            if reference==f.feeMint { XCTAssertGreaterThan(plan.amount-plan.receivedAmount,0) }
            if index==1 { XCTAssertGreaterThan(plan.sources.count,1) }
            let receipt=try await execute(plan,key:key,client:client,name:"asset-\(index)")
            let nativeAfter=try await balance(network,f.sender)
            XCTAssertEqual(nativeBefore-nativeAfter,(reference=="native" ? plan.amount:0)+plan.rent+(receipt.fee ?? 0))
            if reference=="native" {
                let received=try await balance(network,f.recipient)
                XCTAssertEqual(received-recipientBefore,plan.amount)
            } else {
                let remaining=try await tokenBalance(network,owner:f.sender,mint:reference)
                let received=try await tokenBalance(network,owner:f.recipient,mint:reference)
                XCTAssertEqual(tokenBefore-remaining,plan.amount)
                XCTAssertEqual(received-receivedBefore,plan.receivedAmount)
            }
        }
        // Native Max is tested on the separate recipient, preserving the main
        // test payer's funds for durable recovery tests and subsequent fixtures.
        var recipientKey=try TronIdentity.hex(f.recipientSeed);defer { recipientKey.resetBytes(in:0..<recipientKey.count) }
        let maxPlan=try await client.quote(sender:f.recipient,recipient:f.sender,reference:"native",decimals:9,amount:"1",maximum:true)
        _ = try await execute(maxPlan,key:recipientKey,client:client,name:"native-max")
        let remaining=try await balance(network,f.recipient);XCTAssertEqual(remaining,0)
    }
}
