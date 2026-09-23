import Foundation
@testable import Aperture

/// A deterministic, production-sized catalog for CPU benchmarks. Network
/// acquisition is tested separately; these tests must not benchmark an empty DB.
enum WalletPerformanceCatalogFixture {
    static func install() -> ReceiveAssetCatalogRuntimeSnapshot {
        let previous = ReceiveAssetCatalogRuntime.snapshot
        let native = ReceiveToken(
            id: "ethereum", name: "Ethereum", symbol: "ETH", rank: 1, isStablecoin: false,
            variants: [ReceiveTokenVariant(networkID: "eth", contractAddress: nil, decimals: 18, networkRank: 1, logoURL: nil)]
        )
        let stable = ReceiveToken(
            id: "tether", name: "Tether USD", symbol: "USDT", rank: 2,
            isStablecoin: true,
            variants: [ReceiveTokenVariant(networkID: "eth", contractAddress: "0xdac17f958d2ee523a2206206994597c13d831ec7", decimals: 6, networkRank: 2, logoURL: nil)]
        )
        let tokens = (1...2_200).map { index in
            ReceiveToken(
                id: "performance-\(index)", name: "Performance Asset \(index)",
                symbol: "P\(index)", rank: index + 2, isStablecoin: false,
                variants: [ReceiveTokenVariant(
                    networkID: "eth",
                    contractAddress: "0x" + String(repeating: "0", count: 40 - String(index, radix: 16).count) + String(index, radix: 16),
                    decimals: 18, networkRank: index + 2, logoURL: nil
                )]
            )
        }
        ReceiveAssetCatalogRuntime.install([native, stable] + tokens, revision: 1)
        return previous
    }

    static func restore(_ snapshot: ReceiveAssetCatalogRuntimeSnapshot) {
        ReceiveAssetCatalogRuntime.install(snapshot.tokens, revision: snapshot.revision)
    }
}
