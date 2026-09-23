import SwiftUI
import WalletCore

struct SelectedAssetReceiveScreen: View {
    private struct Destination {
        let token: ReceiveToken
        let variant: ReceiveTokenVariant
    }

    let asset: WalletAsset
    let walletAddress: String
    let database: WalletDatabase
    let solanaAccounts: SolanaAccountSet?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var resolvedDestination: Destination?
    @State private var didResolveDestination = false

    init(
        asset: WalletAsset,
        walletAddress: String,
        database: WalletDatabase,
        solanaAccounts: SolanaAccountSet? = nil
    ) {
        self.asset = asset
        self.walletAddress = walletAddress
        self.database = database
        self.solanaAccounts = solanaAccounts
    }

    var body: some View {
        ZStack {
            if asset.network == .solana {
                SelectedSolanaAssetReceiveScreen(
                    asset: asset,
                    accounts: solanaAccounts
                )
            } else if asset.network == .bitcoin {
                BitcoinHDReceiveDetailsContent(
                    asset: asset,
                    fallbackAddress: walletAddress,
                    database: database
                )
            } else if let chain = BitcoinFamilyChain.allCases.first(where: {
                $0.blockchain == asset.network && $0.supportsFamilyHD
            }) {
                BitcoinFamilyHDReceiveContent(asset: asset, chain: chain, fallbackAddress: walletAddress, database: database)
            } else if let address = effectiveIndependentAddress,
                      let networkPresentation {
                IndependentNetworkReceiveDetailsContent(
                    asset: asset,
                    address: address,
                    network: networkPresentation
                )
            } else if let resolvedDestination {
                if let destinationAddress {
                    ReceiveDetailsContent(
                        token: resolvedDestination.token,
                        variant: resolvedDestination.variant,
                        walletAddress: destinationAddress,
                        database: database
                    )
                } else {
                    unavailableAddressContent
                }
            } else if didResolveDestination {
                unavailableAddressContent
            } else {
                SelectedAssetReceivePendingView(asset: asset)
            }
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: didResolveDestination
        )
        .task(id: asset.id) {
            await resolveDestination()
        }
        .onAppear {
        }
    }

    private var destinationAddress: String? {
        if usesIndependentAddress {
            return effectiveIndependentAddress
        }

        if let address = asset.receiveAddress, !address.isEmpty {
            return address
        }
        return walletAddress
    }

    private var usesIndependentAddress: Bool {
        ReceiveAddressResolver.requiresIndependentAddress(
            for: asset.network
        )
    }

    private var effectiveIndependentAddress: String? {
        ReceiveAddressResolver.validatedIndependentAddress(
            asset.receiveAddress,
            for: asset.network
        )
    }

    private var networkPresentation: ReceiveNetworkPresentation? {
        ReceiveNetworkPresentation(asset: asset)
    }

    private var unavailableAddressContent: some View {
        ContentUnavailableView(
            "receive.address.unavailable",
            systemImage: "qrcode",
            description: Text(
                "receive.address.unavailable.message"
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WalletTheme.groupedBackground)
        .navigationTitle(asset.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func resolveDestination() async {
        resolvedDestination = nil
        didResolveDestination = false
        if asset.network == .solana {
            didResolveDestination = true
            return
        }

        if usesIndependentAddress {
            didResolveDestination = true
            return
        }

        // Let the sheet commit its first frame before replacing the
        // shape-matched loading UI with the resolved receive content.
        await Task.yield()
        resolvedDestination = destination
        didResolveDestination = true
    }

    private var destination: Destination? {
        if let selection = ReceiveAssetCatalog.selection(
            assetIdentity: asset.id
        ) {
            return Destination(
                token: selection.token,
                variant: selection.variant
            )
        }

        guard let network = asset.network,
              let receiveNetwork = ReceiveNetworkCatalog.all.first(where: {
                  $0.blockchain == network
              }) else {
            return nil
        }

        if let contractAddress =
            asset.logoSource.checksummedContractAddress {
            let identity =
                "\(receiveNetwork.id):\(contractAddress.lowercased())"
            if let selection = ReceiveAssetCatalog.selection(
                assetIdentity: identity
            ) {
                return Destination(
                    token: selection.token,
                    variant: selection.variant
                )
            }
            return nil
        }

        let token = ReceiveToken.nativeAsset(for: receiveNetwork)
        guard let variant = token.variants.first else { return nil }
        return Destination(token: token, variant: variant)
    }
}

struct IndependentNetworkReceiveDetailsContent: View {
    let asset: WalletAsset
    let address: String
    let network: ReceiveNetworkPresentation

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ReceiveNetworkLabel(
                    networkName: network.localizedName,
                    logoSource: network.logoSource
                )
                .font(
                    .subheadline.weight(
                        WalletTypography.contentTitleWeight
                    )
                )
                .foregroundStyle(.secondary)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(WalletTheme.mutedSecondaryFill, in: Capsule())

                ReceiveQRCodeAddressCard(
                    address: address,
                    payload: address,
                    showsBrandMark: true
                )

                ReceiveAddressActionButtons(
                    context: ReceiveShareContext(
                        address: address,
                        qrPayload: address,
                        assetSymbol: asset.symbol,
                        assetLogoSource: asset.logoSource,
                        networkName: network.localizedName,
                        networkLogoSource: network.logoSource
                    )
                )

                Text(
                    EnglishNumbers.localized(
                        "receive.bitcoin_family.warning",
                        asset.symbol,
                        network.localizedName
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

                ReceiveMemoGuidance(blockchain: network.blockchain)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
        .background(WalletTheme.groupedBackground)
        .navigationTitle(
            EnglishNumbers.localized(
                "receive.details.navigation.title",
                asset.symbol
            )
        )
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SelectedAssetReceivePendingView: View {
    let asset: WalletAsset

    var body: some View {
        Text("receive.details.loading")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WalletTheme.groupedBackground)
        .navigationTitle(
            EnglishNumbers.localized(
                "receive.details.navigation.title",
                asset.symbol
            )
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text("receive.title")

                    AssetLogoView(
                        source: asset.logoSource,
                        size: 22
                    )
                    .accessibilityHidden(true)

                    Text(verbatim: asset.symbol)
                }
                .font(WalletTypography.sheetTitle)
            }
        }
    }
}
