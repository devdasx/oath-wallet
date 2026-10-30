import XCTest
import Foundation
@testable import OathAnkr

/// Opt-in public Testnet integration of production quote/XDR/sign/submit/status.
/// No fixture content or signed payload is ever printed by this test.
final class StellarMultisigLiveTests: XCTestCase {
    struct Fixture: Decodable {
        struct Key: Decodable { let address: String, seed: Data }
        struct Wallet: Decodable { let address: String, seed: Data, required: Int, signers: [Key] }
        let issuer: Key, recipient: Key, wallets: [Wallet], reference: String
    }
    struct Journal: Codable {
        let plan: StellarSendPlan, signed: StellarSignedSend
        var confirmed: Bool
    }
    func load() throws -> (Fixture,String) {
        guard let path=ProcessInfo.processInfo.environment["OATH_STELLAR_MULTISIG_FIXTURE"],path.hasPrefix("/tmp/") else { throw XCTSkip("Opt-in disposable Stellar Testnet") }
        return (try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:path))),path)
    }
    func account(_ address: String) async throws -> StellarJSON {
        let (bytes,response)=try await URLSession.shared.data(from:URL(string:"https://horizon-testnet.stellar.org/accounts/"+address)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StellarSendError.transport }
        return try JSONDecoder().decode(StellarJSON.self,from:bytes)
    }
    func balance(_ value: StellarJSON, token: Bool) throws -> UInt64 {
        let row=try XCTUnwrap(value["balances"].array?.first { token ? $0["asset_code"].string == "OATHLONG" : $0["asset_type"].string == "native" })
        return try XCTUnwrap(UInt64(StellarIdentity.atomic(XCTUnwrap(row["balance"].string))))
    }
    func transact(_ client: StellarSendClient, path: String, name: String, build: () async throws -> (StellarSendPlan,StellarSignedSend)) async throws -> Journal {
        let url=URL(fileURLWithPath:path+"."+name+".journal")
        var j: Journal
        if FileManager.default.fileExists(atPath:url.path) { j=try JSONDecoder().decode(Journal.self,from:Data(contentsOf:url)) }
        else {
            let (plan,signed)=try await build();j = .init(plan:plan,signed:signed,confirmed:false)
            try JSONEncoder().encode(j).write(to:url,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        }
        if !j.confirmed {
            var result=try await client.submit(j.signed,plan:j.plan)
            for _ in 0..<45 where result.outcome == .unknown || result.outcome == .accepted {
                try await Task.sleep(for:.seconds(1));result=try await client.status(j.signed,plan:j.plan)
            }
            guard result.outcome == .confirmed else { throw StellarSendError.execution }
            j.confirmed=true
            try JSONEncoder().encode(j).write(to:url,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        }
        return j
    }
    func testRealNewRecipientAndMaximumReserve() async throws {
        let (fixture,path)=try load(),client=try StellarSendClient(network:.testnet)
        let wallet=fixture.wallets[0],policy=try StellarMultisigPolicy(account:wallet.address,required:wallet.required,signers:wallet.signers.map(\.address))
        let keys=Array(wallet.signers.prefix(wallet.required)).map(\.seed)
        guard try await client.multisigState(policy).configured else { throw XCTSkip("Run setup matrix first") }
        let created=try await transact(client,path:path,name:"newRecipient") {
            let plan=try await client.quote(sender:wallet.address,recipient:wallet.signers[0].address,reference:"native",decimals:7,amount:"20000000",multisig:policy)
            XCTAssertEqual(plan.kind,.createAccount)
            return (plan,try StellarSendCrypto.sign(plan,privateKeys:keys))
        }
        let received=try await balance(account(wallet.signers[0].address),token:false)
        XCTAssertEqual(received,20000000)
        let maximum=try await transact(client,path:path,name:"maximum") {
            let plan=try await client.quote(sender:wallet.address,recipient:fixture.recipient.address,reference:"native",decimals:7,amount:"1",maximum:true,multisig:policy)
            XCTAssertEqual(UInt64(plan.amount),plan.nativeBalance-plan.reserve-plan.nativeLiabilities-UInt64(plan.fee))
            return (plan,try StellarSendCrypto.sign(plan,privateKeys:keys))
        }
        let remaining=try await balance(account(wallet.address),token:false)
        let receipt=try await client.status(maximum.signed,plan:maximum.plan)
        XCTAssertEqual(remaining,maximum.plan.reserve+maximum.plan.nativeLiabilities+UInt64(maximum.plan.fee)-receipt.fee!)
        print("STELLAR_TESTNET_NEW_RECIPIENT hash=\(created.signed.hash)")
        print("STELLAR_TESTNET_MAXIMUM hash=\(maximum.signed.hash)")
    }
    func testRealSetupTrustlinesXLMAndTokenTransfers() async throws {
        let (fixture,path)=try load(),client=try StellarSendClient(network:.testnet)
        for (index,wallet) in fixture.wallets.enumerated() {
            let policy=try StellarMultisigPolicy(account:wallet.address,required:wallet.required,signers:wallet.signers.map(\.address))
            let keys=Array(wallet.signers.reversed().prefix(wallet.required)).map(\.seed)
            let setup=try await transact(client,path:path,name:"setup\(index)") {
                let plan=try await client.configurationQuote(policy:policy)
                return (plan,try StellarSendCrypto.sign(plan,privateKey:wallet.seed))
            }
            let active = try await client.multisigState(policy)
            XCTAssertTrue(active.configured)
            _ = try await transact(client,path:path,name:"trust\(index)") {
                let plan=try await client.configurationQuote(policy:policy,assetCode:"OATHLONG",issuer:fixture.issuer.address)
                return (plan,try StellarSendCrypto.sign(plan,privateKeys:keys))
            }
            // Issuance uses the independent official SDK and an isolated issuer.
            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/env")
            guard let script=ProcessInfo.processInfo.environment["OATH_STELLAR_MULTISIG_PREPARE"] else { throw StellarSendError.configuration }
            process.arguments=["node",script,path,"issue",String(index)]
            process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
            try process.run();process.waitUntilExit();guard process.terminationStatus==0 else { throw StellarSendError.execution }
            for token in [false,true] {
                let name="send\(index)-\(token)",existed=FileManager.default.fileExists(atPath:path+"."+name+".journal")
                let before=try await balance(account(wallet.address),token:token)
                let destBefore=try await balance(account(fixture.recipient.address),token:token)
                let j=try await transact(client,path:path,name:name) {
                    let plan=try await client.quote(sender:wallet.address,recipient:fixture.recipient.address,reference:token ? fixture.reference:"native",decimals:7,amount:"1234567",multisig:policy)
                    return (plan,try StellarSendCrypto.sign(plan,privateKeys:keys))
                }
                let afterAccount=try await account(wallet.address),after=try balance(afterAccount,token:token)
                if !existed {
                    let destAfter=try await balance(account(fixture.recipient.address),token:token)
                    XCTAssertEqual(destAfter-destBefore,1234567)
                    let receipt=try await client.status(j.signed,plan:j.plan)
                    XCTAssertEqual(before-after,1234567+(token ? 0:receipt.fee!))
                }
                // Production account holdings decoding; values must remain exact.
                XCTAssertFalse(try StellarDecoding.classicHoldings(afterAccount,owner:wallet.address).isEmpty)
                let (history,_) = try await URLSession.shared.data(from:URL(string:"https://horizon-testnet.stellar.org/accounts/"+wallet.address+"/payments?order=desc&limit=100")!)
                let rows=try JSONDecoder().decode(StellarJSON.self,from:history)["_embedded"]["records"].array!
                XCTAssertTrue(rows.contains{$0["transaction_hash"].string == j.signed.hash && $0["transaction_successful"] == .bool(true)})
                let replay=try await client.submit(j.signed,plan:j.plan)
                XCTAssertEqual(replay.outcome,.confirmed)
                let replayBalance=try await balance(account(wallet.address),token:token)
                XCTAssertEqual(after,replayBalance)
                print("STELLAR_TESTNET_VERIFIED policy=\(wallet.required)/\(wallet.signers.count) asset=\(token ? "issued":"XLM") hash=\(j.signed.hash)")
            }
            print("STELLAR_TESTNET_SETUP hash=\(setup.signed.hash)")
        }
    }
}
