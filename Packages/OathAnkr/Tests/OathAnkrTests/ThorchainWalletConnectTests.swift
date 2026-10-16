import XCTest
@testable import OathAnkr

@MainActor final class ThorchainWalletConnectTests: XCTestCase {
    struct Vector: Decodable {
        let kind: String, method: String, sender: String, publicKey: String, signBytes: String
        let recipient: String?
        let params: SolanaJSON, response: SolanaJSON
        func request(_ changed: SolanaJSON? = nil) throws -> ThorchainWalletConnectRequest {
            try .init(method: method, params: changed ?? params, sender: sender, publicKey: Data(base64Encoded: publicKey)!)
        }
    }
    func vectors() throws -> [Vector] {
        let url = Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Fixtures/ThorchainWalletConnect")!
        return try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
    }
    func replacing(_ value: SolanaJSON, path: [String], with replacement: SolanaJSON?) -> SolanaJSON {
        guard let first = path.first, case .object(var fields) = value else { return value }
        fields[first] = path.count == 1 ? replacement : replacing(fields[first]!, path: Array(path.dropFirst()), with: replacement)
        return .object(fields)
    }
    func testCosmJSInteropAminoDirectTransfersDepositsTokensAndZeroNumbers() throws {
        for v in try vectors() {
            let request = try v.request()
            XCTAssertEqual(request.signBytes, Data(base64Encoded: v.signBytes), v.method + v.kind)
            XCTAssertEqual(request.recipient, v.recipient)
            XCTAssertEqual(try request.sign(privateKey: Data(repeating: 1, count: 32)), v.response, v.method + v.kind)
            XCTAssertEqual(request.coins.first?.reference, v.kind == "token" ? "x/oath-test" : "native")
            XCTAssertThrowsError(try request.sign(privateKey: Data(repeating: 2, count: 32)))
        }
    }
    func testAminoRejectsHiddenAuthorityAndAmbiguousFields() throws {
        let v = try vectors().first!
        let cases: [([String], SolanaJSON?)] = [
            (["signerAddress"], .string("thor1wrong")),
            (["extra"], .bool(true)),
            (["signDoc", "chain_id"], .string("cosmoshub-4")),
            (["signDoc", "account_number"], .string("01")),
            (["signDoc", "sequence"], .number("7")),
            (["signDoc", "fee", "payer"], .string(v.sender)),
            (["signDoc", "fee", "granter"], .string(v.sender)),
            (["signDoc", "fee", "amount"], .array([.object(["denom": .string("rune"), "amount": .string("1")])])),
            (["signDoc", "memo"], .string("safe\u{202e}hidden")),
            (["signDoc", "memo"], .string(String(repeating: "x", count: 251))),
            (["signDoc", "timeout_height"], .null),
            (["signDoc", "msgs"], .array(v.params["signDoc"]["msgs"].array! + v.params["signDoc"]["msgs"].array!)),
            (["signDoc", "memo"], nil)
        ]
        for (path, value) in cases { XCTAssertThrowsError(try v.request(replacing(v.params, path: path, with: value)), path.joined(separator: "/")) }
        var message = v.params["signDoc"]["msgs"].array!.first!
        message = replacing(message, path: ["type"], with: .string("cosmos-sdk/MsgGrant"))
        XCTAssertThrowsError(try v.request(replacing(v.params, path: ["signDoc", "msgs"], with: .array([message]))))
        for v in try vectors().filter({ $0.method == "cosmos_signAmino" && $0.kind == "deposit" }) {
            let msg = v.params["signDoc"]["msgs"].array!.first!
            let bad = replacing(msg, path: ["value", "coins"], with: .array([.object(["asset": .string("ETH.ETH"), "amount": .string("1")])]))
            XCTAssertThrowsError(try v.request(replacing(v.params, path: ["signDoc", "msgs"], with: .array([bad]))))
        }
    }
    func testDirectRejectsExtensionsMultipleSignersWrongKeysAndInvalidWire() throws {
        let v = try vectors().first { $0.method == "cosmos_signDirect" }!
        let body = Data(base64Encoded: v.params["signDoc"]["bodyBytes"].string!)!
        let auth = Data(base64Encoded: v.params["signDoc"]["authInfoBytes"].string!)!
        for (field, bytes) in [("bodyBytes", body + TronSendCrypto.field(1023, Data([1]))),
                               ("bodyBytes", body + body),
                               ("bodyBytes", Data([0x80])),
                               ("authInfoBytes", auth + auth),
                               ("authInfoBytes", auth + TronSendCrypto.field(3, Data([1])))] {
            XCTAssertThrowsError(try v.request(replacing(v.params, path: ["signDoc", field], with: .string(bytes.base64EncodedString()))))
        }
        var badAuth = auth
        let pub = Data(base64Encoded: v.publicKey)!
        let range = badAuth.range(of: pub)!
        badAuth.replaceSubrange(range, with: try ThorchainSendCrypto.publicKey(privateKey: Data(repeating: 2, count: 32)))
        XCTAssertThrowsError(try v.request(replacing(v.params, path: ["signDoc", "authInfoBytes"], with: .string(badAuth.base64EncodedString()))))
        XCTAssertThrowsError(try v.request(replacing(v.params, path: ["signDoc", "accountNumber"], with: .string("18446744073709551616"))))
        XCTAssertThrowsError(try ThorchainWalletConnectRequest(method: v.method, params: v.params, sender: v.sender, publicKey: pub, network: .localTestnet))
    }
}


