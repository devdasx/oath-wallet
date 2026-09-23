import SwiftUI

struct AddTokenNetworkSelectionView: View {
    let database: WalletDatabase
    let walletAssets: [WalletAsset]
    let transactions: [WalletTransaction]
    let onTokenSaved: (WalletAsset) -> Void
    private let networks: [ReceiveNetwork]

    @Environment(\.dismiss) private var dismiss

    init(
        database: WalletDatabase,
        walletAssets: [WalletAsset],
        transactions: [WalletTransaction],
        capabilities: WalletCapabilities,
        onTokenSaved: @escaping (WalletAsset) -> Void
    ) {
        self.database = database
        self.walletAssets = walletAssets
        self.transactions = transactions
        self.onTokenSaved = onTokenSaved
        let availableNetworks = Self.supportedNetworks(
            for: capabilities
        )
        networks = WalletNetworkSelectionOrdering(
            walletAssets: walletAssets,
            transactions: transactions
        )
        .ordered(
            availableNetworks,
            networkID: \.id
        )
    }

    nonisolated static func supportedNetworks(
        for capabilities: WalletCapabilities
    ) -> [ReceiveNetwork] {
        ReceiveNetworkCatalog.all.filter { network in
            CustomTokenAddress.supports(networkID: network.id)
                && capabilities.permits(networkID: network.id)
        }
    }

    var body: some View {
        List {
            Group {
                Section {
                    ForEach(networks) { network in
                        NavigationLink {
                            Group {
                                AddTokenContractLookupView(
                                    database: database,
                                    network: network,
                                    onTokenSaved: onTokenSaved
                                )
                            }

                        } label: {
                            AddTokenNetworkRow(network: network)
                        }
                    }
                } header: {
                    Text("wallet.assets.add_token.network.section")
                        .font(.subheadline.weight(.regular))
                } footer: {
                    Text("wallet.assets.add_token.network.footer")
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("wallet.assets.add_token.network.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                WalletCloseButton {
                    dismiss()
                }
            }
        }
    }
}

private struct AddTokenNetworkRow: View {
    let network: ReceiveNetwork

    var body: some View {
        LabeledContent {
            Text(verbatim: network.symbol)
                .foregroundStyle(WalletTheme.secondaryLabel)
        } label: {
            HStack(spacing: 12) {
                AssetLogoView(
                    source: network.logoSource,
                    size: 36,
                    animatesChanges: false
                )
                Text(verbatim: network.localizedName)
                    .foregroundStyle(WalletTheme.primaryLabel)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
