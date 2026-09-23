import SwiftUI

struct WalletActivityView: View {
    let transactions: [WalletTransaction]
    let networkValueAssets: [WalletAsset]
    let contentRevision: UUID
    let isBalanceHidden: Bool
    private let availableNetworks: [WalletActivityNetworkOption]
    private let availableDateRange: ClosedRange<Date>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var searchText = ""
    @State private var activityFilter = WalletActivityFilter()
    @State private var isFilterPresented = false
    @State private var displayedTransactions: [WalletTransaction]

    init(
        transactions: [WalletTransaction],
        networkValueAssets: [WalletAsset] = [],
        contentRevision: UUID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        ),
        isBalanceHidden: Bool
    ) {
        self.transactions = transactions
        self.networkValueAssets = networkValueAssets
        self.contentRevision = contentRevision
        self.isBalanceHidden = isBalanceHidden
        let catalogByID = Dictionary(
            uniqueKeysWithValues:
                AssetNetworkSelectorOption.allSupported.map {
                    ($0.id, $0)
                }
        )
        var optionsByID: [String: WalletActivityNetworkOption] = [:]
        for transaction in transactions {
            guard
                let identifier =
                    transaction.metadata.blockchainIdentifier,
                let canonicalNetworkID =
                    WalletNetworkSelectionOrdering.canonicalNetworkID(
                        identifier
                    )
            else {
                continue
            }
            optionsByID[canonicalNetworkID] =
                WalletActivityNetworkOption(
                    id: canonicalNetworkID,
                    name:
                        catalogByID[canonicalNetworkID]?.localizedName
                        ?? canonicalNetworkID.uppercased()
                )
        }
        let catalogFallback = optionsByID.values.sorted {
            $0.name.localizedStandardCompare($1.name)
                == .orderedAscending
        }
        availableNetworks = WalletNetworkSelectionOrdering(
            walletAssets: networkValueAssets,
            transactions: transactions
        )
        .ordered(catalogFallback, networkID: \.id)

        let dates = transactions.compactMap(\.metadata.date)
        if let earliestDate = dates.min(),
           let latestDate = dates.max() {
            availableDateRange = earliestDate...latestDate
        } else {
            availableDateRange = nil
        }
        _displayedTransactions = State(initialValue: transactions)
    }

    var body: some View {
        ZStack {
            WalletTheme.groupedBackground
                .ignoresSafeArea()
                .accessibilityHidden(true)

            if displayedTransactions.isEmpty {
                if !normalizedSearchText.isEmpty {
                    WalletSearchEmptyStateView()
                } else if activityFilter.isActive {
                    WalletEmptyStateView(
                        "wallet.activity.filter.empty.title",
                        message: "wallet.activity.filter.empty.message"
                    )
                } else {
                    WalletEmptyStateView(
                        "wallet.home.empty.activity.title",
                        message: "wallet.home.empty.activity.message"
                    )
                }
            } else {
                List {
                    Group {
                        Section {
                            ForEach(displayedTransactions) { transaction in
                                NavigationLink {
                                    Group {
                                        WalletTransactionDetailsView(
                                            transaction: transaction,
                                            isBalanceHidden: isBalanceHidden
                                        )
                                    }

                                } label: {
                                    WalletTransactionRow(
                                        transaction: transaction,
                                        isBalanceHidden: isBalanceHidden
                                    )
                                }
                            }
                        }
                    }
                    .walletListRowSurface()
                }
                .walletListAppearance()
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("wallet.activity.all.title")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text("wallet.activity.search.prompt")
        )
        .walletTextInputDirection()
        .walletAutomaticSearchToolbarBehavior()
        .task(id: SearchRequest(
            query: normalizedSearchText,
            filter: activityFilter,
            contentRevision: contentRevision
        )) {
            await prepareDisplayedTransactions()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: UniHaptic.action(nil) {
                    isFilterPresented = true
                }) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .fontWeight(WalletSFSymbol.weight)
                }
                .accessibilityLabel(
                    Text("wallet.activity.filter.action")
                )
                .accessibilityValue(
                    Text(
                        EnglishNumbers.localized(
                            "wallet.activity.filter.active_count",
                            EnglishNumbers.integer(
                                Int64(activityFilter.activeCriteriaCount)
                            )
                        )
                    )
                )
            }
        }
        .sheet(isPresented: $isFilterPresented) {
            WalletActivityFilterView(
                filter: activityFilter,
                availableNetworks: availableNetworks,
                availableDateRange: availableDateRange
            ) { filter in
                if reduceMotion {
                    activityFilter = filter
                } else {
                    withAnimation(.smooth(duration: 0.25)) {
                        activityFilter = filter
                    }
                }
            }
            .walletSheetPresentation(nativeGlass: false)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func prepareDisplayedTransactions() async {
        let query = normalizedSearchText
        var filter = activityFilter
        filter.networkIDs = Set(
            filter.networkIDs.compactMap {
                WalletNetworkSelectionOrdering.canonicalNetworkID($0)
            }
        )

        if query.isEmpty, !filter.isActive {
            AssetListRenderingWindow.updateWithoutAnimation {
                displayedTransactions = transactions
            }
            return
        }

        if !query.isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
        }

        let source = transactions
        let result = await Task.detached(priority: .userInitiated) {
            Self.filtered(
                source,
                query: query,
                filter: filter
            )
        }.value
        guard !Task.isCancelled else { return }
        AssetListRenderingWindow.updateWithoutAnimation {
            displayedTransactions = result
        }
    }

    nonisolated private static func filtered(
        _ transactions: [WalletTransaction],
        query: String,
        filter: WalletActivityFilter
    ) -> [WalletTransaction] {
        transactions.filter { transaction in
            guard filter.includes(transaction) else { return false }
            guard !query.isEmpty else { return true }

            let metadata = transaction.metadata
            let values = [
                transaction.activityTitle,
                transaction.activitySubtitle,
                transaction.kind.localizedTitle,
                transaction.historyDetail,
                transaction.time,
                transaction.assetSymbol,
                WalletLocalization.string(
                    transaction.status.localizedKey
                ),
                metadata.transactionHash,
                metadata.fromAddress,
                metadata.toAddress,
                metadata.contractAddress,
                metadata.blockchainIdentifier,
                metadata.blockchainIdentifier.flatMap {
                    ReceiveNetworkCatalog.network(for: $0)?
                        .localizedName
                }
            ]
            return values.compactMap { $0 }.contains {
                $0.localizedStandardContains(query)
            }
        }
    }

    private struct SearchRequest: Hashable {
        let query: String
        let filter: WalletActivityFilter
        let contentRevision: UUID
    }
}
