import XCTest
@testable import OathAnkr

@MainActor final class SolanaMultisigPayerTests: XCTestCase {
    private func fixture() throws -> (SolanaSendPlan, Data) {
        let helper = SolanaMultisigTests(), f = try helper.fixture()
        let row = try XCTUnwrap(f["vectors"].array?.first { $0["kind"].string == "native" && $0["count"].integer == 5 })
        return (try helper.plan(row), try XCTUnwrap(Data(base64Encoded: XCTUnwrap(row["account"].string))))
    }

    func testEveryMemberCanFundSetupAndSendWithoutFirstMemberSOL() async throws {
        let (original, account) = try fixture(), policy = try XCTUnwrap(original.multisig?.policy)
        for member in policy.members {
            let transport = PayerRPCFixture(plan: original, account: account, balances: [member: 100_000_000])
            let client = try SolanaSendClient(network: .devnet, transport: transport)
            let state = try await client.multisigState(policy)
            XCTAssertEqual(state.payer, member)
            XCTAssertEqual(state.balance, 100_000_000)
            let send = try await client.quoteMultisig(policy, recipient: original.recipient, reference: "native", decimals: 9, amount: "1000000")
            XCTAssertEqual(send.multisig?.payer, member)
            XCTAssertEqual(send.multisig?.signingMembers.count, policy.required)
            XCTAssertTrue(send.multisig?.signingMembers.contains(member) == true)
            XCTAssertEqual(send.transactionFee, UInt64(policy.required+1)*5_000)
            try await client.preflight(send)
            await transport.setConfigured(false)
            let setup = try await client.quoteMultisigSetup(policy)
            XCTAssertEqual(setup.multisig?.payer, member)
            XCTAssertEqual(setup.multisig?.signingMembers, [member])
            XCTAssertEqual(setup.transactionFee, 10_000)
        }
    }

    func testHighestBalanceSelectionTiesAndNoFundedMember() async throws {
        let (plan, account) = try fixture(), policy = try XCTUnwrap(plan.multisig?.policy)
        let transport = PayerRPCFixture(plan: plan, account: account, balances: [:])
        let client = try SolanaSendClient(network: .devnet, transport: transport)
        let empty = try await client.multisigPayer(policy, slot: 50)
        XCTAssertEqual(empty.address, policy.payer)
        XCTAssertEqual(empty.balance, 0)
        do {
            _ = try await client.quoteMultisig(policy, recipient: plan.recipient, reference: "native", decimals: 9, amount: "1000000")
            XCTFail("No funded signer must not reach signing")
        } catch { XCTAssertEqual(error as? SolanaSendError, .multisigFunding) }
        await transport.setBalances(Dictionary(uniqueKeysWithValues: policy.members.map { ($0, UInt64(10)) }))
        let tied = try await client.multisigPayer(policy, slot: 50)
        XCTAssertEqual(tied.address, policy.payer)
        await transport.setBalances([policy.members[1]: 10, policy.members[4]: 20])
        let chosen = try await client.multisigPayer(policy, slot: 50)
        XCTAssertEqual(chosen.address, policy.members[4])
        await transport.setIneligibleMember(policy.members[4])
        let eligible = try await client.multisigPayer(policy, slot: 50)
        XCTAssertEqual(eligible.address, policy.members[1], "Do not select a token/stake account's rent as fee funds")
        await transport.setBalances([policy.payer: 100])
        await transport.setIneligibleMember(policy.payer)
        let unfunded = try await client.multisigPayer(policy, slot: 50)
        XCTAssertEqual(unfunded.address, policy.members[1], "Funding guidance must use an eligible signer")
        XCTAssertEqual(unfunded.balance, 0)
        await transport.setMalformedBalance(true)
        do { _ = try await client.multisigPayer(policy, slot: 50); XCTFail("Do not treat failed reads as zero balances") }
        catch { XCTAssertEqual(error as? SolanaSendError, .malformed) }
    }

    func testLegacyJournalAndForeignPayers() throws {
        let (plan, _) = try fixture()
        let context = try XCTUnwrap(plan.multisig)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        var metadata = try XCTUnwrap(json["multisig"] as? [String: Any])
        metadata.removeValue(forKey: "feePayer")
        json["multisig"] = metadata
        let old = try JSONDecoder().decode(SolanaSendPlan.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.multisig?.payer, context.policy.payer)
        XCTAssertEqual(try SolanaMultisigCrypto.messages(old), try SolanaMultisigCrypto.messages(plan))
        metadata["feePayer"] = context.policy.createKey
        json["multisig"] = metadata
        let foreign = try JSONDecoder().decode(SolanaSendPlan.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try SolanaMultisigCrypto.messages(foreign)) { XCTAssertEqual($0 as? SolanaSendError, .changed) }
    }

