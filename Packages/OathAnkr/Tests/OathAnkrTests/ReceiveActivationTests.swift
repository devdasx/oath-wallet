import Foundation
import XCTest
@testable import OathAnkr

@MainActor final class ReceiveActivationTests: XCTestCase {
    func testConfirmedMissingAccountsUseChainSpecificGuidance() async {
        let expected: [String: ReceiveActivationRequirement] = [
            "stellar": .stellar(minimumStroops: 10_000_000), "xrpl": .xrpl(minimumDrops: 1_000_000),
            "solana": .solana(minimumLamports: 890_880), "tron": .tron, "near": .near,
            "ton": .ton(needsFunding: true)
        ]
        for (network, requirement) in expected {
            let status = await checker(network).check(network: network, address: ActivationFixture.address(network))
            XCTAssertEqual(status, .inactive(requirement), network)
        }
    }

    func testExistingZeroBalanceAccountsNeverShowActivationWarning() async {
        for network in ReceiveActivationCheck.networks {
            let status = await checker(network, mode: .active).check(network: network, address: ActivationFixture.address(network))
            XCTAssertEqual(status, .active, network)
        }
    }

    func testUnknownAndWrongNetworkNeverBecomeInactive() async {
        for network in ReceiveActivationCheck.networks {
            for mode: ActivationFixture.Mode in [.wrongNetwork, .malformed, .outage] {
                let status = await checker(network, mode: mode).check(network: network, address: ActivationFixture.address(network))
                XCTAssertEqual(status, .unavailable, "\(network): \(mode)")
            }
        }
    }

    func testChangedNetworkReservesAreUsedWithoutHardcodedAmounts() async {
        let stellar = await checker("stellar", mode: .higherReserve).check(network: "stellar", address: ActivationFixture.address("stellar"))
        let xrp = await checker("xrpl", mode: .higherReserve).check(network: "xrpl", address: ActivationFixture.address("xrpl"))
        let solana = await checker("solana", mode: .higherReserve).check(network: "solana", address: ActivationFixture.address("solana"))
        XCTAssertEqual(stellar, .inactive(.stellar(minimumStroops: 20_000_000)))
        XCTAssertEqual(xrp, .inactive(.xrpl(minimumDrops: 2_000_000)))
        XCTAssertEqual(solana, .inactive(.solana(minimumLamports: 1_200_000)))
    }

    func testNotFoundMustMatchTheRequestedAccountAndLedger() async {
        for network in ["xrpl", "near"] {
            let status = await checker(network, mode: .wrongOwner).check(network: network, address: ActivationFixture.address(network))
            XCTAssertEqual(status, .unavailable, network)
        }
        let ledger = await checker("xrpl", mode: .wrongLedger).check(network: "xrpl", address: ActivationFixture.address("xrpl"))
        XCTAssertEqual(ledger, .unavailable)
    }

    func testStellarUnrelated404IsNotAnInactiveAccount() async {
        let status = await checker("stellar", mode: .other404).check(network: "stellar", address: ActivationFixture.address("stellar"))
        XCTAssertEqual(status, .unavailable)
    }

    func testTonFundedButUndeployedDoesNotAskForMoreFundsAndFrozenIsNotNew() async {
        let funded = await checker("ton", mode: .funded).check(network: "ton", address: ActivationFixture.address("ton"))
        let frozen = await checker("ton", mode: .frozen).check(network: "ton", address: ActivationFixture.address("ton"))
        XCTAssertEqual(funded, .inactive(.ton(needsFunding: false)))
        XCTAssertEqual(frozen, .unavailable)
    }

    func testUnsupportedChainsAndNamedNearAccountsDoNotMakeRequests() async {
        let fixture = ActivationFixture(network: "near", mode: .inactive)
        let client = ReceiveActivationCheck(endpoints: ["near": ActivationFixture.url], transport: fixture)
        for network in ["bitcoin", "ethereum", "aptos", "sui", "thorchain"] {
            let status = await client.check(network: network, address: "fixture")
            XCTAssertEqual(status, .unavailable)
        }
        let named = await client.check(network: "near", address: "example.near")
        XCTAssertEqual(named, .unavailable)
        let count = await fixture.count
        XCTAssertEqual(count, 0)
    }

    func testCancellationDiscardsEvenAnOtherwiseValidResult() async {
        let fixture = ActivationFixture(network: "solana", mode: .inactive, delay: true)
        let client = ReceiveActivationCheck(endpoints: ["solana": ActivationFixture.url], transport: fixture)
        let task = Task { await client.check(network: "solana", address: ActivationFixture.address("solana")) }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .unavailable)
    }

    func testActiveAccountDoesNotRequestReserveOrEntireTokenInventory() async {
        for network in ["stellar", "solana"] {
            let fixture = ActivationFixture(network: network, mode: .active)
            let client = ReceiveActivationCheck(endpoints: [network: ActivationFixture.url], transport: fixture)
            _ = await client.check(network: network, address: ActivationFixture.address(network))
            let calls = await fixture.calls
            XCTAssertEqual(calls.count, 2, network)
            XCTAssertFalse(calls.contains("getMinimumBalanceForRentExemption"))
            XCTAssertFalse(calls.contains("ledgers"))
        }
    }

    private func checker(_ network: String, mode: ActivationFixture.Mode = .inactive) -> ReceiveActivationCheck {
        ReceiveActivationCheck(endpoints: [network: ActivationFixture.url], transport: ActivationFixture(network: network, mode: mode))
    }
}

