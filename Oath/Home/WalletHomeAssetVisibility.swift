import Foundation

struct WalletAssetVisibilityResolution: Sendable {
    fileprivate let visibilityOverrides: [String: Bool]
    fileprivate let pinOverrides: [String: Bool]

    func visibilityOverride(for asset: WalletAsset) -> Bool? {
        Self.override(for: asset, in: visibilityOverrides)
    }

    func isPinned(_ asset: WalletAsset) -> Bool {
        Self.override(for: asset, in: pinOverrides) ?? asset.isPinned
    }

    private static func override(
        for asset: WalletAsset,
        in overrides: [String: Bool]
    ) -> Bool? {
        let identity = AssetIdentityKey.canonical(asset.id)
        return overrides[identity] ?? overrides[asset.id]
    }
}

enum WalletHomeAssetVisibility {
    static let maximumFundedHomeAssetCount = 15

    static func homeAssets(
        from assets: [WalletAsset],
        transactions: [WalletTransaction],
        walletAddress: String,
        preferencesJSON: String
    ) -> [WalletAsset] {
        homeAssets(
            from: assets,
            transactions: transactions,
            resolution: resolution(
                walletAddress: walletAddress,
                preferencesJSON: preferencesJSON
            )
        )
    }

    static func homeAssets(
        from assets: [WalletAsset],
        transactions: [WalletTransaction],
        resolution: WalletAssetVisibilityResolution
    ) -> [WalletAsset] {
        let uniqueAssets = uniqueAssetsByIdentity(from: assets).filter {
            !$0.isSpam
        }

        guard
            let fundedCandidates = fundedHomeCandidates(
                from: uniqueAssets,
                resolution: resolution
            )
        else {
            return emptyWalletAssets(
                from: uniqueAssets,
                transactions: transactions,
                resolution: resolution
            )
        }

        return limitedHomeAssets(
            fundedCandidates,
            resolution: resolution
        )
    }

    static func resolution(
        walletAddress: String,
        preferencesJSON: String
    ) -> WalletAssetVisibilityResolution {
        let preferences = decodedPreferences(from: preferencesJSON)
        let walletScope = scope(for: walletAddress)
        return WalletAssetVisibilityResolution(
            visibilityOverrides: preferences.wallets[walletScope] ?? [:],
            pinOverrides: preferences.pinnedWallets[walletScope] ?? [:]
        )
    }

    static func visibleAssetIDs(
        from assets: [WalletAsset],
        transactions: [WalletTransaction],
        walletAddress: String,
        preferencesJSON: String
    ) -> Set<String> {
        Set(
            homeAssets(
                from: assets,
                transactions: transactions,
                walletAddress: walletAddress,
                preferencesJSON: preferencesJSON
            )
            .map {
                AssetIdentityKey.canonical($0.id)
            }
        )
    }

    static func managementVisibleAssetIDs(
        from assets: [WalletAsset],
        transactions: [WalletTransaction],
        walletAddress: String,
        preferencesJSON: String
    ) -> Set<String> {
        let uniqueAssets = uniqueAssetsByIdentity(from: assets).filter {
            !$0.isSpam
        }
        let resolution = resolution(
            walletAddress: walletAddress,
            preferencesJSON: preferencesJSON
        )
        let visibleAssets: [WalletAsset]
        if let fundedCandidates = fundedHomeCandidates(
            from: uniqueAssets,
            resolution: resolution
        ) {
            visibleAssets = fundedCandidates
        } else {
            visibleAssets = emptyWalletAssets(
                from: uniqueAssets,
                transactions: transactions,
                resolution: resolution
            )
        }

        return Set(
            visibleAssets.map {
                AssetIdentityKey.canonical($0.id)
            }
        )
    }

    static func isAvailableOutsideManagement(
        _ asset: WalletAsset,
        walletAddress: String,
        preferencesJSON: String
    ) -> Bool {
        guard !asset.isSpam else {
            return false
        }
        guard asset.requiresExplicitVisibility else {
            return true
        }
        return resolution(
            walletAddress: walletAddress,
            preferencesJSON: preferencesJSON
        ).visibilityOverride(for: asset) == true
    }

