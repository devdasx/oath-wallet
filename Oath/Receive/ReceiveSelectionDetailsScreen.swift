import SwiftUI
import WalletCore

/// Classic receive layout with the centered network badge, QR code, address,
/// and Copy/Share actions.
struct ReceiveSelectionDetailsScreen: View {
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
        if let chain = BitcoinFamilyChain.allCases.first(where: { $0.blockchain == network.blockchain && $0.supportsFamilyHD }) {
            BitcoinFamilyHDReceiveContent(asset: WalletAsset(id: "\(chain.networkID):native", name: chain.name,
                symbol: chain.symbol, logoSource: .nativeCoin(blockchain: chain.blockchain), network: chain.blockchain,
                balance: 0, fiatValue: 0, balanceText: "0", balanceAtomic: "0", decimals: 8, receiveAddress: walletAddress),
                chain: chain, fallbackAddress: walletAddress, database: database)
        } else { standardContent }
    }

    private var standardContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let effectiveAddress {
                    qrPresentation(address: effectiveAddress)
                    actionButtons

                    Text(
                        EnglishNumbers.localized(
                            "receive.details.warning",
                            token.symbol,
                            network.localizedName
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                    ReceiveMemoGuidance(blockchain: network.blockchain)
                        .multilineTextAlignment(.center)
                } else if didResolveNetworkAddress {
                    VStack(spacing: 10) {
                        Text("receive.address.unavailable")
                            .font(.headline)

                        Text("receive.address.unavailable.message")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 360, minHeight: 280)
                } else {
                    Text("receive.details.loading")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 360, minHeight: 280)
                }
            }
            .walletActionScreenMargins()
            .padding(.top, 20)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
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

    private var receiveTitle: some View {
        HStack(spacing: 6) {
            Text("receive.title")

            ReceiveTokenLogo(
                token: token,
                selectedVariant: variant,
                size: 22
            )

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

    private func qrPresentation(address: String) -> some View {
        VStack(spacing: 18) {
            ReceiveNetworkLabel(
                networkName: network.localizedName,
                logoSource: network.logoSource
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(WalletTheme.mutedSecondaryFill, in: Capsule())

            if let paymentURI {
                ReceiveQRCodeAddressCard(
                    address: address,
                    payload: paymentURI,
                    showsBrandMark: true
                )
            } else {
                VStack(spacing: 6) {
                    Text("receive.address.unavailable")
                        .font(.headline)
                        .foregroundStyle(WalletTheme.qrCodeInk)

                    Text("receive.address.unavailable.message")
                        .font(.subheadline)
                        .foregroundStyle(WalletTheme.qrCodeInk.opacity(0.64))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 292, minHeight: 220)
                .background(
                    WalletTheme.qrCodeSurface,
                    in: RoundedRectangle(
                        cornerRadius: 28,
                        style: .continuous
                    )
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let effectiveAddress {
            ReceiveAddressActionButtons(
                context: ReceiveShareContext(
                    address: effectiveAddress,
                    qrPayload: paymentURI ?? effectiveAddress,
                    assetSymbol: token.symbol,
                    assetLogoSource: variant.logoSource,
                    networkName: network.localizedName,
                    networkLogoSource: network.logoSource
                )
            )
        }
    }

    private var paymentURI: String? {
        guard let effectiveAddress else { return nil }

        return ReceiveAddressResolver.paymentPayload(
            address: effectiveAddress,
            network: network,
            contractAddress: variant.contractAddress
        )
    }

}

private struct ReceiveTokenLogo: View {
    let token: ReceiveToken
    var selectedVariant: ReceiveTokenVariant? = nil
    var size: CGFloat = 44

    private var variant: ReceiveTokenVariant? {
        selectedVariant ?? token.variants.first
    }

    var body: some View {
        AssetLogoView(
            source: variant?.logoSource ?? .unavailable,
            size: size
        )
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
