import SwiftUI

struct WalletActivityNetworkFilterView: View {
    let networks: [WalletActivityNetworkOption]
    @Binding var selectedNetworkIDs: Set<String>

    var body: some View {
        List {
            Group {
                if networks.isEmpty {
                    Section {
                        WalletEmptyStateView(
                            "wallet.activity.filter.network.empty"
                        )
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                    }
                } else {
                    Section("wallet.activity.filter.network.available") {
                        ForEach(networks) { network in
                            Toggle(
                                isOn: networkSelectionBinding(for: network.id)
                            ) {
                                Text(verbatim: network.name)
                            }
                        }
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .navigationTitle("wallet.activity.filter.network.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func networkSelectionBinding(
        for networkID: String
    ) -> Binding<Bool> {
        Binding(
            get: {
                selectedNetworkIDs.isEmpty
                    || selectedNetworkIDs.contains(networkID)
            },
            set: { isSelected in
                if selectedNetworkIDs.isEmpty {
                    selectedNetworkIDs = Set(networks.map(\.id))
                }

                if isSelected {
                    selectedNetworkIDs.insert(networkID)
                } else {
                    selectedNetworkIDs.remove(networkID)
                }

                if selectedNetworkIDs.count == networks.count {
                    selectedNetworkIDs.removeAll()
                }
            }
        )
    }
}
