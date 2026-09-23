import Foundation
import Testing
@testable import Aperture

extension AptosSupportTests {
    @Test
    func indexerNumberDecoderPreservesMaximumUInt64() throws {
        let json = Data(
            #"""
            {"current_fungible_asset_balances":[{"storage_id":"0x0000000000000000000000000000000000000000000000000000000000000001","amount":18446744073709551615,"asset_type":"0x1::aptos_coin::AptosCoin","token_standard":"v1","is_primary":true,"is_frozen":false,"metadata":null}]}
            """#.utf8
        )
        let response = try JSONDecoder().decode(
            AptosIndexerBalancesResponse.self,
            from: json
        )
        let balance = try #require(
            response.currentFungibleAssetBalances.first
        )
        #expect(balance.amount == "18446744073709551615")
    }

    static func network(
        id: String,
        chainID: Int64
    ) -> DBNetworkRecord {
        DBNetworkRecord(
            id: id,
            chainID: chainID,
            nameKey: "network.\(id).name",
            nativeSymbol: id.uppercased(),
            trustWalletBlockchain: id,
            rpcProviderIdentifier: id,
            isMainnet: true,
            isEnabled: true,
            sortOrder: 0,
            createdAt: 0,
            updatedAt: 0
        )
    }

    static var tokenMetadata: AptosTokenMetadata {
        AptosTokenMetadata(
            assetType: tokenType,
            metadataAddress: nil,
            name: "USD Coin",
            symbol: "USDC",
            decimals: 6,
            iconURL: nil,
            tokenStandard: "v1",
            isVerified: false,
            rank: 10_000
        )
    }
}

actor AptosSnapshotProbe {
    private(set) var recordCount = 0
    private(set) var firstBalanceCount = -1
    private(set) var lastBalanceCount = -1

    func record(_ snapshot: AptosWalletSnapshot) {
        recordCount += 1
        if firstBalanceCount < 0 {
            firstBalanceCount = snapshot.balances.count
        }
        lastBalanceCount = snapshot.balances.count
    }
}
