import Testing
@testable import Aperture

struct AddTokenNetworkSelectionTests {
    @Test
    func fullWalletKeepsEveryCustomTokenNetwork() {
        let expected = Set(
            ReceiveNetworkCatalog.all
                .filter {
                    CustomTokenAddress.supports(networkID: $0.id)
                }
                .map(\.id)
        )

        #expect(networkIDs(for: .fullWallet) == expected)
        #expect(!expected.isEmpty)
    }

    @Test
    func evmPrivateKeyKeepsOnlyEVMTokenNetworks() {
        let capabilities = WalletCapabilities(
            scope: .privateKey(.evm)
        )
        let actual = networkIDs(for: capabilities)
        let expected = Set(
            ReceiveNetworkCatalog.all
                .filter {
                    $0.blockchain.isEVM
                        && CustomTokenAddress.supports(networkID: $0.id)
                }
                .map(\.id)
        )

        #expect(actual == expected)
        #expect(!actual.contains(SolanaConstants.networkID))
        #expect(!actual.contains(TronConstants.networkID))
    }

    @Test
    func chainSpecificPrivateKeysKeepOnlyTheirTokenNetwork() {
        #expect(
            networkIDs(
                for: WalletCapabilities(scope: .privateKey(.solana))
            ) == [SolanaConstants.networkID]
        )
        #expect(
            networkIDs(
                for: WalletCapabilities(scope: .privateKey(.tron))
            ) == [TronConstants.networkID]
        )
    }

    @Test
    func privateKeyWithoutCustomTokenSupportHasNoAddTokenNetwork() {
        let capabilities = WalletCapabilities(
            scope: .privateKey(.aptos)
        )

        #expect(networkIDs(for: capabilities).isEmpty)
    }

    private func networkIDs(
        for capabilities: WalletCapabilities
    ) -> Set<String> {
        Set(
            AddTokenNetworkSelectionView.supportedNetworks(
                for: capabilities
            ).map(\.id)
        )
    }
}