    func testChangingQuotedPayerInvalidatesExistingSignatures() throws {
        let helper = SolanaMultisigTests(), f = try helper.fixture()
        let row = try XCTUnwrap(f["vectors"].array?.first { $0["kind"].string == "native" && $0["required"].integer == 5 })
        let plan = try helper.plan(row), context = try XCTUnwrap(plan.multisig)
        let keys = try XCTUnwrap(row["seeds"].array).map { try XCTUnwrap(Data(base64Encoded: XCTUnwrap($0.string))) }
        let signed = try SolanaMultisigCrypto.sign(plan, privateKeys: keys)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        var metadata = try XCTUnwrap(json["multisig"] as? [String: Any])
        metadata["feePayer"] = context.policy.members.last!
        json["multisig"] = metadata
        let changed = try JSONDecoder().decode(SolanaSendPlan.self, from: JSONSerialization.data(withJSONObject: json))
        try changed.validate()
        XCTAssertThrowsError(try SolanaMultisigCrypto.verify(signed, plan: changed))
        XCTAssertEqual(try JSONDecoder().decode(SolanaSendPlan.self, from: JSONEncoder().encode(changed)), changed)
    }
}

private actor PayerRPCFixture: AnkrTransport {
    let plan: SolanaSendPlan
    let account: Data
    var balances: [String: UInt64]
    var configured = true
    var malformedBalance = false
    var ineligibleMember: String?
    init(plan: SolanaSendPlan, account: Data, balances: [String: UInt64]) {
        self.plan = plan; self.account = account; self.balances = balances
    }
    func setBalances(_ value: [String: UInt64]) { balances = value }
    func setConfigured(_ value: Bool) { configured = value }
    func setIneligibleMember(_ value: String?) { ineligibleMember = value }
    func setMalformedBalance(_ value: Bool) { malformedBalance = value }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        let params = try XCTUnwrap(body["params"].array), policy = try XCTUnwrap(plan.multisig?.policy)
        let result: SolanaJSON
        func wrapped(_ value: SolanaJSON) -> SolanaJSON { .object(["context": .object(["slot": .number("50")]), "value": value]) }
        func dataAccount(_ data: Data) -> SolanaJSON {
            .object(["owner": .string(SolanaMultisigPolicy.program), "executable": .bool(false), "data": .array([.string(data.base64EncodedString()), .string("base64")])])
        }
        switch body["method"].string {
        case "getGenesisHash": result = .string(SolanaSendNetwork.devnet.genesis)
        case "getMultipleAccounts":
            result = wrapped(.array(policy.members.map { member in
                if malformedBalance { return .object([:]) }
                guard let balance = balances[member] else { return .null }
                return .object(["lamports": .number(String(balance)), "owner": .string(member == ineligibleMember ? SolanaIdentity.tokenProgram : SolanaSendCrypto.system), "executable": .bool(false), "data": .array([.string(""), .string("base64")])])
            }))
        case "getBalance":
            let address = try XCTUnwrap(params.first?.string)
            result = wrapped(malformedBalance ? .null : .number(String(address == plan.sender ? 1_000_000_000 : balances[address, default: 0])))
        case "getLatestBlockhash": result = wrapped(.object(["blockhash": .string(plan.blockhash), "lastValidBlockHeight": .number("100")]))
        case "getAccountInfo":
            let address = try XCTUnwrap(params.first?.string)
            if address == SolanaMultisigPolicy.program {
                result = wrapped(.object(["executable": .bool(true), "owner": .string("BPFLoaderUpgradeab1e11111111111111111111111")]))
            } else if address == (try SolanaMultisigPolicy.programConfig) {
                let data = Data([196,210,90,231,144,149,140,63]) + Data(repeating: 0, count: 32) + SolanaSendCrypto.le(UInt64(1_000_000)) + (try SolanaSendCrypto.decode(policy.createKey))
                result = wrapped(dataAccount(data))
            } else if address == (try policy.multisig) {
                result = wrapped(configured ? dataAccount(account) : .null)
            } else { result = wrapped(.object(["owner": .string(SolanaSendCrypto.system)])) }
        case "getMinimumBalanceForRentExemption": result = .number("1000000")
        case "getFeeForMessage":
            let message = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(params.first?.string)))
            result = wrapped(.number(String(UInt64(try XCTUnwrap(message.first))*5_000)))
        case "simulateTransaction": result = wrapped(.object(["err": .null]))
        default: throw SolanaSendError.malformed
        }
        return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": .number("1"), "result": result])), 200)
    }
}