extension ThorchainWalletConnectTests {
    func testIsolatedTHORNodeExecutesWalletConnectSignatures() async throws {
        guard let path = ProcessInfo.processInfo.environment["OATH_THORCHAIN_SEND_FIXTURE"] else { throw XCTSkip("Opt-in isolated THORNode; never uses app wallets") }
        struct Fixture: Decodable { let privateKey: String, sender: String, publicKey: String, recipient: String }
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let client = try ThorchainSendClient(network: .localTestnet, localAPI: URL(string: "http://127.0.0.1:28317")!, localRPC: URL(string: "http://127.0.0.1:28657")!)
        func rpc(_ method: String, _ params: [String: String]) async throws -> SolanaJSON {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:28657")!)
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return try JSONDecoder().decode(SolanaJSON.self, from: data)
        }
        var evidence = [[String: String]]()
        for method in ["cosmos_signAmino", "cosmos_signDirect"] {
            for kind in ["native", "x/oath-test", "deposit"] {
                let isDeposit = kind == "deposit", reference = kind == "x/oath-test" ? kind : "native"
                let p = try await client.quote(sender: f.sender, recipient: f.recipient, reference: reference, publicKey: TronIdentity.hex(f.publicKey), decimals: reference == "native" ? 8 : 6, amount: "123456")
                let before = try await client.balance(owner: f.recipient, reference: reference)
                let senderBefore = try await client.balance(owner: f.sender, reference: reference)
                let nativeBefore = try await client.balance(owner: f.sender, reference: "native")
                func text(_ tag: UInt64, _ s: String) -> Data { TronSendCrypto.field(tag, Data(s.utf8)) }
                let depositCoin = TronSendCrypto.field(1, text(1,"THOR") + text(2,"RUNE") + text(3,"RUNE")) + text(2,p.amount)
                let deposit = try TronSendCrypto.field(1, depositCoin) + text(2,"RESERVE") + TronSendCrypto.field(3,ThorchainSendCrypto.addressBytes(p.sender,network:p.network))
                let body = isDeposit ? TronSendCrypto.field(1,text(1,"/types.MsgDeposit") + TronSendCrypto.field(2,deposit)) : try ThorchainSendCrypto.body(p)
                var auth = ThorchainSendCrypto.auth(p)
                let doc: SolanaJSON
                if method == "cosmos_signDirect" {
                    doc = .object(["chainId": .string(p.network.chainID), "accountNumber": .string(String(p.accountNumber)), "bodyBytes": .string(body.base64EncodedString()), "authInfoBytes": .string(auth.base64EncodedString())])
                } else {
                    let message: SolanaJSON = isDeposit ? .object(["type": .string("thorchain/MsgDeposit"), "value": .object(["signer": .string(p.sender), "memo": .string("RESERVE"), "coins": .array([.object(["asset": .string("THOR.RUNE"), "amount": .string(p.amount)])])])]) : .object(["type": .string("thorchain/MsgSend"), "value": .object(["from_address": .string(p.sender), "to_address": .string(p.recipient), "amount": .array([.object(["denom": .string(p.denom), "amount": .string(p.amount)])])])])
                    var fields: [String: SolanaJSON] = ["chain_id": .string(p.network.chainID), "account_number": .string(String(p.accountNumber)), "sequence": .string(String(p.sequence)), "fee": .object(["gas": .string(String(ThorchainSendPlan.gasLimit)), "amount": .array([])]), "memo": .string(p.memo), "msgs": .array([message])]
                    if !isDeposit { fields["timeout_height"] = .string(String(p.timeoutHeight)) }
                    doc = .object(fields)
                    let key = text(1,"/cosmos.crypto.secp256k1.PubKey") + TronSendCrypto.field(2,TronSendCrypto.field(1,p.publicKey))
                    let mode = TronSendCrypto.field(1,TronSendCrypto.number(1,127))
                    let signer = TronSendCrypto.field(1,key) + TronSendCrypto.field(2,mode) + TronSendCrypto.number(3,p.sequence)
                    auth = TronSendCrypto.field(1,signer) + TronSendCrypto.field(2,TronSendCrypto.number(2,ThorchainSendPlan.gasLimit))
                }
                let request = try ThorchainWalletConnectRequest(method: method, params: .object(["signerAddress": .string(p.sender), "signDoc": doc]), sender: p.sender, publicKey: p.publicKey, network: .localTestnet)
                let review = try await client.walletConnectReview(request)
                let result = try request.sign(privateKey: TronIdentity.hex(f.privateKey))
                let signature = try XCTUnwrap(result["signature"]["signature"].string.flatMap { Data(base64Encoded: $0) })
                let tx = TronSendCrypto.field(1,body) + TronSendCrypto.field(2,auth) + TronSendCrypto.field(3,signature)
                let submitted = try await rpc("broadcast_tx_sync", ["tx": tx.base64EncodedString()])
                XCTAssertEqual(submitted["result"]["code"], .number("0"))
                let hash = try XCTUnwrap(submitted["result"]["hash"].string)
                var receipt: SolanaJSON = .null
                for _ in 0..<30 {
                    try await Task.sleep(for: .seconds(1))
                    receipt = try await rpc("tx", ["hash": try TronIdentity.hex(hash).base64EncodedString()])
                    if !receipt["result"]["height"].isNull { break }
                }
                XCTAssertEqual(receipt["result"]["tx_result"]["code"], .number("0"), method + kind)
                let senderAfter = try await client.balance(owner: f.sender, reference: reference)
                let nativeAfter = try await client.balance(owner: f.sender, reference: "native")
                let recipientAfter = try await client.balance(owner: f.recipient, reference: reference)
                XCTAssertEqual(try ThorchainSendAmount.subtract(senderBefore,senderAfter), try ThorchainSendAmount.add(p.amount,reference == "native" ? String(review.fee) : "0"))
                XCTAssertEqual(try ThorchainSendAmount.subtract(nativeBefore,nativeAfter), try ThorchainSendAmount.add(reference == "native" ? p.amount : "0",String(review.fee)))
                XCTAssertEqual(try ThorchainSendAmount.subtract(recipientAfter,before),isDeposit ? "0" : p.amount)
                evidence.append(["method": method, "kind": kind, "hash": hash, "fee": String(review.fee)])
            }
        }
        try JSONEncoder().encode(evidence).write(to: URL(fileURLWithPath: "/tmp/oath-thor-wc-node-evidence.json"))
    }
}
