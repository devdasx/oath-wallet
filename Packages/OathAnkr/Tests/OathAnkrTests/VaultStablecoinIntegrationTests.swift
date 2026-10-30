import Foundation
import XCTest
@testable import OathAnkr

@MainActor final class VaultStablecoinIntegrationTests: XCTestCase {
    private func token(_ network: String, _ symbol: String) throws -> StablecoinRestrictionToken {
        try XCTUnwrap(StablecoinRestrictionRegistry.tokens.first { $0.network == network && $0.symbol == symbol })
    }
    func testEVMRequiresExactContractAndArcNativeAlias() throws {
        let usdt = try token("ethereum", "USDT"), usdc = try token("ethereum", "USDC")
        XCTAssertTrue(usdt.matchesAsset(reference: usdt.reference.uppercased()))
        XCTAssertFalse(usdt.matchesAsset(reference: usdc.reference))
        XCTAssertFalse(usdt.matchesAsset(reference: "USDT"))
        XCTAssertFalse(usdc.matchesAsset(reference: "native"))
        XCTAssertTrue(try token("arc", "USDC").matchesAsset(reference: "native"))
        XCTAssertTrue(try token("arbitrum", "USDT0").matchesAsset(reference: token("arbitrum", "USDT0").reference))
    }
    func testSolanaAndTronReferencesRemainCaseSensitive() throws {
        for network in ["solana", "tron"] {
            let usdt = try token(network, "USDT")
            XCTAssertTrue(usdt.matchesAsset(reference: usdt.reference))
            XCTAssertFalse(usdt.matchesAsset(reference: usdt.reference.lowercased()))
            XCTAssertFalse(usdt.matchesAsset(reference: try token(network, "USDC").reference))
        }
    }
    func testStellarAssetContractNotIssuerOrTicker() throws {
        let usdc = try token("stellar", "USDC")
        let contract = try StellarIdentity.contract(code: "USDC", issuer: usdc.reference)
        XCTAssertTrue(usdc.matchesAsset(reference: contract))
        XCTAssertFalse(usdc.matchesAsset(reference: usdc.reference))
        XCTAssertFalse(usdc.matchesAsset(reference: StellarIdentity.nativeContract))
        XCTAssertFalse(usdc.matchesAsset(reference: try StellarIdentity.contract(code: "FAKE", issuer: usdc.reference)))
    }
    func testXRPLCurrencyAndIssuerBothMatch() throws {
        let usdc = try token("xrpl", "USDC")
        let code = "5553444300000000000000000000000000000000"
        XCTAssertTrue(usdc.matchesAsset(reference: code + "." + usdc.reference))
        XCTAssertFalse(usdc.matchesAsset(reference: "USD." + usdc.reference))
        XCTAssertFalse(usdc.matchesAsset(reference: code + ".rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"))
    }
    func testMoveTypesAndInvalidAddressesNeverMatch() throws {
        let sui = try token("sui", "USDC")
        XCTAssertTrue(sui.matchesAsset(reference: sui.reference))
        XCTAssertFalse(sui.matchesAsset(reference: sui.reference.lowercased()))
        for network in ["aptos", "sui", "ton"] {
            XCTAssertFalse(StablecoinRestrictionAccount(network: network, address: "invalid")
                .matchesOwner(network: network, address: "invalid"))
            let value = try token(network, network == "ton" ? "USDT" : "USDC")
            XCTAssertTrue(value.matchesAsset(reference: value.reference))
            XCTAssertFalse(value.matchesAsset(reference: "invalid"))
        }
    }
    func testOwnerAndNetworkScopesPreventCrossWalletMarks() {
        let owner = "0x00000000000000000000000000000000000000aA"
        let account = StablecoinRestrictionAccount(network: "ethereum", address: owner)
        XCTAssertTrue(account.matchesOwner(network: "eth", address: owner.lowercased()))
        XCTAssertFalse(account.matchesOwner(network: "base", address: owner))
        XCTAssertFalse(account.matchesOwner(network: "eth", address: "0x0000000000000000000000000000000000000001"))
    }
    func testAllOathRegistryNetworksHaveVaultProviders() {
        for network in Set(StablecoinRestrictionRegistry.tokens.map(\.network)) {
            XCTAssertEqual(StablecoinRestrictionCheck.publicMainnetEndpoints[network]?.scheme, "https", network)
        }
    }
    func testTONCenterEnvelopeIsStrictAndProviderScoped() async throws {
        let url = URL(string: "https://toncenter.com/api/v2/jsonRPC")!
        let good = StablecoinRestrictionCheck(endpoints: [:], transport:
            VaultRestrictionFixtureTransport(json: #"{"ok":true,"result":{"state":"active"}}"#))
        let result = try await good.rpc(url, "getAddressInformation")
        XCTAssertEqual(result["state"].string, "active")
        for raw in [#"{"ok":false,"result":{"state":"active"}}"#, #"{"ok":true}"#, #"{"ok":"true","result":{}}"#] {
            let bad = StablecoinRestrictionCheck(endpoints: [:], transport: VaultRestrictionFixtureTransport(json: raw))
            do { _ = try await bad.rpc(url, "getAddressInformation"); XCTFail("Invalid envelope accepted") }
            catch { XCTAssertTrue(error is StablecoinRestrictionCheck.Failure) }
        }
        do {
            _ = try await good.rpc(URL(string: "https://fixture.example")!, "getAddressInformation")
            XCTFail("TON envelope accepted for another provider")
        } catch { XCTAssertTrue(error is StablecoinRestrictionCheck.Failure) }
    }
    func testLivePublishedBlocklistedAddressAndClearAddress() async throws {
        guard ProcessInfo.processInfo.environment["RUN_VAULT_RESTRICTION_LIVE"] == "yes" else {
            throw XCTSkip("Opt-in public read, no user wallets")
        }
        let usdc = try token("ethereum", "USDC")
        let checker = StablecoinRestrictionCheck.publicMainnet()
        // Issuer-published public fixture, not a user address.
        let blocked = await checker.check(.init(network: "ethereum",
            address: "0x04DBA1194ee10112fE6C3207C0687DEf0e78baCf"), tokens: [usdc])
        XCTAssertEqual(blocked.first?.outcome, .restricted)
        let clear = await checker.check(.init(network: "ethereum",
            address: "0x0000000000000000000000000000000000000001"), tokens: [usdc])
        XCTAssertEqual(clear.first?.outcome, .notDetected)
    }
    func testLivePublicMainnetAdapters() async throws {
        guard ProcessInfo.processInfo.environment["RUN_VAULT_RESTRICTION_ADAPTERS"] == "yes" else {
            throw XCTSkip("Opt-in public provider compatibility checks")
        }
        let owners = [
            "solana": SolanaIdentity.wrappedSOL,
            "tron": "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
            "near": "wrap.near", "aptos": "0x1", "sui": "0x1", "ton": TonIdentity.usdt,
            "stellar": "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN",
            "xrpl": "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
        ]
        let checker = StablecoinRestrictionCheck.publicMainnet()
        let selected = ProcessInfo.processInfo.environment["VAULT_RESTRICTION_NETWORKS"]?
            .split(separator: ",").map(String.init)
        let networks = Array(Set(StablecoinRestrictionRegistry.tokens.map(\.network)))
            .filter { selected == nil || selected!.contains($0) }.sorted()
        for start in stride(from: 0, to: networks.count, by: 3) {
            let results = await withTaskGroup(of: [StablecoinRestrictionResult].self) { group in
                for network in networks[start..<min(start + 3, networks.count)] {
                    group.addTask {
                        await checker.check(.init(network: network, address: owners[network] ?? "0x0000000000000000000000000000000000000001"),
                                            tokens: StablecoinRestrictionRegistry.tokens(network: network))
                    }
                }
                var results: [StablecoinRestrictionResult] = []
                for await result in group { results += result }
                return results
            }
            for result in results.sorted(by: { $0.token.id < $1.token.id }) {
                print("VAULT PUBLIC RESTRICTION PROBE \(result.token.network) \(result.token.symbol): \(result.outcome.rawValue)")
                // Real addresses can be blocklisted (including burn/system
                // addresses). Test that the adapter resolves current state;
                // do not assert that a public fixture must stay unblocked.
                XCTAssertNotEqual(result.outcome, .unavailable, "\(result.token.network) \(result.token.symbol)")
            }
        }
    }
}

private struct VaultRestrictionFixtureTransport: AnkrTransport {
    let json: String
    func send(_ request: URLRequest) async throws -> (Data, Int) { (Data(json.utf8), 200) }
}
