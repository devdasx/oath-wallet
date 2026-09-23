import SwiftUI

struct PrivateKeyNetworkSelectionView: View {
    let networks: [PrivateKeyImportNetwork]

    init(
        networks: [PrivateKeyImportNetwork] =
            PrivateKeyImportNetwork.allCases
    ) {
        self.networks = networks
    }

    var body: some View {
        List {
            Group {
                Section {
                    ForEach(networks, id: \.self) {
                        network in
                        NavigationLink(
                            value: OnboardingDestination
                                .privateKeyCredential(network)
                        ) {
                            PrivateKeyNetworkSelectionRow(
                                network: network
                            )
                        }
                        .accessibilityHint(
                            Text(
                                WalletLocalization.string(
                                    "import.private_key.network.accessibility_hint"
                                )
                            )
                        )
                    }
                } header: {
                    Text(
                        WalletLocalization.string(
                            "import.private_key.network.section"
                        )
                    )
                } footer: {
                    Text(
                        WalletLocalization.string(
                            "import.private_key.network.footer"
                        )
                    )
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle(
            Text(
                WalletLocalization.string(
                    "import.private_key.network.navigation.title"
                )
            )
        )
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivateKeyNetworkSelectionRow: View {
    let network: PrivateKeyImportNetwork

    var body: some View {
        Group {
            if network == .evm {
                HStack(alignment: .top, spacing: 12) {
                    networkLogo

                    VStack(alignment: .leading, spacing: 6) {
                        networkTitle

                        PrivateKeyEVMNetworkBadges()
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 12) {
                    networkLogo
                    networkTitle
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var networkLogo: some View {
        AssetLogoView(
            source: .nativeCoin(
                blockchain: network.blockchain
            ),
            size: 40,
            animatesChanges: false
        )
    }

    private var networkTitle: some View {
        Text(LocalizedStringKey(network.titleKey))
            .font(WalletTypography.listRowTitle)
            .foregroundStyle(WalletTheme.primaryLabel)
    }
}

private struct PrivateKeyEVMNetworkBadges: View {
    private let visibleNetworkLimit = 6

    private var networks: [ReceiveNetwork] {
        let capabilities = WalletCapabilities(
            scope: .privateKey(.evm)
        )
        return ReceiveNetworkCatalog.all.filter {
            capabilities.permits(networkID: $0.id)
        }
    }

    private var visibleNetworks: ArraySlice<ReceiveNetwork> {
        networks.prefix(visibleNetworkLimit)
    }

    private var additionalNetworkCount: Int {
        max(networks.count - visibleNetworks.count, 0)
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(visibleNetworks) { network in
                AssetLogoView(
                    source: network.logoSource,
                    size: 26,
                    animatesChanges: false
                )
            }

            if additionalNetworkCount > 0 {
                Text(
                    verbatim: "+"
                        + EnglishNumbers.integer(
                            Int64(additionalNetworkCount)
                        )
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(WalletTheme.secondaryLabel)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(
                    WalletTheme.tertiaryFill,
                    in: Capsule()
                )
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    NavigationStack {
        PrivateKeyNetworkSelectionView()
            .navigationDestination(
                for: OnboardingDestination.self
            ) { _ in
                Color.clear
            }
    }
}
