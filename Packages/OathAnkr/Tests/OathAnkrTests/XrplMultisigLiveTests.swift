import XCTest
@testable import OathAnkr

final class XrplMultisigLiveTests: XCTestCase {
    struct Fixture: Decodable {
        struct Wallet: Decodable { let address: String, privateKey: String }
        struct Policy: Decodable { let name: String, required: Int, owner: Wallet, signers: [Wallet] }
        let network: String, cases: [Policy], recipient: Wallet, issued: String, mpt: String, authorizationMpt: String
    }
    private func rpc(_ method:String,_ params:[String:XrplJSON]) async throws -> XrplJSON {
        var request = URLRequest(url:XrplSendNetwork.testnet.endpoint);request.httpMethod="POST";request.timeoutInterval=20
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        var p=params;p["api_version"] = .number("2")
        request.httpBody=try JSONEncoder().encode(XrplJSON.object(["method":.string(method),"params":.array([.object(p)])]))
        let (data,_) = try await URLSession.shared.data(for:request)
        return try JSONDecoder().decode(XrplJSON.self,from:data)["result"]
    }
    private func balance(_ owner:String,_ reference:String,at ledger:UInt32? = nil) async throws -> String {
        let index = ledger.map { XrplJSON.number(String($0)) } ?? .string("validated")
        func read(_ method:String,_ params:[String:XrplJSON]) async throws -> XrplJSON {
            // Public testnet nodes can lag one another. Read the exact receipt
            // ledger, never mistake an older "validated" balance for delivery.
            for attempt in 0..<6 {
                let result = try await rpc(method,params.merging(["ledger_index":index]) { _,new in new })
                if ledger != nil, ["lgrNotFound","ledgerNotFound"].contains(result["error"].string), attempt < 5 {
                    try await Task.sleep(for:.seconds(1));continue
                }
                XCTAssertEqual(result["status"].string,"success")
                XCTAssertEqual(result["validated"],.bool(true))
                if let ledger { XCTAssertEqual(result["ledger_index"].integer,UInt64(ledger)) }
                return result
            }
            throw XrplSendError.changed
        }
        if reference == "native" {
            let result=try await read("account_info",["account":.string(owner)])
            return try XCTUnwrap(result["account_data"]["Balance"].string)
        }
        if let dot=reference.lastIndex(of:".") {
            let r=try await read("account_lines",["account":.string(owner),"peer":.string(String(reference[reference.index(after:dot)...]))])
            let row=try XCTUnwrap(r["lines"].array?.first(where:{$0["currency"].string == String(reference[..<dot])}))
            return try XrplIdentity.issuedAmount(XCTUnwrap(row["balance"].string))
        }
        return try await read("ledger_entry",["mptoken":.object(["account":.string(owner),"mpt_issuance_id":.string(reference)])])["node"]["MPTAmount"].string ?? "0"
    }
    func testLivePoliciesTokensBalanceHistoryAndReplay() async throws {
        guard ProcessInfo.processInfo.environment["OATH_XRPL_MULTISIG_LIVE"] == "1",
              let path = ProcessInfo.processInfo.environment["OATH_XRPL_MULTISIG_FIXTURE"], path.hasPrefix("/tmp/") else {
            throw XCTSkip("Explicit disposable XRPL Testnet fixture required")
        }
        let f = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        guard f.network == "testnet" else { throw XrplSendError.wrongNetwork }
        let client = try XrplSendClient(network:.testnet)
        var count = 0
        for c in f.cases {
            if let filter = ProcessInfo.processInfo.environment["OATH_XRPL_MULTISIG_CASE"], filter != c.name { continue }
            count += 1
            let policy = try XrplMultisigPolicy(account:c.owner.address,required:c.required,signers:c.signers.map(\.address))
            var keys = try policy.signers.map { address in try TronIdentity.hex(String(XCTUnwrap(c.signers.first(where:{$0.address == address})).privateKey.suffix(64))) }
            var master = try TronIdentity.hex(String(c.owner.privateKey.suffix(64)))
            defer { master.resetBytes(in:0..<master.count);for i in keys.indices { keys[i].resetBytes(in:0..<keys[i].count) } }
            for _ in 0..<2 {
                let state = try await client.multisigState(policy)
                if state.configured { break }
                let plan = try await XCTUnwrapAsync { try await client.quoteMultisigSetup(policy) }
                let signed = try XrplSendCrypto.sign(plan,privateKey:master)
                _ = try await confirm(client,signed,plan)
                print("XRPL_MULTISIG_SETUP policy=\(c.name) stage=\(plan.multisigSetup!.rawValue) hash=\(signed.hash)")
            }
            let active = try await client.multisigState(policy)
            XCTAssertTrue(active.configured)
            guard active.configured else { throw XrplSendError.changed }
            // Explicit token authorization is signed with the configured threshold,
            // even when updating an existing line/opt-in from fixture funding.
            for reference in [f.issued,f.authorizationMpt] {
                if reference == f.authorizationMpt {
                    let holder = try await rpc("ledger_entry",["mptoken":.object(["account":.string(c.owner.address),"mpt_issuance_id":.string(reference)]),"ledger_index":.string("validated")])
                    if holder["node"]["Account"].string == c.owner.address { continue }
                }
                let plan = try await client.quoteTokenAuthorization(policy,reference:reference,limit:"200000")
                let signed = try XrplMultisigCrypto.sign(plan,privateKeys:Array(keys.prefix(c.required)))
                _ = try await confirm(client,signed,plan)
                print("XRPL_MULTISIG_TOKEN_AUTH policy=\(c.name) type=\(reference.contains(".") ? "issued":"MPT") hash=\(signed.hash)")
            }
            for reference in ["native",f.issued,f.mpt] {
                let amount = reference == "native" ? "123456" : reference.contains(".") ? try XrplIdentity.issuedAmount("1.25") : "123"
                let p = try await client.quote(sender:c.owner.address,recipient:f.recipient.address,reference:reference,amount:amount,destinationTag:0,multisig:policy)
                let before = try await balance(f.recipient.address,reference,at:p.firstLedger)
                let sourceBefore = try await balance(c.owner.address,reference,at:p.firstLedger)
                if c.required > 1 { XCTAssertThrowsError(try XrplMultisigCrypto.sign(p,privateKeys:Array(keys.prefix(c.required-1)))) }
                XCTAssertThrowsError(try XrplSendCrypto.sign(p,privateKey:master))
                let signed = try XrplMultisigCrypto.sign(p,privateKeys:Array(keys.prefix(c.required)))
                let receipt = try await confirm(client,signed,p)
                let ledger = try XCTUnwrap(receipt.ledger)
                let after = try await balance(f.recipient.address,reference,at:ledger)
                let sourceAfter = try await balance(c.owner.address,reference,at:ledger)
                let debit = reference == "native" ? SuiIdentity.add(p.assetDebit,String(p.fee)) : p.assetDebit
                XCTAssertEqual(after,SuiIdentity.add(before,amount))
                XCTAssertEqual(sourceAfter,SuiIdentity.add(sourceBefore,"-"+debit))
                let retried = try await client.submit(signed,plan:p)
                XCTAssertEqual(retried.outcome,.confirmed)
                let history = try await rpc("account_tx",["account":.string(c.owner.address),"ledger_index_min":.number(String(ledger)),"ledger_index_max":.number(String(ledger)),"limit":.number("20")])
                let entry = try XCTUnwrap(history["transactions"].array?.first(where:{$0["hash"].string?.uppercased() == signed.hash || $0["tx_json"]["hash"].string?.uppercased() == signed.hash}))
                let transaction = try XrplDecoding.transaction(entry,owner:c.owner.address)
                XCTAssertTrue(transaction.movements.contains(where:{$0.reference == reference && $0.direction == "outgoing" && $0.amount == p.assetDebit}))
                guard after == SuiIdentity.add(before,amount),sourceAfter == SuiIdentity.add(sourceBefore,"-"+debit),retried.outcome == .confirmed else { throw XrplSendError.changed }
                print("XRPL_MULTISIG_TRANSFER policy=\(c.name) type=\(reference == "native" ? "XRP":reference.contains(".") ? "issued":"MPT") hash=\(signed.hash) balances=true history=true replay=true")
            }
        }
        XCTAssertGreaterThan(count,0)
    }
    func testLiveMaximumTransfersAndIncomingHistory() async throws {
        guard ProcessInfo.processInfo.environment["OATH_XRPL_MULTISIG_MAX"] == "1",
              let path = ProcessInfo.processInfo.environment["OATH_XRPL_MULTISIG_FIXTURE"], path.hasPrefix("/tmp/") else {
            throw XCTSkip("Explicit disposable Testnet maximum-send run required")
        }
        let f = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        guard f.network == "testnet" else { throw XrplSendError.wrongNetwork }
        let c = try XCTUnwrap(f.cases.first), client = try XrplSendClient(network:.testnet)
        let policy = try XrplMultisigPolicy(account:c.owner.address,required:c.required,signers:c.signers.map(\.address))
        var keys = try policy.signers.prefix(c.required).map { address in try TronIdentity.hex(String(XCTUnwrap(c.signers.first(where:{$0.address == address})).privateKey.suffix(64))) }
        defer { for i in keys.indices { keys[i].resetBytes(in:0..<keys[i].count) } }
        do {
            _ = try await client.quoteTokenAuthorization(policy,reference:f.authorizationMpt,limit:"0")
            XCTFail("Already-enabled MPT should not offer another transaction")
        } catch { XCTAssertEqual(error as? XrplSendError,.tokenAlreadyEnabled) }
        let newReference = "NEW."+f.issued.split(separator:".").last!
        let trust = try await client.quoteTokenAuthorization(policy,reference:newReference,limit:"100")
        let trustSigned = try XrplMultisigCrypto.sign(trust,privateKeys:keys)
        _ = try await confirm(client,trustSigned,trust)
        print("XRPL_MULTISIG_NEW_TRUST hash=\(trustSigned.hash)")
        // Send tokens first, preserving XRP fees until the final XRP Max send.
        for reference in [f.issued,f.mpt,"native"] {
            let available = try await balance(c.owner.address,reference)
            let p = try await client.quote(sender:c.owner.address,recipient:f.recipient.address,reference:reference,amount:available,destinationTag:0,maximum:true,multisig:policy)
            let before = try await balance(f.recipient.address,reference,at:p.firstLedger)
            let signed = try XrplMultisigCrypto.sign(p,privateKeys:keys)
            let receipt = try await confirm(client,signed,p), ledger = try XCTUnwrap(receipt.ledger)
            let after = try await balance(f.recipient.address,reference,at:ledger)
            let left = try await balance(c.owner.address,reference,at:ledger)
            XCTAssertEqual(after,SuiIdentity.add(before,p.amount))
            if reference == "native" { XCTAssertEqual(left,String(p.reserve)) }
            else { XCTAssertEqual(left,SuiIdentity.add(p.assetBalance,"-"+p.assetDebit)) }
            let history = try await rpc("account_tx",["account":.string(f.recipient.address),"ledger_index_min":.number(String(ledger)),"ledger_index_max":.number(String(ledger)),"limit":.number("20")])
            let entry = try XCTUnwrap(history["transactions"].array?.first(where:{$0["hash"].string?.uppercased() == signed.hash || $0["tx_json"]["hash"].string?.uppercased() == signed.hash}))
            let transaction = try XrplDecoding.transaction(entry,owner:f.recipient.address)
            XCTAssertTrue(transaction.movements.contains(where:{$0.reference == reference && $0.direction == "incoming" && $0.amount == p.amount}))
            print("XRPL_MULTISIG_MAX type=\(reference == "native" ? "XRP":reference.contains(".") ? "issued":"MPT") hash=\(signed.hash) balances=true incomingHistory=true")
        }
    }
    private func confirm(_ client: XrplSendClient,_ signed: XrplSignedSend,_ plan: XrplSendPlan) async throws -> XrplSendReceipt {
        // Persist exact public signed bytes before broadcast. A failed run can
        // reconcile these hashes rather than fabricate confirmation.
        struct Journal: Codable { let plan:XrplSendPlan, signed:XrplSignedSend }
        let file = URL(fileURLWithPath:"/tmp/oath-xrp-multisig-"+signed.hash+".json")
        try JSONEncoder().encode(Journal(plan:plan,signed:signed)).write(to:file,options:.atomic)
        var receipt = try await client.submit(signed,plan:plan)
        for _ in 0..<40 where [.unknown,.accepted].contains(receipt.outcome) {
            try await Task.sleep(for:.seconds(1))
            receipt = try await client.status(signed,plan:plan)
        }
        XCTAssertEqual(receipt.outcome,.confirmed)
        guard receipt.outcome == .confirmed else { throw XrplSendError.changed }
        return receipt
    }
}
private func XCTUnwrapAsync<T>(_ operation: () async throws -> T?) async throws -> T { let value = try await operation(); return try XCTUnwrap(value) }
