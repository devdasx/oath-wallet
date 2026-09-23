import Foundation
import GRDB
import Testing
import UIKit
@testable import Aperture

/// Asset families: a curated group of tokens (bStocks on BNB Smart Chain)
/// that gets its own chip next to the networks and its own badge beside the
/// network badge, while its members stay ordinary tokens of their chain.
@Suite(.serialized)
struct AssetFamilyTests {
    private let bnb = "bsc:native"
    private let tesla = "bsc:0x5b1910eaad6450e50f816082aa078c41f10c292f"
    private let cake = "bsc:0x0e09fabb73bd3ade0a17ecc321fd13a19e81ce82"
    private let future = "bsc:0x1111111111111111111111111111111111111111"

    @Test
    func familyChipFollowsItsNetworkAndKeepsTheNetworkMappings() {
        let options = AssetNetworkSelectorOption.allSelectable
        let bsc = try? #require(options.firstIndex { $0.id == "bsc" })
        let chip = options[(bsc ?? 0) + 1]

        // The networks list itself is untouched: no family, no duplicates
        // by chain, and the same entries in the same order.
        #expect(AssetNetworkSelectorOption.allSupported.allSatisfy { $0.family == nil })
        #expect(
            Set(AssetNetworkSelectorOption.allSupported.map(\.blockchain)).count
                == AssetNetworkSelectorOption.allSupported.count
        )
        #expect(
            options.filter { $0.family == nil }.map(\.id)
                == AssetNetworkSelectorOption.allSupported.map(\.id)
        )

        #expect(chip.id == "family:bstocks")
        #expect(chip.family == .bStocks)
        #expect(chip.blockchain == .smartchain)
        #expect(chip.localizedName == "bStocks")
        #expect(chip.officialLogoAssetName == "AssetFamilyLogoBStocks")
        #expect(UIImage(named: chip.officialLogoAssetName) != nil)
        #expect(Set(options.map(\.id)).count == options.count)
        #expect(options.filter { $0.family != nil }.count == AssetFamily.allCases.count)

        // The network mappings ignore the chip; the chip resolves to its chain.
        #expect(AssetNetworkSelectorOption.networkID(for: .smartchain) == "bsc")
        #expect(AssetNetworkSelectorOption.blockchain(for: "family:bstocks") == .smartchain)
        #expect(AssetNetworkSelectorOption.family(for: "family:bstocks") == .bStocks)
        #expect(AssetNetworkSelectorOption.family(for: "bsc") == nil)
        #expect(AssetFamily.selectorFamily(for: "family:unknown") == nil)
        #expect(AssetFamily.bStocks.logoSource.bundledAssetName == "AssetFamilyLogoBStocks")
        #expect(AssetFamily.bStocks.logoSource.origin == .bundled)
        #expect(AssetFamily.bStocks.logoSource.blockchain == .smartchain)
    }

    @Test
    func membershipInstallsFromTheCatalogAndDrivesFiltersAndBadges() async throws {
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer {
            ReceiveAssetCatalogRuntime.install(
                previous.tokens,
                revision: previous.revision
            )
        }
        let database = try WalletDatabase.temporary()
        let entries = [
            nativeEntry(order: 0),
            entry(identity: tesla, symbol: "TSLAB", order: 1, family: "bstocks"),
            entry(identity: cake, symbol: "CAKE", order: 2, family: nil),
            // A family this build does not know is kept as a plain token.
            entry(identity: future, symbol: "FUT", order: 3, family: "future_family")
        ]
        let tokens = try await database.pool.write { db in
            try WalletAssetCatalogPersistence.replaceRemoteSnapshot(
                entries,
                revision: 4,
                in: db
            )
            return try WalletAssetCatalogPersistence.loadCachedTokens(in: db)
        }
        #expect(tokens.count == 4)
        #expect(tokens.first { $0.symbol == "BNB" }?.variants.first?.family == nil)
        #expect(tokens.first { $0.symbol == "TSLAB" }?.variants.first?.family == .bStocks)
        #expect(tokens.first { $0.symbol == "CAKE" }?.variants.first?.family == nil)
        #expect(tokens.first { $0.symbol == "FUT" }?.variants.first?.family == nil)

        ReceiveAssetCatalogRuntime.install(tokens, revision: 4)
        #expect(ReceiveAssetCatalog.family(forAssetIdentity: tesla) == .bStocks)
        #expect(ReceiveAssetCatalog.family(forAssetIdentity: tesla.uppercased()) == .bStocks)
        #expect(ReceiveAssetCatalog.family(forAssetIdentity: cake) == nil)

        // Receive picker: the family chip leads with the chain's native coin
        // (it pays the gas) and then lists members only; the network chip
        // still lists everything on the chain.
        #expect(ReceiveAssetSearchIndex.candidates(networkID: "family:bstocks").map(\.id) == [bnb, tesla])
        #expect(Set(ReceiveAssetSearchIndex.candidates(networkID: "bsc").map(\.id)) == [bnb, tesla, cake, future])
        #expect(ReceiveAssetSearchIndex.candidates(networkID: "family:bstocks", matching: "TSLA").map(\.id) == [tesla])
        #expect(ReceiveAssetSearchIndex.candidates(networkID: "family:bstocks", matching: "BNB").map(\.id) == [bnb])
        #expect(ReceiveAssetSearchIndex.candidates(networkID: "family:bstocks", matching: "CAKE").isEmpty)
        #expect(ReceiveAssetSearchIndex.candidates(networkID: "bsc", matching: "CAKE").map(\.id) == [cake])

        // Wallet assets: badge sources and chip membership.
        let teslaAsset = asset(identity: tesla, symbol: "TSLAB")
        let cakeAsset = asset(identity: cake, symbol: "CAKE")
        let bnbAsset = WalletAsset(
            id: bnb,
            name: "BNB Smart Chain",
            symbol: "BNB",
            logoSource: .nativeCoin(blockchain: .smartchain),
            network: .smartchain,
            balance: 1,
            fiatValue: 600,
            decimals: 18,
            isVerified: true
        )
        #expect(bnbAsset.family == nil)
        #expect(bnbAsset.familyLogoSource == nil)
        #expect(AssetNetworkSelectorOption.includes(bnbAsset, in: "family:bstocks"))
        #expect(teslaAsset.family == .bStocks)
        #expect(teslaAsset.familyLogoSource == .family(.bStocks))
        #expect(teslaAsset.networkLogoSource == .network(blockchain: .smartchain))
        #expect(cakeAsset.family == nil)
        #expect(cakeAsset.familyLogoSource == nil)
        #expect(AssetNetworkSelectorOption.includes(teslaAsset, in: "family:bstocks"))
        #expect(AssetNetworkSelectorOption.includes(teslaAsset, in: "bsc"))
        #expect(AssetNetworkSelectorOption.includes(teslaAsset, in: nil))
        #expect(!AssetNetworkSelectorOption.includes(cakeAsset, in: "family:bstocks"))
        #expect(AssetNetworkSelectorOption.includes(cakeAsset, in: "bsc"))
        #expect(!AssetNetworkSelectorOption.includes(cakeAsset, in: "eth"))

        // Send picker: the family chip narrows to members plus the native coin.
        let choices = [teslaAsset, cakeAsset, bnbAsset].map(choice)
        #expect(choices.map(\.family) == [.bStocks, nil, nil])
        #expect(
            Set(SendAssetChoiceCatalog.filtered(choices, networkID: "family:bstocks", searchText: "")
                .map(\.id)) == [tesla, bnb]
        )
        #expect(
            SendAssetChoiceCatalog.filtered(choices, networkID: "bsc", searchText: "")
                .count == 3
        )
        #expect(
            SendAssetChoiceCatalog.filtered(choices, networkID: "family:bstocks", searchText: "cake")
                .isEmpty
        )

        // Chip ordering: a funded member lifts its family chip next to its chain.
        let ordering = WalletNetworkSelectionOrdering(
            walletAssets: [teslaAsset],
            transactions: []
        )
        let ordered = ordering.ordered(AssetNetworkSelectorOption.allSelectable)
        #expect(ordered.prefix(2).map(\.id) == ["bsc", "family:bstocks"])
    }

    @Test
    func remoteEntriesCarryTheFamilyThroughSync() async throws {
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer {
            ReceiveAssetCatalogRuntime.install(
                previous.tokens,
                revision: previous.revision
            )
        }
        let database = try WalletDatabase.temporary()
        let client = AssetFamilyFixtureClient(
            entries: [
                remoteJSON(identity: tesla, symbol: "TSLAB", order: 1, revision: 5, family: "\"bstocks\""),
                remoteJSON(identity: cake, symbol: "CAKE", order: 2, revision: 6, family: nil)
            ],
            revision: 6
        )

        try await AssetCatalogSyncService(client: client)
            .synchronizeAndWait(database: database)

        let tokens = try await database.pool.read { db in
            try WalletAssetCatalogPersistence.loadCachedTokens(in: db)
        }
        #expect(tokens.map(\.symbol) == ["TSLAB", "CAKE"])
        #expect(tokens.first?.variants.first?.family == .bStocks)
        #expect(tokens.last?.variants.first?.family == nil)
        #expect(ReceiveAssetCatalog.family(forAssetIdentity: tesla) == .bStocks)
        #expect(await client.requestedActions() == ["manifest", "snapshot"])
    }

    // MARK: - Fixtures

    private func entry(
        identity: String,
        symbol: String,
        order: Int64,
        family: String?
    ) -> AssetCatalogRemoteEntry {
        AssetCatalogRemoteEntry(
            assetIdentity: identity,
            tokenID: identity,
            networkID: "bsc",
            contractAddress: String(identity.dropFirst("bsc:".count)),
            name: symbol,
            symbol: symbol,
            decimals: 18,
            globalRank: order,
            networkRank: order,
            isStablecoin: false,
            logoURL: nil,
            marketDataID: nil,
            tokenOrder: order,
            variantOrder: 0,
            source: .curated,
            isVerified: true,
            isActive: true,
            revision: order,
            assetFamily: family
        )
    }

    private func nativeEntry(order: Int64) -> AssetCatalogRemoteEntry {
        AssetCatalogRemoteEntry(
            assetIdentity: bnb,
            tokenID: "native-bsc",
            networkID: "bsc",
            contractAddress: nil,
            name: "BNB Smart Chain",
            symbol: "BNB",
            decimals: 18,
            globalRank: 1,
            networkRank: 0,
            isStablecoin: false,
            logoURL: nil,
            marketDataID: "binancecoin",
            tokenOrder: order,
            variantOrder: 0,
            source: .curated,
            isVerified: true,
            isActive: true,
            revision: 4,
            assetFamily: nil
        )
    }

    private func asset(identity: String, symbol: String) -> WalletAsset {
        WalletAsset(
            id: identity,
            name: symbol,
            symbol: symbol,
            logoSource: .catalogToken(
                blockchain: .smartchain,
                contractAddress: String(identity.dropFirst("bsc:".count)),
                logoURL: nil
            ),
            network: .smartchain,
            balance: 1,
            fiatValue: 100,
            decimals: 18,
            isVerified: true
        )
    }

    private func choice(_ asset: WalletAsset) -> SendAssetChoice {
        SendAssetChoice(
            id: asset.id,
            name: asset.name,
            symbol: asset.symbol,
            networkID: "bsc",
            networkName: "BNB Smart Chain",
            blockchain: .smartchain,
            contractAddress: AssetIdentityKey.contractAddress(from: asset.id),
            decimals: 18,
            logoSource: asset.logoSource,
            networkLogoSource: asset.networkLogoSource,
            balance: asset.balance,
            fiatValue: asset.fiatValue,
            balanceAtomic: nil,
            sourceAddress: nil,
            isVerified: true
        )
    }

    private func remoteJSON(
        identity: String,
        symbol: String,
        order: Int,
        revision: Int,
        family: String?
    ) -> String {
        let contract = String(identity.dropFirst("bsc:".count))
        let familyField = family.map { ",\"asset_family\":\($0)" } ?? ""
        return """
        {"asset_identity":"\(identity)","token_id":"\(identity)","network_id":"bsc","contract_address":"\(contract)","name":"\(symbol)","symbol":"\(symbol)","decimals":18,"global_rank":"\(order)","network_rank":"\(order)","is_stablecoin":false,"logo_url":null,"market_data_id":null,"token_order":"\(order)","variant_order":0,"source":"curated","is_verified":true,"is_active":true,"revision":"\(revision)"\(familyField)}
        """
    }
}

private actor AssetFamilyFixtureClient: AssetCatalogRemoteDataClient {
    private let manifest: Data
    private let snapshot: Data
    private var actions: [String] = []

    init(entries: [String], revision: Int) {
        manifest = Data(
            "{\"snapshot_revision\":\"\(revision)\",\"entry_count\":\(entries.count)}".utf8
        )
        snapshot = Data(
            "{\"snapshot_revision\":\"\(revision)\",\"entry_count\":\(entries.count),\"entries\":[\(entries.joined(separator: ","))]}".utf8
        )
    }

    func invokeData(functionPath _: String, payload: Data) async throws -> Data {
        guard
            let dictionary = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let action = dictionary["action"] as? String
        else {
            throw AssetCatalogSyncError.invalidResponse
        }
        actions.append(action)
        switch action {
        case "manifest": return manifest
        case "snapshot": return snapshot
        default: throw AssetCatalogSyncError.invalidResponse
        }
    }

    func requestedActions() -> [String] {
        actions
    }
}
