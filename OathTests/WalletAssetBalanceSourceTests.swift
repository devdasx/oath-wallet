import Foundation
import Testing
@testable import Aperture

struct WalletAssetBalanceSourceTests {
    @Test
    func liveSnapshotReplacesStaleValuesClearsSpentAssetsAndAddsNewHoldings() {
        let preparedBitcoin = nativeAsset(
            id: "bitcoin:native",
            symbol: "BTC",
            blockchain: .bitcoin,
            balance: 0,
            fiatValue: 0,
            balanceText: "0",
            balanceAtomic: "0",
            receiveAddress: "bc1qprepared"
        )
        let staleTron = nativeAsset(
            id: "tron:native",
            symbol: "TRX",
            blockchain: .tron,
            balance: 100,
            fiatValue: 25,
            balanceText: "100",
            balanceAtomic: "100000000",
            receiveAddress: "TPrepared"
        )
        let currentBitcoin = nativeAsset(
            id: "BITCOIN:NATIVE",
            symbol: "BTC",
            blockchain: .bitcoin,
            balance: 1,
            fiatValue: 30,
            balanceText: "1.0",
            balanceAtomic: "100000000"
        )
        let newlyFundedToken = tokenAsset(
            id: "eth:0x1111111111111111111111111111111111111111",
            balance: 9,
            fiatValue: 18
        )

        let projected = WalletAssetBalanceSnapshot(
            assets: [currentBitcoin, newlyFundedToken]
        ).projecting(candidates: [preparedBitcoin, staleTron])

        #expect(projected.count == 3)
        #expect(projected[0].balance == 1)
        #expect(projected[0].fiatValue == 30)
        #expect(projected[0].balanceText == "1.0")
        #expect(projected[0].balanceAtomic == "100000000")
        #expect(projected[0].receiveAddress == "bc1qprepared")
        #expect(projected[1].balance == 0)
        #expect(projected[1].fiatValue == 0)
        #expect(projected[1].balanceText == "0")
        #expect(projected[1].balanceAtomic == "0")
        #expect(projected[1].receiveAddress == "TPrepared")
        #expect(projected[2] == newlyFundedToken)
    }

    @Test
    func liveFundedSelectionsIncludeAssetsMissingFromPreparedIndexes() {
        let lowerValue = nativeAsset(
            id: "litecoin:native",
            symbol: "LTC",
            blockchain: .litecoin,
            balance: 1,
            fiatValue: 4
        )
        let newlyFunded = tokenAsset(
            id: "eth:0x2222222222222222222222222222222222222222",
            balance: 20,
            fiatValue: 20
        )

        let selections = WalletAssetLiveSelectionProjection
            .selections(
                indexedSelections: [.walletAsset(lowerValue)],
                walletAssets: [lowerValue, newlyFunded],
                directAssetsByIdentity: [
                    AssetIdentityKey.canonical(lowerValue.id): lowerValue
                ],
                transactions: [],
                networkID: nil,
                searchText: "",
                eligibleSolanaTokenMints: [],
                visibleLimit: 150
            )

        #expect(selections.count == 2)
        #expect(
            selections.first?.canonicalAssetIdentity
                == AssetIdentityKey.canonical(newlyFunded.id)
        )
        #expect(
            selections.map(\.canonicalAssetIdentity).contains(
                AssetIdentityKey.canonical(lowerValue.id)
            )
        )
    }

    @Test
    func balanceSourceIsBoundToOneWalletRequest() {
        let requestID = UUID()
        let identity = PersistedWalletIdentity(
            walletID: "wallet-a",
            address: "0x1111111111111111111111111111111111111111"
        )
        let source = WalletActionBalanceSource(
            requestID: requestID,
            identity: identity,
            stateRevision: UUID(),
            assets: []
        )
        let matching = context(requestID: requestID, identity: identity)
        let otherRequest = context(requestID: UUID(), identity: identity)
        let otherWallet = context(
            requestID: requestID,
            identity: PersistedWalletIdentity(
                walletID: "wallet-b",
                address: "0x2222222222222222222222222222222222222222"
            )
        )

        #expect(source.matches(matching))
        #expect(!source.matches(otherRequest))
        #expect(!source.matches(otherWallet))
    }

    @Test
    func catalogMergeDoesNotCollapseCaseSensitiveTronIdentities() {
        let first = tokenAsset(
            id: "tron:TCaseSensitiveAddress",
            balance: 0,
            fiatValue: 0,
            blockchain: .tron
        )
        let second = tokenAsset(
            id: "tron:tCaseSensitiveAddress",
            balance: 0,
            fiatValue: 0,
            blockchain: .tron
        )

        let available = WalletHomeAssetCatalog.availableAssets(
            from: [],
            remoteCatalogAssets: [first, second]
        )

        #expect(available.count == 2)
        #expect(Set(available.map(\.id)) == Set([first.id, second.id]))
    }

    private func context(
        requestID: UUID,
        identity: PersistedWalletIdentity
    ) -> AppRootResolvedWalletContext {
        AppRootResolvedWalletContext(
            requestID: requestID,
            identity: identity,
            name: "Wallet",
            capabilities: .fullWallet
        )
    }

    private func nativeAsset(
        id: String,
        symbol: String,
        blockchain: WalletBlockchain,
        balance: Decimal,
        fiatValue: Decimal,
        balanceText: String? = nil,
        balanceAtomic: String? = nil,
        receiveAddress: String? = nil
    ) -> WalletAsset {
        WalletAsset(
            id: id,
            name: symbol,
            symbol: symbol,
            logoSource: .nativeCoin(blockchain: blockchain),
            network: blockchain,
            balance: balance,
            fiatValue: fiatValue,
            balanceText: balanceText,
            balanceAtomic: balanceAtomic,
            receiveAddress: receiveAddress
        )
    }

    private func tokenAsset(
        id: String,
        balance: Decimal,
        fiatValue: Decimal,
        blockchain: WalletBlockchain = .ethereum
    ) -> WalletAsset {
        let contract = AssetIdentityKey.contractAddress(from: id) ?? id
        return WalletAsset(
            id: id,
            name: "Test Token",
            symbol: "TEST",
            logoSource: .catalogToken(
                blockchain: blockchain,
                contractAddress: contract,
                logoURL: nil
            ),
            network: blockchain,
            balance: balance,
            fiatValue: fiatValue,
            balanceText: EnglishNumbers.decimal(balance),
            decimals: 18
        )
    }
}
