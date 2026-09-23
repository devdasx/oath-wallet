import SwiftUI
import WalletCore

/// Preserved native-list receive layout.
struct ReceiveSelectionDetailsListScreen: View {
    let token: ReceiveToken
    let variant: ReceiveTokenVariant
    let walletAddress: String
    let database: WalletDatabase

    @State private var resolvedNetworkAddress: String?
    @State private var didResolveNetworkAddress = false

    init(
        token: ReceiveToken,
        variant: ReceiveTokenVariant,
        walletAddress: String,
        database: WalletDatabase
    ) {
        self.token = token
        self.variant = variant
        self.walletAddress = walletAddress
        self.database = database
    }

    private var network: ReceiveNetwork {
        variant.network ?? ReceiveNetworkCatalog.all[0]
    }

    private var effectiveAddress: String? {
        let candidateAddress = resolvedNetworkAddress ?? walletAddress
        if ReceiveAddressResolver.requiresIndependentAddress(
            for: network.blockchain
        ) {
            return ReceiveAddressResolver.validatedIndependentAddress(
                candidateAddress,
                for: network.blockchain
            )
        }

        guard AnkrAPIClient.isValidAddress(candidateAddress) else {
            return nil
        }
        return candidateAddress
    }

    var body: some View {
        List {
            Group {
                if let effectiveAddress {
                    networkSection
                    qrSection(address: effectiveAddress)
                    actionsSection(effectiveAddress)
                    warningSection
                } else if didResolveNetworkAddress {
                    unavailableSection
                } else {
                    Section {
                        Text("receive.details.loading")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .navigationTitle(
            EnglishNumbers.localized(
                "receive.details.navigation.title",
                token.symbol
            )
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                receiveTitle
            }
        }
        .onAppear {
        }
        .task(id: variant.assetIdentity) {
            await resolveNetworkAddress()
        }
    }

    private var networkSection: some View {
        Section {
            ReceiveNetworkLabel(
                networkName: network.localizedName,
                logoSource: network.logoSource,
                logoSize: 28,
                spacing: 10
            )
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)

            ReceiveMemoGuidance(blockchain: network.blockchain)
        }
    }

    private func qrSection(address: String) -> some View {
        Section {
            if let paymentURI {
                ReceiveQRCodeAddressCard(
                    address: address,
                    payload: paymentURI,
                    showsBrandMark: true
                )
                    .frame(maxWidth: 360)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowInsets(
                        EdgeInsets(
                            top: 12,
                            leading: 16,
                            bottom: 12,
                            trailing: 16
                        )
                    )
            } else {
                ContentUnavailableView(
                    "receive.address.unavailable",
                    systemImage: "qrcode",
                    description: Text(
                        "receive.address.unavailable.message"
                    )
                )
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func actionsSection(_ address: String) -> some View {
        Section {
            ReceiveAddressActionButtons(
                context: ReceiveShareContext(
                    address: address,
                    qrPayload: paymentURI ?? address,
                    assetSymbol: token.symbol,
                    assetLogoSource: variant.logoSource,
                    networkName: network.localizedName,
                    networkLogoSource: network.logoSource
                )
            )
            .walletActionUsesContainerMargins()
        }
    }

    private var warningSection: some View {
        Section {
            Text(
                EnglishNumbers.localized(
                    "receive.details.warning",
                    token.symbol,
                    network.localizedName
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var unavailableSection: some View {
        Section {
            ContentUnavailableView(
                "receive.address.unavailable",
                systemImage: "qrcode",
                description: Text(
                    "receive.address.unavailable.message"
                )
            )
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
    }

    private var receiveTitle: some View {
        HStack(spacing: 6) {
            Text("receive.title")

            AssetLogoView(
                source: variant.logoSource,
                size: 22
            )
            .accessibilityHidden(true)

            Text(verbatim: token.symbol)
        }
        .font(WalletTypography.sheetTitle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            EnglishNumbers.localized(
                "receive.details.navigation.title",
                token.symbol
            )
        )
    }

    private var paymentURI: String? {
        guard let effectiveAddress else { return nil }

        return ReceiveAddressResolver.paymentPayload(
            address: effectiveAddress,
            network: network,
            contractAddress: variant.contractAddress
        )
    }

    @MainActor
    private func resolveNetworkAddress() async {
        resolvedNetworkAddress = nil
        didResolveNetworkAddress = false

        guard ReceiveAddressResolver.requiresIndependentAddress(
            for: network.blockchain
        ),
              effectiveAddress == nil else {
            didResolveNetworkAddress = true
            return
        }
        do {
            resolvedNetworkAddress =
                try await ReceiveAddressResolver.independentAddress(
                    for: network.blockchain,
                    database: database
                )
        } catch {
        }
        guard !Task.isCancelled else { return }
        didResolveNetworkAddress = true
    }

}
