import XCTest
@testable import OathAnkr

/// Explicit opt-in. Secrets remain in a private /tmp fixture; only devnet is used.
@MainActor final class SolanaMultisigLiveTests: XCTestCase {
    func testDevnetCreationTransfersBalancesAndHistory() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SOLANA_MULTISIG_LIVE"] == "1",
              let path = ProcessInfo.processInfo.environment["OATH_SOLANA_TESTNET_FIXTURE"], path.hasPrefix("/tmp/") else { throw XCTSkip("Opt-in funded devnet tests") }
        let f = try JSONDecoder().decode(SolanaJSON.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        guard f["network"].string == "devnet" else { throw SolanaSendError.wrongNetwork }
        let client = try SolanaSendClient(network:.devnet,transport:DevnetMultisigTransport())
        func bytes(_ j: SolanaJSON) throws -> Data { Data(try XCTUnwrap(j.array).map { UInt8(try XCTUnwrap($0.integer)) }) }
        let recipient = try XCTUnwrap(f["recipient"].string)
        func inventory(_ owner: String) async throws -> SolanaInventory {
            async let native = client.rpc("getBalance",[.string(owner),.object(["commitment":.string("finalized")])])
            async let classic = client.rpc("getTokenAccountsByOwner",[.string(owner),.object(["programId":.string(SolanaIdentity.tokenProgram)]),.object(["encoding":.string("jsonParsed"),"commitment":.string("finalized")])])
            async let extended = client.rpc("getTokenAccountsByOwner",[.string(owner),.object(["programId":.string(SolanaIdentity.token2022Program)]),.object(["encoding":.string("jsonParsed"),"commitment":.string("finalized")])])
            return try await SolanaDecoding.inventory(owner:owner,values:[native,classic,extended])
        }
        func funds(_ owner: String, _ reference: String) async throws -> UInt64 {
            let i = try await inventory(owner)
            if reference == "native" { return try XCTUnwrap(UInt64(i.lamports)) }
            return try i.accounts.filter { $0.mint == reference }.reduce(0) { try $0 + XCTUnwrap(UInt64($1.amount)) }
        }
        func execute(_ p: SolanaSendPlan, keys: [Data]) async throws -> SolanaSignedSend {
            let signed = try SolanaMultisigCrypto.sign(p,privateKeys:keys)
            // Durable test journal mirrors the app ordering before first broadcast.
            let journal = URL(fileURLWithPath:"/tmp/oath-solana-live-\(signed.hash).json")
            try JSONEncoder().encode(signed).write(to:journal,options:.atomic)
            if ProcessInfo.processInfo.environment["OATH_SOLANA_CASE"] == "mixed", p.reference == "native", let preparation = signed.preparations?.first {
                // Broadcast only the non-spending proposal, then prove the live
                // program rejects execution with one required approval absent.
                try await client.sendMultisigStage(preparation,slot:p.slot)
                var confirmed = false
                for _ in 0..<20 {
                    let tx = try await client.rpc("getTransaction",[.string(preparation.hash),.object(["encoding":.string("base64"),"commitment":.string("confirmed"),"maxSupportedTransactionVersion":SolanaTransactionRead.maximumVersion])])
                    if !tx.isNull { XCTAssertTrue(tx["meta"]["err"].isNull); confirmed = true; break }
                    try await Task.sleep(for:.seconds(1))
                }
                XCTAssertTrue(confirmed)
                let stage = try XCTUnwrap(SolanaMultisigCrypto.stages(p).last)
                let partial = try SolanaMultisigCrypto.compile(payer:p.multisig!.payer,instructions:Array(stage.instructions.dropFirst()))
                let bytes = SolanaSendCrypto.short(partial.signerCount)+Data(repeating:0,count:partial.signerCount*64)+(try partial.message(p.blockhash))
                let simulation = try await client.rpc("simulateTransaction",[.string(bytes.base64EncodedString()),.object(["encoding":.string("base64"),"sigVerify":.bool(false),"commitment":.string("confirmed")])])
                let error = try XCTUnwrap(simulation["value"]["err"]["InstructionError"].array)
                XCTAssertEqual(error.last?["Custom"].integer,6008) // Squads InvalidProposalStatus
                print("DEVNET program rejected execution below threshold (6008)")
            }
            // Reload exactly the stored bytes, as the app does after restart.
            let recovered = try JSONDecoder().decode(SolanaSignedSend.self,from:Data(contentsOf:journal))
            XCTAssertTrue(recovered == signed, "Restart must preserve exact signed bytes")
            _ = try await client.submit(recovered,plan:p,reconcileFirst:false)
            var receipt = try await client.status(signed,plan:p)
            for _ in 0..<50 where receipt.outcome != .confirmed && receipt.outcome != .failed && receipt.outcome != .expired {
                try await Task.sleep(for:.seconds(2)); receipt = try await client.status(signed,plan:p)
            }
            XCTAssertEqual(receipt.outcome,.confirmed)
            guard receipt.outcome == .confirmed else { throw SolanaSendError.execution }
            print("DEVNET multisig \(p.multisig!.policy.required)-of-\(p.multisig!.policy.members.count) \(p.multisig!.setupTreasury == nil ? (p.reference == "native" ? "SOL" : p.program == SolanaIdentity.tokenProgram ? "SPL" : "Token-2022") : "setup") confirmed \(signed.hash)")
            return signed
        }
        var executedCases = 0
        for item in try XCTUnwrap(f["cases"].array) {
            if let tag = ProcessInfo.processInfo.environment["OATH_SOLANA_CASE"], item["tag"].string != tag { continue }
            executedCases += 1
            for source in item["derived"].array ?? [] {
                XCTAssertTrue(try SolanaMultisigCrypto.deriveSigner(seed:bytes(source["bip39Seed"])) == bytes(source["key"]), "Independent signer derivation must match")
            }
            let keys = try XCTUnwrap(item["seeds"].array).map(bytes), create = try bytes(item["createSeed"])
            let policy = try SolanaMultisigPolicy(createKey:SolanaSendCrypto.encode(SolanaSendCrypto.publicKey(privateKey:create)),required:Int(XCTUnwrap(item["required"].integer)),members:keys.map { try SolanaSendCrypto.encode(SolanaSendCrypto.publicKey(privateKey:$0)) })
            func selectedKeys(_ plan: SolanaSendPlan) throws -> [Data] {
                try XCTUnwrap(plan.multisig).signingMembers.map { address in
                    try XCTUnwrap(keys.first { try SolanaSendCrypto.encode(SolanaSendCrypto.publicKey(privateKey:$0)) == address })
                }
            }
            let vault = try policy.vault
            if try await client.multisigIndex(policy) == nil {
                let setup = try await client.quoteMultisigSetup(policy)
                _ = try await execute(setup,keys:selectedKeys(setup)+[create])
            }
            let configured = try await client.multisigIndex(policy); XCTAssertNotNil(configured)
            let references = ProcessInfo.processInfo.environment["OATH_SOLANA_ASSET"] == "fee" ? [try XCTUnwrap(f["feeToken"].string)] : ["native", try XCTUnwrap(f["spl"].string), try XCTUnwrap(f["token2022"].string)]
            for reference in references {
                let before = try await funds(recipient,reference), senderBefore = try await funds(vault,reference)
                let p = try await client.quoteMultisig(policy,recipient:recipient,reference:reference,decimals:reference == "native" ? 9:6,amount:"1234567")
                let selected = try selectedKeys(p)
                if reference == f["feeToken"].string { XCTAssertEqual(p.amount-p.receivedAmount,1000) }
                if policy.required > 1 { XCTAssertThrowsError(try SolanaMultisigCrypto.sign(p,privateKeys:Array(selected.dropLast()))) }
                XCTAssertThrowsError(try SolanaMultisigCrypto.sign(p,privateKeys:[create]))
                let signed = try await execute(p,keys:selected)
                let after = try await funds(recipient,reference), senderAfter = try await funds(vault,reference)
                XCTAssertEqual(after-before,p.receivedAmount); XCTAssertEqual(senderBefore-senderAfter,p.amount)
                let replay = try await client.submit(signed,plan:p)
                XCTAssertEqual(replay.outcome,.confirmed)
                let replayBalance = try await funds(recipient,reference); XCTAssertEqual(replayBalance,after)
                let raw = try await client.rpc("getTransaction",[.string(signed.hash),.object(["encoding":.string("jsonParsed"),"commitment":.string("finalized"),"maxSupportedTransactionVersion":SolanaTransactionRead.maximumVersion])])
                let parsed = try SolanaDecoding.transaction(raw,signature:signed.hash,owner:vault)
                XCTAssertFalse(parsed.failed)
                let history = try SolanaDecoding.signatures(await client.rpc("getSignaturesForAddress",[.string(vault),.object(["limit":.number("50"),"commitment":.string("finalized")])]))
                XCTAssertTrue(history.contains { $0.signature == signed.hash })
                XCTAssertTrue(parsed.changes.contains { $0.mint == reference })
            }
        }
        XCTAssertGreaterThan(executedCases,0,"The requested funded fixture must exist")
    }
}

private actor DevnetMultisigTransport: AnkrTransport {
    let base = AnkrHTTPTransport()
    var next = Date.distantPast
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.url?.host == "api.devnet.solana.com" else { throw SolanaSendError.wrongNetwork }
        for attempt in 0..<4 {
            let delay = max(0,next.timeIntervalSinceNow)
            next = Date.now.addingTimeInterval(delay+0.6)
            if delay > 0 { try await Task.sleep(for:.seconds(delay)) }
            let result = try await base.send(request)
            if result.1 != 429 || attempt == 3 { return result }
            try await Task.sleep(for:.seconds(10))
        }
        throw SolanaSendError.transport
    }
}
