import Foundation
import XCTest
@testable import OathAnkr

/// Opt-in public reads. No user wallets, seeds, balances, signatures or writes.
@MainActor final class StablecoinRestrictionLiveTests: XCTestCase {
    func testAuthenticatedTronPolicyReadsInParallel() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_RESTRICTION_KEY"], !key.isEmpty else { throw XCTSkip("Opt-in public TRON policy probe") }
        let checker = StablecoinRestrictionCheck(endpoints: ["tron": URL(string: "https://rpc.ankr.com/premium-http/tron")!.appendingPathComponent(key)])
        let assets = StablecoinRestrictionRegistry.tokens(network: "tron")
        let results = await withTaskGroup(of: [StablecoinRestrictionResult].self) { group in
            for _ in 0..<3 {
                group.addTask {
                    await checker.check(.init(network: "tron", address: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"), tokens: assets)
                }
            }
            var values: [StablecoinRestrictionResult] = []
            for await result in group { values += result }
            return values
        }
        XCTAssertEqual(results.count, 6)
        XCTAssertTrue(results.allSatisfy { $0.outcome != .unavailable })
    }

    func testClioPublicUnfundedHolder() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_XRPL_ABSENCE"] == "1" else { throw XCTSkip("Opt-in public XRPL absence probe") }
        let checker = StablecoinRestrictionCheck(endpoints: ["xrpl": URL(string: "https://s1.ripple.com:51234")!])
        let results = await checker.check(.init(network: "xrpl", address: "rh58Qu1geRrc8ieM7DhMbyxou8jgbHtxM7"),
                                          tokens: StablecoinRestrictionRegistry.tokens(network: "xrpl"))
        XCTAssertEqual(results.map(\.outcome), [.notDetected])
    }

    func testMainnetAdapters() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_RESTRICTION_KEY"], !key.isEmpty else {
            throw XCTSkip("Run Tools/CheckStablecoinRestrictionsLive.py --run for public mainnet probes")
        }
        let paths = ["ethereum": "eth", "arbitrum": "arbitrum", "avalanche": "avalanche", "base": "base",
                     "hyperevm": "hyperevm", "linea": "linea", "monad": "monad_mainnet", "optimism": "optimism",
                     "polygon": "polygon", "unichain": "unichain_mainnet", "xlayer": "xlayer", "flare": "flare", "solana": "solana"]
        var endpoints = paths.mapValues { URL(string: "https://rpc.ankr.com/\($0)")!.appendingPathComponent(key) }
        endpoints["arc"] = URL(string: "https://rpc.blockdaemon.mainnet.arc.io")
        endpoints["tron"] = URL(string: "https://rpc.ankr.com/premium-http/tron")!.appendingPathComponent(key)
        endpoints["near"] = URL(string: "https://rpc.mainnet.near.org")
        endpoints["aptos"] = URL(string: "https://api.mainnet.aptoslabs.com/v1")
        endpoints["stellar"] = URL(string: "https://horizon.stellar.org")
        endpoints["xrpl"] = URL(string: "https://s1.ripple.com:51234")
        endpoints["sui"] = URL(string: "https://graphql.mainnet.sui.io/graphql")
        endpoints["ton"] = URL(string: "https://rpc.ankr.com/ton_api_v2")!.appendingPathComponent(key)
        let owners = [
            "solana": SolanaIdentity.wrappedSOL,
            "tron": "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
            "near": "wrap.near", "aptos": "0x1", "sui": "0x1", "ton": TonIdentity.usdt,
            "stellar": "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN",
            "xrpl": "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
        ]
        let checker = StablecoinRestrictionCheck(endpoints: endpoints)
        let networks = Array(Set(StablecoinRestrictionRegistry.tokens.map(\.network))).sorted()
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
                print("PUBLIC RESTRICTION PROBE \(result.token.network) \(result.token.symbol): \(result.outcome.rawValue)")
                // Real addresses can be blocklisted (including burn/system
                // addresses). Test that the adapter resolves current state;
                // do not assert that a public fixture must stay unblocked.
                XCTAssertNotEqual(result.outcome, .unavailable, "\(result.token.network) \(result.token.symbol)")
            }
        }
    }
    func testPublishedCircleBlocklistedAddress() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_RESTRICTION_KEY"], !key.isEmpty else { throw XCTSkip("Opt-in mainnet read") }
        // circlefin/stablecoin-evm/test.blacklist.remote.json, public test vector.
        let checker = StablecoinRestrictionCheck(endpoints: ["ethereum": URL(string: "https://rpc.ankr.com/eth")!.appendingPathComponent(key)])
        let token = StablecoinRestrictionRegistry.tokens.first { $0.network == "ethereum" && $0.symbol == "USDC" }!
        let results = await checker.check(.init(network: "ethereum", address: "0x04DBA1194ee10112fE6C3207C0687DEf0e78baCf"), tokens: [token])
        print("PUBLIC RESTRICTION PROBE Ethereum USDC issuer-published blocklist fixture: \(results[0].outcome.rawValue)")
        XCTAssertEqual(results[0].outcome, .restricted)
    }
}
