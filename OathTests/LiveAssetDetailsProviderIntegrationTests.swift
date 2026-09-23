#if LIVE_MAINNET_TESTS
import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct LiveAssetDetailsProviderIntegrationTests {
    private static let evmFixtureAddress =
        "0x6f8c2d54a7b913e0c4d2f8173a5e9b406c1d72fa"

    @Test
    func everyEVMMainnetLoadsOnlyItsSelectedNativeAsset() async throws {
        let networks = Self.evmNetworks
        #expect(networks.count == 13)

        try await Self.verifyConcurrently(networks) { network in
            let token = ReceiveToken.nativeAsset(for: network)
            let variant = try #require(token.variants.first)
            let selected = WalletAsset(
                id: variant.assetIdentity,
                name: token.name,
                symbol: token.symbol,
                logoSource: .nativeCoin(blockchain: network.blockchain),
                network: network.blockchain,
                balance: 0,
                fiatValue: 0,
                decimals: variant.decimals,
                receiveAddress: Self.evmFixtureAddress
            )
            let result = try await AnkrAPIClient.localBuild()
                .loadAssetDetails(
                    asset: selected,
                    address: Self.evmFixtureAddress
                )

            let loaded = try #require(result.snapshot.assets.first)
            #expect(result.snapshot.assets.count == 1)
            #expect(loaded.network == network.blockchain)
            #expect(loaded.logoSource.checksummedContractAddress == nil)
            #expect(loaded.balanceText != nil)
            #expect(loaded.balanceAtomic?.allSatisfy(\.isNumber) == true)
            #expect(
                result.snapshot.persistenceTransactions.allSatisfy {
                    WalletAssetDetailsSelection.matches($0, asset: loaded)
                }
            )
        }
    }

    @Test
    func everyEVMMainnetLoadsOnlyItsSelectedCatalogContract() async throws {
        let networks = Self.evmNetworks
        #expect(networks.count == 13)

        try await Self.verifyConcurrently(networks) { network in
            let tokenAndVariant = try #require(
                ReceiveAssetCatalog.tokens(for: network.id)
                    .lazy
                    .flatMap { token in
                        token.variants
                            .filter {
                                $0.networkID == network.id
                                    && $0.contractAddress != nil
                            }
                            .map { (token, $0) }
                    }
                    .first
            )
            let token = tokenAndVariant.0
            let variant = tokenAndVariant.1
            let contract = try #require(variant.contractAddress)
            let selected = WalletAsset(
                id: variant.assetIdentity,
                name: token.name,
                symbol: token.symbol,
                logoSource: variant.logoSource,
                network: network.blockchain,
                balance: 0,
                fiatValue: 0,
                decimals: variant.decimals,
                receiveAddress: Self.evmFixtureAddress
            )
            let result = try await AnkrAPIClient.localBuild()
                .loadAssetDetails(
                    asset: selected,
                    address: Self.evmFixtureAddress
                )

            let loaded = try #require(result.snapshot.assets.first)
            #expect(result.snapshot.assets.count == 1)
            #expect(loaded.network == network.blockchain)
            #expect(
                loaded.logoSource.checksummedContractAddress?
                    .caseInsensitiveCompare(contract) == .orderedSame
            )
            #expect(loaded.balanceText != nil)
            #expect(loaded.balanceAtomic?.allSatisfy(\.isNumber) == true)
            #expect(
                result.snapshot.persistenceTransactions.allSatisfy {
                    WalletAssetDetailsSelection.matches($0, asset: loaded)
                }
            )
        }
    }

    private static var evmNetworks: [ReceiveNetwork] {
        ReceiveNetworkCatalog.all.filter {
            $0.blockchain.isEVM
                && AnkrAPIClient.supportsTokenLookup(networkID: $0.id)
        }
    }

    private static func verifyConcurrently(
        _ networks: [ReceiveNetwork],
        operation: @escaping @Sendable (ReceiveNetwork) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = networks.makeIterator()
            for _ in 0..<min(3, networks.count) {
                if let network = iterator.next() {
                    group.addTask { try await operation(network) }
                }
            }
            while try await group.next() != nil {
                if let network = iterator.next() {
                    group.addTask { try await operation(network) }
                }
            }
        }
    }
}
#endif