private actor ActivationFixture: AnkrTransport {
    typealias JSON = SolanaJSON
    enum Mode { case inactive, active, wrongNetwork, malformed, outage, higherReserve, wrongOwner, wrongLedger, other404, funded, frozen }
    static let url = URL(string: "https://fixture.example")!
    static let ledgerHash = String(repeating: "A", count: 64)
    static func address(_ network: String) -> String {
        switch network {
        case "stellar": return PublicMultisigTests.stellar
        case "xrpl": return PublicMultisigTests.xrp
        case "tron": return PublicMultisigTests.tron
        case "near": return String(repeating: "a", count: 64)
        case "ton": return "0:" + String(repeating: "a", count: 64)
        default: return "11111111111111111111111111111111"
        }
    }
    let network: String
    let mode: Mode
    let delay: Bool
    var calls: [String] = []
    var count: Int { calls.count }
    init(network: String, mode: Mode, delay: Bool = false) { self.network = network; self.mode = mode; self.delay = delay }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if delay { try await Task.sleep(for: .milliseconds(30)) }
        let body = try request.httpBody.map { try JSONDecoder().decode(JSON.self, from: $0) } ?? .null
        let method = body["method"].string ?? request.url!.pathComponents.dropFirst().first ?? "root"
        calls.append(method)
        func encoded(_ value: JSON, _ status: Int = 200) throws -> (Data, Int) { (try JSONEncoder().encode(value), status) }
        func rpc(_ result: JSON) throws -> (Data, Int) {
            try encoded(.object(["jsonrpc": .string("2.0"), "id": .number("1"), "result": result]))
        }
        if mode == .outage { return try encoded(.object(["error": .string("service unavailable")]), 503) }
        if mode == .malformed { return try encoded(.object(["unexpected": .bool(true)])) }
        switch network {
        case "stellar":
            switch method {
            case "root": return try encoded(.object(["network_passphrase": .string(mode == .wrongNetwork ? "testnet" : StellarIdentity.network), "history_latest_ledger": .number("100")]))
            case "ledgers": return try encoded(.object(["sequence": .number("100"), "base_reserve_in_stroops": .number(mode == .higherReserve ? "10000000" : "5000000")]))
            default:
                if mode == .active { return try encoded(.object(["account_id": .string(Self.address(network)), "sequence": .string("1"), "balances": .array([])])) }
                return try encoded(.object(["status": .number("404"), "type": .string(mode == .other404 ? "proxy/not-found" : "https://stellar.org/horizon-errors/not_found")]), 404)
            }
        case "xrpl":
            if method == "server_info" {
                return try encoded(.object(["result": .object(["status": .string("success"), "info": .object([
                    "network_id": .number(mode == .wrongNetwork ? "1" : "0"),
                    "validated_ledger": .object(["seq": .number("100"), "hash": .string(Self.ledgerHash),
                        "reserve_base_xrp": .number(mode == .higherReserve ? "2" : "1")])])])]))
            }
            var value: [String: JSON] = ["validated": .bool(true), "ledger_hash": .string(mode == .wrongLedger ? String(repeating: "B", count: 64) : Self.ledgerHash)]
            if mode == .active {
                value["status"] = .string("success"); value["account_data"] = .object(["Account": .string(Self.address(network)), "Balance": .string("0")])
            } else {
                value["status"] = .string("error"); value["error"] = .string("actNotFound"); value["error_code"] = .number("19")
                value["account"] = .string(mode == .wrongOwner ? PublicMultisigTests.signer : Self.address(network))
            }
            return try encoded(.object(["result": .object(value)]))
        case "solana":
            switch method {
            case "getGenesisHash": return try rpc(.string(mode == .wrongNetwork ? "testnet" : SolanaIdentity.genesis))
            case "getMinimumBalanceForRentExemption": return try rpc(.number(mode == .higherReserve ? "1200000" : "890880"))
            default: return try rpc(.object(["context": .object(["slot": .number("100")]), "value": mode == .active ? .object(["lamports": .number("0"), "owner": .string(Self.address(network))]) : .null]))
            }
        case "tron":
            if request.url!.lastPathComponent == "getblockbynum" {
                return try encoded(.object(["blockID": .string(mode == .wrongNetwork ? "wrong" : TronSendNetwork.mainnet.genesisID)]))
            }
            return try encoded(mode == .active ? .object(["address": .string(Self.address(network))]) : .object([:]))
        case "near":
            if method == "EXPERIMENTAL_genesis_config" { return try rpc(.object(["chain_id": .string(mode == .wrongNetwork ? "testnet" : "mainnet")])) }
            if mode == .active { return try rpc(.object(["amount": .string("0"), "code_hash": .string("hash"), "block_height": .number("100"), "block_hash": .string("hash")])) }
            return try encoded(.object(["jsonrpc": .string("2.0"), "id": .number("1"), "error": .object([
                "code": .number("-32000"), "cause": .object(["name": .string("UNKNOWN_ACCOUNT"),
                    "info": .object(["requested_account_id": .string(mode == .wrongOwner ? "other.near" : Self.address(network))])])])]))
        case "ton":
            if method == "getMasterchainInfo" { return try rpc(.object(["init": .object(["root_hash": .string(mode == .wrongNetwork ? "testnet" : TonIdentity.genesis)])])) }
            return try rpc(.object(["state": .string(mode == .active ? "active" : mode == .frozen ? "frozen" : "uninitialized"), "balance": .string(mode == .funded ? "100000000" : "0")]))
        default: throw URLError(.unsupportedURL)
        }
    }
}