    static func assetsAvailableOutsideManagement(
        from assets: [WalletAsset],
        walletAddress: String,
        preferencesJSON: String
    ) -> [WalletAsset] {
        let resolution = resolution(
            walletAddress: walletAddress,
            preferencesJSON: preferencesJSON
        )
        return assets.filter { asset in
            !asset.isSpam
                && (
                    !asset.requiresExplicitVisibility
                        || resolution.visibilityOverride(for: asset) == true
                )
        }
    }

    static func updatedPreferencesJSON(
        setting isVisible: Bool,
        for asset: WalletAsset,
        walletAddress: String,
        preferencesJSON: String
    ) -> String? {
        var preferences = decodedPreferences(from: preferencesJSON)
        let walletScope = scope(for: walletAddress)
        var overrides = preferences.wallets[walletScope] ?? [:]
        let identity = AssetIdentityKey.canonical(asset.id)
        overrides.removeValue(forKey: asset.id)
        overrides[identity] = isVisible
        preferences.wallets[walletScope] = overrides

        if !isVisible {
            var pinOverrides =
                preferences.pinnedWallets[walletScope] ?? [:]
            pinOverrides.removeValue(forKey: asset.id)
            pinOverrides[identity] = false
            preferences.pinnedWallets[walletScope] = pinOverrides
        }

        return encodedPreferences(preferences)
    }

    static func isPinned(
        _ asset: WalletAsset,
        walletAddress: String,
        preferencesJSON: String
    ) -> Bool {
        resolution(
            walletAddress: walletAddress,
            preferencesJSON: preferencesJSON
        ).isPinned(asset)
    }

    static func updatedPreferencesJSON(
        settingPinned isPinned: Bool,
        for asset: WalletAsset,
        walletAddress: String,
        preferencesJSON: String
    ) -> String? {
        var preferences = decodedPreferences(from: preferencesJSON)
        let walletScope = scope(for: walletAddress)
        let identity = AssetIdentityKey.canonical(asset.id)

        var pinOverrides = preferences.pinnedWallets[walletScope] ?? [:]
        pinOverrides.removeValue(forKey: asset.id)
        pinOverrides[identity] = isPinned
        preferences.pinnedWallets[walletScope] = pinOverrides

        if isPinned {
            var visibilityOverrides = preferences.wallets[walletScope] ?? [:]
            visibilityOverrides.removeValue(forKey: asset.id)
            visibilityOverrides[identity] = true
            preferences.wallets[walletScope] = visibilityOverrides
        }

        return encodedPreferences(preferences)
    }

    private static func uniqueAssetsByIdentity(
        from assets: [WalletAsset]
    ) -> [WalletAsset] {
        var seen = Set<String>()
        return assets.filter {
            seen.insert(AssetIdentityKey.canonical($0.id)).inserted
        }
    }

    private static func emptyWalletAssets(
        from assets: [WalletAsset],
        transactions: [WalletTransaction],
        resolution: WalletAssetVisibilityResolution
    ) -> [WalletAsset] {
        let automaticAssets = WalletHomeAssetCatalog.mainScreenAssets(
            from: assets
        )
        let automaticIDs = Set(
            automaticAssets.map {
                AssetIdentityKey.canonical($0.id)
            }
        )
        let automaticallyVisible = automaticAssets.filter {
            resolution.visibilityOverride(for: $0) ?? true
        }
        let explicitAssets = AssetDiscoveryRanking.assets(
            assets.filter { asset in
                let identity = AssetIdentityKey.canonical(asset.id)
                return !automaticIDs.contains(identity)
                    && resolution.visibilityOverride(for: asset) != false
                    && (
                        resolution.visibilityOverride(for: asset) == true
                            || resolution.isPinned(asset)
                    )
            },
            transactions: transactions,
            searchText: ""
        )
        let selectedAssets = automaticallyVisible + explicitAssets
        let pinnedAssets = selectedAssets.filter {
            resolution.isPinned($0)
        }
        let regularAssets = selectedAssets.filter {
            !resolution.isPinned($0)
        }
        return pinnedAssets + regularAssets
    }

