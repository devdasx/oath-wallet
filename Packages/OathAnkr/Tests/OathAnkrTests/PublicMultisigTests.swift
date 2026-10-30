import XCTest
@testable import OathAnkr

final class PublicMultisigTests: XCTestCase {
    static let xrp = "r9cZA1mLK5R5Am25ArfXFmqgNwjZgnfk59"
    static let signer = "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"
    static let stellar = "GBEBCRCJ5VX7GERSGJ5XGJX7K2CHNVQB67K2KGCX7RFGMCBIIZQ5E4GY"
    static let tron = "TJmmqjb1DK9TTZbQXzRQ2AuA94z4gKAPFh"
    private func json(_ text: String) throws -> TronJSON { try JSONDecoder().decode(TronJSON.self, from: Data(text.utf8)) }
    private func confirmed(_ result: PublicMultisigResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .confirmed = result else { XCTFail("Expected confirmed policy", file: file, line: line); return }
    }
    func testXRPValidatedSignerListAndEnabledMaster() throws {
        let account = PublicMultisigAccount(chain: .xrpl, address: Self.xrp)
        let data = try json("""
        {"result":{"status":"success","validated":true,"account_data":{"Account":"\(Self.xrp)","Flags":0},"signer_lists":[{"SignerQuorum":1,"SignerEntries":[{"SignerEntry":{"Account":"\(Self.signer)","SignerWeight":1}}]}]}}
        """)
        confirmed(try PublicMultisigCheck.parse(data, account: account))
        var result = data["result"].fields!
        result["validated"] = .bool(false)
        XCTAssertThrowsError(try PublicMultisigCheck.parse(.object(["result": .object(result)]), account: account))
        result["validated"] = .bool(true); result["signer_lists"] = .array([])
        XCTAssertEqual(try PublicMultisigCheck.parse(.object(["result": .object(result)]), account: account), .notDetected)
        result["signer_lists"] = .array([.object(["SignerQuorum": .number("9"), "SignerEntries": data["result"]["signer_lists"].array![0]["SignerEntries"]])])
        XCTAssertThrowsError(try PublicMultisigCheck.parse(.object(["result": .object(result)]), account: account))
    }
    func testStellarWeightsNotSignerArrayLength() throws {
        let account = PublicMultisigAccount(chain: .stellar, address: Self.stellar)
        var result = try json("""
        {"account_id":"\(Self.stellar)","thresholds":{"low_threshold":1,"med_threshold":2,"high_threshold":2},"signers":[{"key":"\(Self.stellar)","weight":1,"type":"ed25519_public_key"},{"key":"GAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAWHF","weight":1,"type":"ed25519_public_key"}]}
        """).fields!
        confirmed(try PublicMultisigCheck.parse(.object(result), account: account))
        var signers = result["signers"]!.array!, master = signers[0].fields!
        master["weight"] = .number("0"); signers[0] = .object(master); result["signers"] = .array(signers)
        XCTAssertEqual(try PublicMultisigCheck.parse(.object(result), account: account), .notDetected)
        result["account_id"] = .string("wrong account")
        XCTAssertThrowsError(try PublicMultisigCheck.parse(.object(result), account: account))
    }
    func testTronOwnerAndActiveThresholds() throws {
        let account = PublicMultisigAccount(chain: .tron, address: Self.tron)
        let other = "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb"
        let keys = "[{\"address\":\"\(Self.tron)\",\"weight\":1},{\"address\":\"\(other)\",\"weight\":1}]"
        let owner = try json("""
        {"address":"\(Self.tron)","owner_permission":{"permission_name":"owner","threshold":2,"keys":\(keys)}}
        """)
        confirmed(try PublicMultisigCheck.parse(owner, account: account))
        var unnamed = owner.fields!, permission = owner["owner_permission"].fields!
        permission.removeValue(forKey: "permission_name"); unnamed["owner_permission"] = .object(permission)
        confirmed(try PublicMultisigCheck.parse(.object(unnamed), account: account))
        let active = try json("""
        {"address":"\(Self.tron)","active_permission":[{"type":"Active","id":2,"permission_name":"active","threshold":2,"operations":"0200000000000000000000000000000000000000000000000000000000000000","keys":\(keys)}]}
        """)
        confirmed(try PublicMultisigCheck.parse(active, account: account))
        let single = try json("""
        {"address":"\(Self.tron)","owner_permission":{"permission_name":"owner","threshold":1,"keys":[{"address":"\(other)","weight":1}]}}
        """)
        XCTAssertEqual(try PublicMultisigCheck.parse(single, account: account), .notDetected)
        XCTAssertEqual(try PublicMultisigCheck.parse(.object([:]), account: account), .notDetected)
    }
    func testStellarPublicSignerEncodingsAndLongestPayload() throws {
        let official = "PA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAQACAQDAQCQMBYIBEFAWDANBYHRAEISCMKBKFQXDAMRUGY4DUPB6IBZGM"
        try StellarIdentity.validateSigner(official, type: "ed25519_signed_payload")
        let longest = StellarIdentity.encode(Array(repeating: 1, count: 32) + [0, 0, 0, 64] + Array(repeating: 2, count: 64), version: 120)
        XCTAssertEqual(longest.count, 165)
        try StellarIdentity.validateSigner(longest, type: "ed25519_signed_payload")
        XCTAssertThrowsError(try StellarIdentity.validateSigner(longest, type: "ed25519_public_key"))
        XCTAssertThrowsError(try StellarIdentity.validateSigner(String(longest.dropLast()) + "A", type: "ed25519_signed_payload"))
        for (type, version) in [("preauth_tx", UInt8(152)), ("sha256_hash", UInt8(184))] {
            try StellarIdentity.validateSigner(StellarIdentity.encode(Array(repeating: 1, count: 32), version: version), type: type)
        }
    }
    func testAptosResourceProofAndThresholdValidation() throws {
        let account = PublicMultisigAccount(chain: .aptos, address: "0x123")
        let valid = try json("""
        {"type":"0x1::multisig_account::MultisigAccount","data":{"owners":["0x1","0x2"],"num_signatures_required":"2"}}
        """)
        confirmed(try PublicMultisigCheck.parse(valid, account: account))
        let duplicate = try json("""
        {"type":"0x1::multisig_account::MultisigAccount","data":{"owners":["0x1","0x01"],"num_signatures_required":"2"}}
        """)
        XCTAssertThrowsError(try PublicMultisigCheck.parse(duplicate, account: account))
        // An account authentication key hash is not a multisig resource.
        XCTAssertThrowsError(try PublicMultisigCheck.parse(try json("{\"authentication_key\":\"0x123\"}"), account: account))
    }
    func testCoalescesAndCachesFailuresWithoutFalsePositive() async throws {
        let transport = MultisigTestTransport(data: Data("{\"error\":\"unavailable\"}".utf8), status: 503)
        let checker = PublicMultisigCheck(transport: transport)
        let account = PublicMultisigAccount(chain: .xrpl, address: Self.xrp)
        let results = await withTaskGroup(of: PublicMultisigResult.self) { group in
            for _ in 0..<12 { group.addTask { await checker.check(account) } }
            var values: [PublicMultisigResult] = []
            for await item in group { values.append(item) }
            return values
        }
        XCTAssertEqual(results, Array(repeating: .unavailable, count: 12))
        let cached = await checker.check(account), calls = await transport.calls
        XCTAssertEqual(cached, .unavailable); XCTAssertEqual(calls, 1)
    }
    func testAbsentResourceIsNormalButMalformed404IsFailure() async throws {
        for (json, expected) in [("{\"error_code\":\"resource_not_found\"}", PublicMultisigResult.notDetected), ("{}", .unavailable)] {
            let checker = PublicMultisigCheck(transport: MultisigTestTransport(data: Data(json.utf8), status: 404))
            let result = await checker.check(.init(chain: .aptos, address: "0x123"))
            XCTAssertEqual(result, expected)
        }
    }
    func testRequestsContainOnlyPublicReadMethods() throws {
        for testnet in [false, true] {
            for (chain, address) in [(PublicMultisigChain.xrpl, Self.xrp), (.stellar, Self.stellar), (.tron, Self.tron), (.aptos, "0x123")] {
                let request = try PublicMultisigCheck.request(.init(chain: chain, address: address, testnet: testnet))
                XCTAssertEqual(request.url?.scheme, "https"); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8)!
                XCTAssertFalse(body.contains("private")); XCTAssertFalse(body.contains("mnemonic")); XCTAssertFalse(body.contains("sign_transaction"))
                if chain == .xrpl { XCTAssertTrue(body.contains("account_info")) }
                if chain == .tron { XCTAssertEqual(request.url?.path, "/walletsolidity/getaccount") }
            }
        }
    }
    func testLivePublicAccountsReadOnly() async throws {
        guard let path = ProcessInfo.processInfo.environment["OATH_MULTISIG_PUBLIC_FIXTURES"] else { throw XCTSkip("Opt-in public network checks; no keys or broadcast") }
        struct Fixture: Decodable { let chain: String; let address: String; let testnet: Bool; let multisig: Bool }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        for fixture in fixtures {
            let chain = try XCTUnwrap(PublicMultisigChain(rawValue: fixture.chain))
            let result = await PublicMultisigCheck().check(.init(chain: chain, address: fixture.address, testnet: fixture.testnet))
            if fixture.multisig { confirmed(result) } else { XCTAssertEqual(result, .notDetected, "\(fixture.chain) public account check") }
            let matched: Bool
            switch result { case .confirmed: matched = fixture.multisig; case .notDetected: matched = !fixture.multisig; case .unavailable: matched = false }
            print("PUBLIC_MULTISIG chain=\(fixture.chain) testnet=\(fixture.testnet) expectedMultisig=\(fixture.multisig) matched=\(matched)")
        }
    }
}
private actor MultisigTestTransport: AnkrTransport {
    let data: Data; let status: Int; var calls = 0
    init(data: Data, status: Int) { self.data = data; self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        try await Task.sleep(for: .milliseconds(30))
        return (data, status)
    }
}
