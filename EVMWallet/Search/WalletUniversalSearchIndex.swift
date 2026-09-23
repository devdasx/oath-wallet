import Foundation

struct WalletUniversalSearchIndex: Sendable {
    let revision: UUID

    private struct ActionDocument: Sendable {
        let item: WalletUniversalSearchActionItem
        let title: String
        let searchableText: String
    }

    private struct WalletDocument: Sendable {
        let wallet: ManagedWallet
        let title: String
        let searchableText: String
    }

    private struct NetworkDocument: Sendable {
        let network: AssetNetworkSelectorOption
        let title: String
        let searchableText: String
    }

    private let assetIndex: WalletAssetDiscoveryIndex
    private let orderedAssets: [WalletAsset]
    private let actionDocuments: [ActionDocument]
    private let walletDocuments: [WalletDocument]
    private let networkDocuments: [NetworkDocument]
    private let unitUSDPricesByAssetID: [String: Decimal]

    static func make(
        assets: [WalletAsset],
        transactions: [WalletTransaction],
        wallets: [ManagedWallet],
        unitUSDPricesByAssetID: [String: Decimal] = [:]
    ) async -> WalletUniversalSearchIndex {
        async let assetIndex = makeAssetIndex(
            assets: assets,
            transactions: transactions
        )
        async let actionDocuments = makeActionDocuments()
        async let walletDocuments = makeWalletDocuments(wallets)
        async let networkDocuments = makeNetworkDocuments()

        let resolvedAssetIndex = await assetIndex
        return WalletUniversalSearchIndex(
            revision: UUID(),
            assetIndex: resolvedAssetIndex,
            orderedAssets: resolvedAssetIndex.assets(
                networkID: nil,
                searchText: ""
            ),
            actionDocuments: await actionDocuments,
            walletDocuments: await walletDocuments,
            networkDocuments: await networkDocuments,
            unitUSDPricesByAssetID: Dictionary(
                unitUSDPricesByAssetID.map {
                    (AssetIdentityKey.canonical($0.key), $0.value)
                },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    func unitUSDPrice(for asset: WalletAsset) -> Decimal? {
        if let price = unitUSDPricesByAssetID[
            AssetIdentityKey.canonical(asset.id)
        ], price > 0 {
            return price
        }
        guard asset.balance != 0, asset.fiatValue != 0 else {
            return nil
        }
        let inferredPrice = asset.fiatValue / asset.balance
        return inferredPrice > 0 ? inferredPrice : -inferredPrice
    }

    func suggestions() -> WalletUniversalSearchSuggestions {
        return WalletUniversalSearchSuggestions(
            actions: suggestedActions(withIDs: [
                "action.send",
                "action.receive",
                "action.scan",
                "navigation.assets"
            ]),
            features: suggestedActions(withIDs: [
                "navigation.manage_assets",
                "navigation.activity",
                "navigation.wallets",
                "settings.root"
            ]),
            settings: suggestedActions(withIDs: [
                "settings.security",
                "settings.appearance",
                "settings.language",
                "settings.currency",
                "settings.notifications"
            ]),
            marketAssets: suggestedMarketAssets(),
            assets: Array(
                orderedAssets.filter {
                    $0.fiatValue > 0 || $0.balance > 0
                }
                .prefix(4)
            )
        )
    }

    private func suggestedActions(
        withIDs orderedIDs: [String]
    ) -> [WalletUniversalSearchActionItem] {
        let itemsByID = Dictionary(
            uniqueKeysWithValues: actionDocuments.map {
                ($0.item.id, $0.item)
            }
        )
        return orderedIDs.compactMap { itemsByID[$0] }
    }

    private func suggestedMarketAssets() -> [WalletAsset] {
        Self.suggestedMarketBlockchains.compactMap { blockchain in
            orderedAssets.first { asset in
                guard asset.network == blockchain,
                      case let .nativeCoin(logoBlockchain) =
                        asset.logoSource else {
                    return false
                }
                return logoBlockchain == blockchain
            }
        }
    }

    private static let suggestedMarketBlockchains: [WalletBlockchain] = [
        .bitcoin,
        .ethereum,
        .solana,
        .smartchain
    ]

    func localResults(
        matching rawQuery: String
    ) -> WalletUniversalSearchResults {
        let query = Self.normalized(rawQuery)
        guard !query.isEmpty else { return .empty }

        let actions = rankedMatches(
            query: query,
            documents: actionDocuments,
            title: \.title,
            searchableText: \.searchableText
        )
        .prefix(20)
        .map(\.item)

        let wallets = rankedMatches(
            query: query,
            documents: walletDocuments,
            title: \.title,
            searchableText: \.searchableText
        )
        .prefix(20)
        .map(\.wallet)

        let networks = rankedMatches(
            query: query,
            documents: networkDocuments,
            title: \.title,
            searchableText: \.searchableText
        )
        .prefix(AssetNetworkSelectorOption.allSupported.count)
        .map(\.network)

        return WalletUniversalSearchResults(
            actions: Array(actions),
            wallets: Array(wallets),
            networks: Array(networks),
            assets: matchingAssets(query: query),
            transactions: []
        )
    }

    private func matchingAssets(query: String) -> [WalletAsset] {
        let categoryQueries: Set<String> = [
            Self.normalized(
                WalletLocalization.string("wallet.home.assets.title")
            )
        ]
        var matches: [WalletAsset]
        if categoryQueries.contains(query) {
            matches = orderedAssets
        } else {
            matches = assetIndex.assets(
                networkID: nil,
                searchText: query
            )
        }

        let numericMatches = orderedAssets.filter {
            assetNumericSearchText($0).contains(query)
        }
        var seen = Set<String>()
        let merged = matches + numericMatches
        return Array(
            merged.filter {
                seen.insert(
                    AssetIdentityKey.canonical($0.id)
                ).inserted
            }
            .prefix(60)
        )
    }

    private func rankedMatches<Document>(
        query: String,
        documents: [Document],
        title: KeyPath<Document, String>,
        searchableText: KeyPath<Document, String>
    ) -> [Document] {
        documents.compactMap { document -> (Document, Int)? in
            let score = Self.score(
                query: query,
                title: document[keyPath: title],
                searchableText: document[keyPath: searchableText]
            )
            return score > 0 ? (document, score) : nil
        }
        .sorted {
            if $0.1 != $1.1 {
                return $0.1 > $1.1
            }
            return $0.0[keyPath: title]
                < $1.0[keyPath: title]
        }
        .map(\.0)
    }

    private static func score(
        query: String,
        title: String,
        searchableText: String
    ) -> Int {
        if title == query { return 1_000 }
        let titleWords = words(in: title)
        if title.hasPrefix(query) { return 920 }
        if titleWords.contains(query) { return 900 }

        let queryTerms = words(in: query)
        guard !queryTerms.isEmpty else { return 0 }
        let searchableWords = words(in: searchableText)
        guard queryTerms.allSatisfy({ term in
            searchableWords.contains(where: {
                $0 == term || $0.hasPrefix(term)
            })
                || searchableText.contains(term)
        }) else {
            return 0
        }
        if searchableWords.contains(query) { return 840 }
        if searchableText.hasPrefix(query) { return 800 }
        return 600 + min(queryTerms.count, 10) * 10
    }

    private static func normalized(_ value: String) -> String {
        AssetDiscoveryRanking.normalized(value)
    }

    private static func words(in value: String) -> [String] {
        value.split {
            !$0.isLetter && !$0.isNumber
        }
        .map(String.init)
    }

    private func assetNumericSearchText(
        _ asset: WalletAsset
    ) -> String {
        var values = [
            EnglishNumbers.decimal(asset.balance),
            EnglishNumbers.decimal(asset.fiatValue)
        ]
        if let unitPrice = unitUSDPrice(for: asset) {
            values.append(
                EnglishNumbers.decimal(unitPrice)
            )
        }
        return Self.normalized(values.joined(separator: " "))
    }

    private static func makeAssetIndex(
        assets: [WalletAsset],
        transactions: [WalletTransaction]
    ) async -> WalletAssetDiscoveryIndex {
        WalletAssetDiscoveryIndex(
            walletAssets: assets,
            transactions: transactions
        )
    }

    private static func makeActionDocuments() async -> [ActionDocument] {
        actionItems.map { item in
            let title = normalized(
                WalletLocalization.string(item.titleKey)
            )
            let subtitle = normalized(
                item.resolvedSubtitle
            )
            return ActionDocument(
                item: item,
                title: title,
                searchableText: [title, subtitle]
                    .joined(separator: " ")
            )
        }
    }

    private static func makeWalletDocuments(
        _ wallets: [ManagedWallet]
    ) async -> [WalletDocument] {
        wallets.map { wallet in
            let title = normalized(wallet.name)
            let kindKey: String
            switch wallet.kind {
            case .created:
                kindKey = "settings.wallets.kind.created"
            case .importedRecoveryPhrase:
                kindKey = "settings.wallets.kind.recovery"
            case .importedPrivateKey:
                kindKey = "settings.wallets.kind.private_key"
            case .watchOnly:
                kindKey = "settings.wallets.kind.watch_only"
            case .hardware:
                kindKey = "settings.wallets.kind.hardware"
            }
            let kind = WalletLocalization.string(kindKey)
            return WalletDocument(
                wallet: wallet,
                title: title,
                searchableText: normalized(
                    "\(wallet.name) \(wallet.address) \(kind)"
                )
            )
        }
    }

    private static func makeNetworkDocuments() async
        -> [NetworkDocument]
    {
        AssetNetworkSelectorOption.allSupported.map { network in
            let aliases = AssetNetworkSearchMetadata.aliases(
                networkID: network.id,
                blockchain: network.blockchain,
                localizedName: network.localizedName
            )
            let title = normalized(network.localizedName)
            return NetworkDocument(
                network: network,
                title: title,
                searchableText: normalized(
                    (
                        [
                            network.localizedName,
                            network.id,
                            network.blockchain.rawValue
                        ] + aliases
                    )
                    .joined(separator: " ")
                )
            )
        }
    }

    private static let actionItems: [
        WalletUniversalSearchActionItem
    ] = [
        WalletUniversalSearchActionItem(
            id: "settings.tools.transaction_export",
            titleKey: "transaction_export.title",
            subtitleKey: "transaction_export.subtitle",
            action: .settings(.transactionExport)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.tools.network_fees",
            titleKey: "network_fees.title",
            subtitleKey: "network_fees.subtitle",
            action: .settings(.networkFeeDashboard)
        ),
        WalletUniversalSearchActionItem(
            id: "action.send",
            titleKey: "send.title",
            subtitleKey: "wallet.search.action.send.subtitle",
            action: .send
        ),
        WalletUniversalSearchActionItem(
            id: "action.receive",
            titleKey: "receive.title",
            subtitleKey: "wallet.search.action.receive.subtitle",
            action: .receive
        ),
        WalletUniversalSearchActionItem(
            id: "action.scan",
            titleKey: "wallet.home.action.scan",
            subtitleKey: "wallet.search.action.scan.subtitle",
            action: .scan
        ),
        WalletUniversalSearchActionItem(
            id: "navigation.assets",
            titleKey: "wallet.home.assets.title",
            subtitleKey: "wallet.search.navigation.assets.subtitle",
            action: .allAssets
        ),
        WalletUniversalSearchActionItem(
            id: "navigation.manage_assets",
            titleKey: "wallet.assets.manage.title",
            subtitleKey: "wallet.search.navigation.manage_assets.subtitle",
            action: .manageAssets
        ),
        WalletUniversalSearchActionItem(
            id: "navigation.activity",
            titleKey: "wallet.activity.all.title",
            subtitleKey: "wallet.search.navigation.activity.subtitle",
            action: .allActivity
        ),
        WalletUniversalSearchActionItem(
            id: "navigation.wallets",
            titleKey: "settings.wallets.title",
            subtitleKey: "wallet.search.navigation.wallets.subtitle",
            action: .walletSwitcher
        ),
        WalletUniversalSearchActionItem(
            id: "settings.root",
            titleKey: "settings.title",
            subtitleKey: "wallet.search.settings.root.subtitle",
            action: .settings(.root)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.wallets",
            titleKey: "settings.wallets.title",
            subtitleKey: "settings.wallets.subtitle",
            action: .settings(.wallets)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.wallets.create",
            titleKey: "settings.wallets.create",
            subtitleKey: "settings.wallets.empty.message",
            action: .settings(.wallets)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.wallets.import",
            titleKey: "settings.wallets.import",
            subtitleKey: "settings.wallets.empty.message",
            action: .settings(.wallets)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.wallets.restore_icloud",
            titleKey: "settings.wallets.restore_icloud",
            subtitleKey: "settings.wallets.backup.keychain.footer",
            action: .settings(.wallets)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.wallets.backup",
            titleKey: "wallet.creation.recovery.navigation",
            subtitleKey: "settings.wallets.backup.keychain.footer",
            action: .settings(.wallets)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.haptics",
            titleKey: "settings.haptics.title",
            subtitleKey: "settings.haptics.detail",
            action: .settings(.root)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.security",
            titleKey: "settings.security.title",
            subtitleKey: "settings.security.subtitle",
            action: .settings(.security)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.security.change_passcode",
            titleKey: "settings.security.change_passcode",
            subtitleKey: "settings.security.change_passcode.message",
            action: .settings(.security)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.security.biometrics",
            titleKey: "settings.security.biometrics.title",
            subtitleKey: "settings.security.biometrics.detail",
            action: .settings(.security)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.security.auto_lock",
            titleKey: "settings.security.auto_lock.section",
            subtitleKey: "settings.security.auto_lock.footer",
            action: .settings(.security)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.security.privacy_screen",
            titleKey: "settings.security.privacy_screen",
            subtitleKey: "settings.security.privacy_screen.detail",
            action: .settings(.security)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.appearance",
            titleKey: "settings.appearance.title",
            subtitleKey: "wallet.search.settings.appearance.subtitle",
            action: .settings(.appearance)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.language",
            titleKey: "settings.language.title",
            subtitleKey: "wallet.search.settings.language.subtitle",
            action: .settings(.language)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.currency",
            titleKey: "settings.currency.title",
            subtitleKey: "wallet.search.settings.currency.subtitle",
            action: .settings(.currency)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.notifications",
            titleKey: "settings.notifications.title",
            subtitleKey: "settings.notifications.subtitle",
            action: .settings(.notifications)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.notifications.received",
            titleKey: "settings.notifications.received",
            subtitleKey: "settings.notifications.received.detail",
            action: .settings(.notifications)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.notifications.sent",
            titleKey: "settings.notifications.sent",
            subtitleKey: "settings.notifications.sent.detail",
            action: .settings(.notifications)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.notifications.admin",
            titleKey: "settings.notifications.admin",
            subtitleKey: "settings.notifications.admin.detail",
            action: .settings(.notifications)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.about",
            titleKey: "settings.about.title",
            subtitleKey: "settings.about.version",
            subtitleText: AppBundleMetadata.localizedVersionSummary,
            action: .settings(.about)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.privacy",
            titleKey: "settings.about.privacy",
            subtitleKey: "wallet.search.settings.privacy.subtitle",
            action: .settings(.about)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.terms",
            titleKey: "settings.about.terms",
            subtitleKey: "wallet.search.settings.terms.subtitle",
            action: .settings(.about)
        ),
        WalletUniversalSearchActionItem(
            id: "settings.reset",
            titleKey: "settings.reset.action",
            subtitleKey: "wallet.search.settings.reset.subtitle",
            action: .settings(.reset)
        )
    ]
}
