import Foundation
import Testing
@testable import Aperture

/// Explicit opt-in mainnet reads. No secrets, balances, signing or broadcasts.
@Suite(.timeLimit(.minutes(3)), .enabled(if: ProcessInfo.processInfo.environment["APERTURE_LIVE_STABLECOIN_TESTS"] == "1"))
struct StablecoinBlacklistLiveTests {
    // These real contracts blacklist their own addresses. This is not a claim
    // that an unrelated user address was positively observed on every network.
    static let observedSelfBlacklist: Set<String> = [
        "0xdac17f958d2ee523a2206206994597c13d831ec7", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        "0xaf88d065e77c8cc2239327c5edb3a432268e5831", "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359", "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
        "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e", "0x2a22f9c3b484c3629090feed35f17ff8f88f76f0",
        "0x176211869ca2b568f2a7d4ee941e073a821ee1ff", "0x06efdbff2a14a7c8e15944d1f4a48f9f95f663a4",
        "0xb6ceceab302e2e4948951ee7843fc24e92933061", "0x74b7f16337b8972027f6196a17a631ac6de26d22",
        "0xf1815bd50389c46847f0bda824ec8da914045d14", "0x07d83526730c7438048d55a4fc0b850e2aab6f0b",
        "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8"
    ]

    @Test
    func realMainnetRequestsThroughProductionClient() async {
        let targets = StablecoinBlacklistRegistry.all.filter { $0.method != nil }
        let client = StablecoinBlacklistClient()
        // Bound requests rather than flooding public RPCs with parallel tests.
        for start in stride(from: 0, to: targets.count, by: 4) {
            await withTaskGroup(of: Void.self) { group in
                for target in targets[start..<min(start + 4, targets.count)] {
                    group.addTask {
                        let address = target.networkID == "tron"
                            ? "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb" : StablecoinBlacklistTests.address
                        do {
                            #expect(try await !client.check(target: target, address: address), "\(target.networkID) \(target.symbol) negative")
                            if Self.observedSelfBlacklist.contains(target.contract) {
                                #expect(try await client.check(target: target, address: target.contract), "\(target.networkID) \(target.symbol) positive")
                            }
                            let unsupportedMethod = StablecoinBlacklistTarget(
                                networkID: target.networkID, chainID: target.chainID, symbol: target.symbol,
                                contract: target.contract, method: target.method == .circle ? .tether : .circle,
                                endpoint: target.endpoint, fallbackEndpoints: target.fallbackEndpoints
                            )
                            do {
                                _ = try await client.check(target: unsupportedMethod, address: address)
                                Issue.record("Unsupported getter unexpectedly succeeded: \(target.networkID) \(target.symbol)")
                            } catch {
                                #expect(!(error is CancellationError))
                            }
                        } catch {
                            Issue.record(error, "Mainnet check failed: \(target.networkID) \(target.symbol)")
                        }
                    }
                }
            }
        }
    }
}