    private static func hasPositiveHolding(_ asset: WalletAsset) -> Bool {
        asset.balance > 0 || asset.fiatValue > 0
    }

    private static func fundedHomeCandidates(
        from assets: [WalletAsset],
        resolution: WalletAssetVisibilityResolution
    ) -> [WalletAsset]? {
        let positiveHoldings = assets.filter { asset in
            hasPositiveHolding(asset)
                && isEligibleHolding(asset, resolution: resolution)
        }
        guard !positiveHoldings.isEmpty else { return nil }

        let explicitlyVisible = assets.filter { asset in
            let visibilityOverride = resolution.visibilityOverride(for: asset)
            guard visibilityOverride != false else { return false }
            return visibilityOverride == true
                || resolution.isPinned(asset)
        }
        let explicitlyVisibleIDs = Set(
            explicitlyVisible.map {
                AssetIdentityKey.canonical($0.id)
            }
        )
        let automaticFunded = positiveHoldings.filter { asset in
            resolution.visibilityOverride(for: asset) != false
                && !explicitlyVisibleIDs.contains(
                    AssetIdentityKey.canonical(asset.id)
                )
        }
        return explicitlyVisible + automaticFunded
    }

    private static func limitedHomeAssets(
        _ assets: [WalletAsset],
        resolution: WalletAssetVisibilityResolution
    ) -> [WalletAsset] {
        let pinnedAssets = sortedByValue(
            assets.filter {
                resolution.isPinned($0)
            }
        )
        let regularAssets = sortedByValue(
            assets.filter {
                !resolution.isPinned($0)
            }
        )
        let regularLimit = max(
            maximumFundedHomeAssetCount - pinnedAssets.count,
            0
        )
        return pinnedAssets + Array(regularAssets.prefix(regularLimit))
    }

    private static func isEligibleHolding(
        _ asset: WalletAsset,
        resolution: WalletAssetVisibilityResolution
    ) -> Bool {
        return !asset.requiresExplicitVisibility
            || resolution.visibilityOverride(for: asset) == true
    }

    private static func sortedByValue(
        _ assets: [WalletAsset]
    ) -> [WalletAsset] {
        assets.sorted { first, second in
            if first.fiatValue != second.fiatValue {
                return first.fiatValue > second.fiatValue
            }
            if first.balance != second.balance {
                return first.balance > second.balance
            }
            let nameComparison = first.name.localizedStandardCompare(
                second.name
            )
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return AssetIdentityKey.canonical(first.id)
                < AssetIdentityKey.canonical(second.id)
        }
    }

    private static func decodedPreferences(
        from json: String
    ) -> WalletAssetVisibilityPreferences {
        guard
            let data = json.data(using: .utf8),
            let preferences = try? JSONDecoder().decode(
                WalletAssetVisibilityPreferences.self,
                from: data
            )
        else {
            return WalletAssetVisibilityPreferences()
        }
        return preferences
    }

    private static func encodedPreferences(
        _ preferences: WalletAssetVisibilityPreferences
    ) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let data = try? encoder.encode(preferences),
            let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }

    private static func scope(for walletAddress: String) -> String {
        walletAddress.lowercased()
    }
}

private struct WalletAssetVisibilityPreferences: Codable {
    var wallets: [String: [String: Bool]] = [:]
    var pinnedWallets: [String: [String: Bool]] = [:]

    private enum CodingKeys: String, CodingKey {
        case wallets
        case pinnedWallets
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wallets = try container.decodeIfPresent(
            [String: [String: Bool]].self,
            forKey: .wallets
        ) ?? [:]
        pinnedWallets = try container.decodeIfPresent(
            [String: [String: Bool]].self,
            forKey: .pinnedWallets
        ) ?? [:]
    }
}
