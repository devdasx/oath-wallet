import Foundation

@main struct Regression {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func main() async throws {
        for (input, expected) in [
            ("0.000000000003152", "$0.00000000"),
            ("0.000000019", "$0.00000001"),
            ("0.009999999", "$0.00999999"),
            ("0.0012", "$0.00120000")
        ] {
            check(EnglishNumbers.unitPrice(Decimal(string: input)!,
                using: WalletCurrencyContext(code: "USD", ratePerUSD: 1)) == expected,
                "Small unit price must truncate to eight places: \(input)")
        }
        check(EnglishNumbers.unitPrice(1, using: WalletCurrencyContext(code: "USD", ratePerUSD: 1))
            == "$1.00", "Ordinary unit price formatting changed")
        check(EnglishNumbers.unitPrice(Decimal(string: "0.000000019")!,
            using: WalletCurrencyContext(code: "EUR", ratePerUSD: 2))
            .contains("0.00000003"), "Currency conversion must precede truncation")
        print("PASS: eight-place truncation, zero padding, currency conversion and ordinary-price formatting")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PriceFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let contract = "0xac531eb26ca1d21b85126de8fb87e80e09002dcf"
        let sand = WalletAsset(id: "base:" + contract, network: .base)
        for chain in WalletBlockchain.allCases where ![.bitcoin, .bitcoincash, .litecoin, .dogecoin].contains(chain) {
            let id = ReceiveNetworkCatalog.catalogNetwork(for: chain)!.id
            let asset = WalletAsset(id: id + ":" + contract, network: chain)
            check(!AssetPriceClient.tokenPriceAttempts(asset: asset, stage: .dex,
                serviceID: "matrix", session: session).isEmpty, "No DEX stage for \(chain)")
        }
        for mode in [PriceFixtureProtocol.Mode.dex, .fallback, .wrongChain, .gecko] {
            PriceFixtureProtocol.install(mode)
            let price = try await AssetPriceClient.fetchPrice(for: sand, session: session)
            let hosts = PriceFixtureProtocol.requests().map { $0.host! }
            let dexHosts: Set<String> = ["api.dexscreener.com", "api.geckoterminal.com"]
            switch mode {
            case .dex:
                check(price.price == Decimal(string: "0.000000000003152")!, "Incorrect SAND quote")
                check(hosts.allSatisfy { dexHosts.contains($0) }, "Aggregator ran despite DEX success")
                let value = price.price * Decimal(string: "138295198634.16446765731119248")!
                check(value > Decimal(string: "0.43")! && value < Decimal(string: "0.44")!, "Inflated total")
            case .gecko:
                check(price.provider == AssetPriceClient.geckoTerminalContractPriceProvider, "Gecko DEX fallback missing")
                check(hosts.allSatisfy { dexHosts.contains($0) }, "Aggregator ran despite Gecko success")
            default:
                check(price.price == Decimal(string: "0.025")!, "Exact contract fallback failed")
                check(hosts.prefix(2).allSatisfy { dexHosts.contains($0) }, "Aggregator preceded DEX stage")
            }
            check(!PriceFixtureProtocol.requests().contains { $0.path == "/api/v3/simple/price" }, "Market ID token fallback")
        }
        let solana = WalletAsset(id: "solana:EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", network: .solana)
        for (asset, mode) in [(sand, PriceFixtureProtocol.Mode.reject), (solana, .wrongMint)] {
            PriceFixtureProtocol.install(mode)
            do {
                _ = try await AssetPriceClient.fetchPrice(for: asset, session: session)
                preconditionFailure("Accepted unavailable or mismatched token quote")
            } catch { check(error is AssetPriceError, "Unexpected error") }
            check(!PriceFixtureProtocol.requests().contains { $0.path == "/api/v3/simple/price" }, "Catalog bypass")
        }
        PriceFixtureProtocol.install(.dex)
        do {
            _ = try await AssetPriceClient.fetchPrice(for: WalletAsset(id: sand.id, network: .ethereum), session: session)
            preconditionFailure("Accepted chain/asset-ID mismatch")
        } catch { check(PriceFixtureProtocol.requests().isEmpty, "Mismatched identity sent to provider") }
        for provider in ["coingecko", "coingecko-contract-v2", "ankr_getTokenPrice", "defillama-market-v1", "tonapi"] {
            let quote = AssetUSDPrice(assetID: sand.id, price: 1, provider: provider, observedAt: Date())
            check(!AssetPriceClient.cachedPriceIsReusable(quote, for: sand), "Legacy cache accepted")
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AssetPriceClient.fetchTokenPrice(for: sand, session: session)
        }
        do { _ = try await cancelled.value; preconditionFailure("Cancellation swallowed") }
        catch { check(error is CancellationError, "Cancellation changed into fallback") }
        PriceFixtureProtocol.install(.dex)
        let native = try await AssetPriceClient.fetchPrice(for: WalletAsset(id: "eth:native", network: .ethereum), session: session)
        check(native.price == 1, "Native pricing regressed")
        print("PASS: all token-chain DEX routes, SAND valuation, DEX-first under adaptive ranking, contract fallback, wrong-chain/mint rejection, catalog bypass rejection, legacy cache rejection, cancellation, native pricing")
        if CommandLine.arguments.contains("--live") {
            let live = try await AssetPriceClient.fetchPrice(for: sand, session: .shared)
            check(live.provider == AssetPriceClient.dexScreenerContractPriceProvider || live.provider == AssetPriceClient.geckoTerminalContractPriceProvider, "Live DEX unavailable")
            print("LIVE Base SAND: \(live.provider), USD \(live.price)")
        }
    }
}
