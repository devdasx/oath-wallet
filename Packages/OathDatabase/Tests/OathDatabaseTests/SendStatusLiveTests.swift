import CryptoKit
import Foundation
import GRDB
import OathAnkr
import XCTest
@testable import OathDatabase

/// Opt-in public TESTNET integration. Test-only insertion simulates a crash
/// after journaling: production queue APIs intentionally reject testnet plans.
/// The reopened database uses the real scheduler, status RPCs and settlement.
@MainActor final class SendStatusLiveTests: XCTestCase {
    private func fixture(_ chain: String) throws -> [String: Any] {
        guard ProcessInfo.processInfo.environment["OATH_STATUS_LIVE"] == "1" else { throw XCTSkip("Explicit public testnet opt-in required") }
        let data = try Data(contentsOf: URL(fileURLWithPath: "/tmp/oath-" + chain + "-testnet-fixture.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func text(_ value: [String: Any], _ path: String...) throws -> String {
        var node: Any = value
        for key in path { node = (node as? [String: Any])?[key] as Any }
        return try XCTUnwrap(node as? String)
    }
    func track<P: Encodable, S: Encodable>(chain: String, reference: String, decimals: Int,
        sender: String, recipient: String, amount: String, hash: String, plan: P, signed: S,
        planTable: String? = nil, rawPayload: Data? = nil, timeoutSeconds: Int = 240,
        check: @escaping @Sendable (OathDatabase, String) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StatusLive-" + UUID().uuidString).appendingPathComponent("db.sqlite")
        let db = try await OathDatabase.open(at: url), id = UUID().uuidString, asset = chain + ":" + reference
        try await db.seed(networks: [.init(id: chain, name: chain, family: "account", symbol: "TEST", decimals: decimals, derivationPath: "test", logo: "", sortOrder: 0)],
                          assets: [.init(id: asset, networkID: chain, reference: reference, name: "Testnet", symbol: "TEST", decimals: decimals)])
        try await db.importWalletIfNeeded(.init(id: "fixture", name: "Testnet", kind: "privateKey", vaultReference: "test-only", createdAt: 1),
            accounts: [.init(id: "sender", walletID: "fixture", networkID: chain, address: sender, derivationPath: "test")])
        let planData = try JSONEncoder().encode(plan), payload = try rawPayload ?? JSONEncoder().encode(signed)
        let table = planTable ?? chain + "SendPlans"
        try await db.pool.write { sql in
            let tx = chain + ":" + hash
            try TransactionRecord(id: tx, networkID: chain, hash: hash, state: "pending", timestamp: 1, updatedAt: 1).insert(sql)
            var send = SendRecord(id: id, walletID: "fixture", accountID: "sender", networkID: chain, assetID: asset,
                idempotencyKey: id, recipient: recipient, amountAtomic: amount, state: "signed", signedPayload: payload,
                transactionID: tx, createdAt: 1, updatedAt: 1)
            send.senderAddress = sender
            try send.insert(sql)
            // Table identity comes only from fixed test case literals.
            try sql.execute(sql: "INSERT INTO \(table)(sendID,plan) VALUES(?,?)", arguments: [id,planData])
            if chain == "ton" { try sql.execute(sql:"UPDATE tonSendPlans SET messageHash=? WHERE sendID=?",arguments:[hash,id]) }
        }
        _ = try await db.claimSendStatusChecks(owner: "terminated-test-process")
        let reopened = try await OathDatabase.open(at: url)
        let worker = SendStatusTracker(database: reopened, owner: "restarted-test-process") { send in
            do { try await check(reopened, send.id) }
            catch {
                // Fixed enum cases only; no provider message, SQL or payload.
                if let e = error as? NearSendError { print("STATUS_TESTNET_RETRY near \(e)") }
                else { print("STATUS_TESTNET_RETRY chain=\(chain) type=\(type(of: error))") }
                throw error
            }
        }
        await worker.resume()
        var state = "broadcast"
        for _ in 0..<timeoutSeconds {
            state = try await reopened.send(id)?.state ?? "missing"
            if state == "confirmed" || state == "failed" { break }
            try await Task.sleep(for: .seconds(1))
        }
        await worker.pause()
        XCTAssertEqual(state, "confirmed", "Public testnet tracking must settle before timeout")
        let persisted = try await OathDatabase.open(at: url)
        let evidence = try await persisted.pool.read { sql in
            (try String.fetchOne(sql, sql: "SELECT t.state FROM transactions t JOIN sends s ON s.transactionID=t.id WHERE s.id=?", arguments: [id]),
             try Int.fetchOne(sql, sql: "SELECT COUNT(*) FROM sendStatusChecks"))
        }
        XCTAssertEqual(evidence.0, "confirmed"); XCTAssertEqual(evidence.1, 0)
        if state == "confirmed" { print("STATUS_\(ProcessInfo.processInfo.environment["OATH_ARC_LOCAL_EVM"] == "1" ? "LOCAL_EVM" : "TESTNET")_CONFIRMED chain=\(chain) kind=\(reference == "native" ? "native" : "token") hash=\(hash) reopened=true queue_removed=true") }
    }
    func testArcLocalEVMRestartRecovery() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ARC_LOCAL_EVM"]=="1" else { throw XCTSkip("Opt-in loopback EVM recovery") }
        let f=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"/tmp/oath-arc-local-fixture.json"))) as? [String:String])
        let sender=try XCTUnwrap(f["sender"]),recipient=try XCTUnwrap(f["recipient"])
        let client=ArcSendClient(network:.testnet,transport:ArcLoopbackTransport())
        let plan=try await client.quote(sender:sender,recipient:recipient,reference:"native",decimals:18,amount:"1000000000000")
        let signed=try ArcSendCrypto.sign(plan,privateKey:Data(repeating:1,count:32))
        try await track(chain:"arc",reference:"native",decimals:18,sender:sender,recipient:recipient,amount:plan.amount,hash:signed.hash,plan:plan,signed:signed,timeoutSeconds:30) {
            try await $0.reconcileArcSend($1,client:client)
        }
    }
    func testLiveArcResumesJournalAfterRestart() async throws {
        let f=try fixture("arc")
        var key=try TronIdentity.hex(text(f,"privateKey"));defer { key.resetBytes(in:0..<key.count) }
        let client=ArcSendClient(network:.testnet),sender=try text(f,"sender"),recipient=try text(f,"recipient")
        let plan=try await client.quote(sender:sender,recipient:recipient,reference:"native",decimals:18,amount:"1000000000000")
        let signed=try ArcSendCrypto.sign(plan,privateKey:key)
        try await track(chain:"arc",reference:"native",decimals:18,sender:sender,recipient:recipient,amount:plan.amount,hash:signed.hash,plan:plan,signed:signed,timeoutSeconds:90) {
            try await $0.reconcileArcSend($1,client:client)
        }
    }
    func testLiveXrplNativeIssuedAndMPT() async throws {
        let f = try fixture("xrpl")
        var key = try TronIdentity.hex(String(text(f,"sender","privateKey").suffix(64)))
        defer { key.resetBytes(in: 0..<key.count) }
        let sender = try text(f,"sender","address"), recipient = try text(f,"recipient","address")
        let client = try XrplSendClient(network: .testnet)
        for reference in ["native", try text(f,"issued"), try text(f,"mpt")] {
            let amount = reference == "native" ? "1000" : reference.contains(".") ? try XrplIdentity.issuedAmount("0.001") : "1"
            let plan = try await client.quote(sender: sender, recipient: recipient, reference: reference, amount: amount, destinationTag: 0)
            let signed = try XrplSendCrypto.sign(plan, privateKey: key)
            try await track(chain: "xrpl", reference: reference, decimals: 6, sender: sender, recipient: recipient,
                amount: amount, hash: signed.hash, plan: plan, signed: signed) { try await $0.reconcileXrplSend($1, client: client) }
        }
    }
    func testLiveStellarNativeClassicAndContract() async throws {
        let f = try fixture("stellar")
        let client = try StellarSendClient(network: .testnet)
        let references = ["native", try text(f,"classicReference"), try text(f,"contract")]
        let contractOnly = ProcessInfo.processInfo.environment["OATH_STATUS_STELLAR_CONTRACT_ONLY"] == "1"
        for reference in contractOnly ? Array(references.suffix(1)) : references {
            let isContract = reference == (try text(f,"contract"))
            let role = isContract ? "issuer" : "sender"
            let sender = try text(f,role,"address"), recipient = try text(f,isContract ? "sender" : "recipient","address")
            var key = try XCTUnwrap(Data(base64Encoded: text(f,role,"seed")))
            defer { key.resetBytes(in: 0..<key.count) }
            let decimals = isContract ? 6 : 7
            let plan = try await client.quote(sender: sender, recipient: recipient, reference: reference, decimals: decimals, amount: "1000",
                memo: isContract ? .init() : .init(type: .id, value: "0"))
            let signed = try StellarSendCrypto.sign(plan, privateKey: key)
            try await track(chain: "stellar", reference: reference, decimals: decimals, sender: sender, recipient: recipient,
                amount: plan.amount, hash: signed.hash, plan: plan, signed: signed) { try await $0.reconcileStellarSend($1, client: client) }
        }
    }
    func testLiveTronNativeTRC10AndTRC20() async throws {
        let f = try fixture("tron")
        let client = try TronSendClient(network: .nile)
        for reference in ["native", "1005416", "TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf"] {
            // Prior maximum tests moved the test tokens to recipient. Fund its
            // gas, then send small token amounts back using its isolated key.
            let native = reference == "native"
            var key = try TronIdentity.hex(text(f,native ? "key" : "recipientKey"))
            defer { key.resetBytes(in: 0..<key.count) }
            let sender = try text(f,native ? "sender" : "recipient"), recipient = try text(f,native ? "recipient" : "sender")
            let plan = try await client.quote(sender: sender, recipient: recipient, reference: reference, decimals: 6, amount: native ? "100000000" : "1000")
            let signed = try TronSendCrypto.sign(plan, privateKey: key)
            try await track(chain: "tron", reference: reference, decimals: 6, sender: sender, recipient: recipient,
                amount: plan.amount, hash: signed.hash, plan: plan, signed: signed) { try await $0.reconcileTronSend($1, client: client) }
        }
    }
    func testLiveSolanaNativeSPLAndToken2022() async throws {
        let f=try fixture("solana")
        var key=try TronIdentity.hex(text(f,"seed"));defer { key.resetBytes(in:0..<key.count) }
        let network=try XCTUnwrap(SolanaSendNetwork(rawValue:text(f,"network")))
        guard network != .mainnet else { throw SolanaSendError.wrongNetwork }
        let sender=try text(f,"sender"),recipient=try text(f,"recipient"),client=try SolanaSendClient(network:network)
        let references = ["native",try text(f,"splMint"),try text(f,"token2022Mint"),try text(f,"feeMint")]
        let extensionsOnly = ProcessInfo.processInfo.environment["OATH_STATUS_SOLANA_EXTENSIONS_ONLY"] == "1"
        for reference in extensionsOnly ? Array(references.suffix(2)) : references {
            // Respect the shared public devnet quota between test cases.
            try await Task.sleep(for: .seconds(4))
            let decimals=reference=="native" ? 9:6
            let plan=try await client.quote(sender:sender,recipient:recipient,reference:reference,decimals:decimals,amount:"1000000")
            let signed=try SolanaSendCrypto.sign(plan,privateKey:key)
            try await track(chain:"solana",reference:reference,decimals:decimals,sender:sender,recipient:recipient,amount:String(plan.amount),hash:signed.hash,plan:plan,signed:signed) {
                try await $0.reconcileSolanaSend($1,client:client)
            }
        }
    }
    func testLiveTonNativeAndJetton() async throws {
        let f=try fixture("ton")
        var key=try TronIdentity.hex(text(f,"seed"));defer { key.resetBytes(in:0..<key.count) }
        let sender=try text(f,"sender"),recipient=try text(f,"recipient"),client=try TonSendClient(network:.testnet)
        for reference in ["native",try text(f,"jetton")] {
            let plan=try await client.quote(sender:sender,recipient:recipient,reference:reference,publicKey:TonSendCrypto.publicKey(privateKey:key),decimals:9,amount:"1000000")
            let signed=try TonSendCrypto.sign(plan,privateKey:key)
            try await track(chain:"ton",reference:reference,decimals:9,sender:sender,recipient:recipient,amount:String(plan.amount),hash:signed.hash,plan:plan,signed:signed) {
                try await $0.reconcileTonSend($1,client:client)
            }
        }
    }
    func testLiveAptosNativeCoinAndFungibleAsset() async throws {
        let f=try fixture("aptos")
        var key=try TronIdentity.hex(text(f,"privateKey").replacingOccurrences(of:"ed25519-priv-",with:""))
        defer { key.resetBytes(in:0..<key.count) }
        let sender=try text(f,"sender"),recipient=try text(f,"recipient"),client=try AptosSendClient(network:.testnet)
        for reference in ["native",try text(f,"coin"),try text(f,"fa")] {
            let decimals=reference=="native" ? 8:6
            let plan=try await client.quote(sender:sender,recipient:recipient,reference:reference,publicKey:AptosSendCrypto.publicKey(privateKey:key),decimals:decimals,amount:"1000")
            let signed=try AptosSendCrypto.sign(plan,privateKey:key)
            try await track(chain:"aptos",reference:reference,decimals:decimals,sender:sender,recipient:recipient,amount:String(plan.amount),hash:signed.hash,plan:plan,signed:signed) {
                try await $0.reconcileAptosSend($1,client:client)
            }
        }
    }
    func testLiveNearNativeAndToken() async throws {
        let f = try fixture("near")
        var key = try XCTUnwrap(Data(base64Encoded: text(f,"seed"))); defer { key.resetBytes(in: 0..<key.count) }
        let sender = try text(f,"sender")
        let recipients = try XCTUnwrap(f["recipients"] as? [[String: Any]])
        let recipient = try text(recipients[0],"address")
        let client = try NearSendClient(network: .testnet)
        for reference in ["native", try text(f,"token")] {
            let plan = try await client.quote(sender: sender, recipient: recipient, reference: reference,
                publicKey: NearSendCrypto.publicKey(privateKey: key), decimals: 24, amount: "1000000000000000000")
            try await client.preflight(plan)
            let signed = try NearSendCrypto.sign(plan, privateKey: key)
            try await track(chain: "near", reference: reference, decimals: 24, sender: sender, recipient: recipient,
                amount: plan.amount, hash: signed.hash, plan: plan, signed: signed) { try await $0.reconcileNearSend($1, client: client) }
        }
    }
    func testLiveSuiNativeAndToken() async throws {
        guard ProcessInfo.processInfo.environment["OATH_STATUS_LIVE"] == "1" else { throw XCTSkip("Explicit public testnet opt-in required") }
        var key = try Data(contentsOf: URL(fileURLWithPath: "/tmp/oath-sui-testnet-key.bin")); defer { key.resetBytes(in: 0..<key.count) }
        let sender = try SuiSendCrypto.address(privateKey: key)
        let recipient = try SuiSendCrypto.address(privateKey: Curve25519.Signing.PrivateKey().rawRepresentation)
        let client = try SuiSendClient(network: .testnet)
        var references = ["native"]
        if let token = ProcessInfo.processInfo.environment["OATH_SUI_TESTNET_TOKEN"] { references.append(token) }
        for reference in references {
            let plan = try await client.quote(sender: sender, recipient: recipient, reference: reference, amount: 1000)
            let signed = try SuiSendCrypto.sign(plan, privateKey: key)
            try await track(chain: "sui", reference: reference, decimals: 9, sender: sender, recipient: recipient,
                amount: String(plan.amount), hash: signed.digest, plan: plan, signed: signed) { try await $0.reconcileSuiSend($1, client: client) }
        }
    }
}

private struct ArcLoopbackTransport:AnkrTransport {
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        var request=request;request.url=URL(string:"http://127.0.0.1:18542")!
        return try await AnkrHTTPTransport().send(request)
    }
}
