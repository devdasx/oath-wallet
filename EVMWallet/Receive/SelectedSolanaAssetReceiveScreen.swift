import SwiftUI

struct SelectedSolanaAssetReceiveScreen: View {
    let asset: WalletAsset
    let accounts: SolanaAccountSet?

    @State private var selectedKind = SolanaDerivationKind.phantom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let address {
                    networkBadge
                    ReceiveQRCodeAddressCard(
                        address: address,
                        payload: address,
                        showsBrandMark: true,
                        animatesPayloadReplacement: true
                    )
                    ReceiveAddressActionButtons(
                        context: shareContext(address)
                    )
                    warning
                } else {
                    ContentUnavailableView(
                        "receive.address.unavailable",
                        systemImage: "qrcode",
                        description: Text(
                            "receive.address.unavailable.message"
                        )
                    )
                    .frame(minHeight: 320)
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.28),
                value: address
            )
        }
        .background(WalletTheme.groupedBackground)
        .navigationTitle(
            EnglishNumbers.localized(
                "receive.details.navigation.title",
                asset.symbol
            )
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SolanaReceivePathMenu(
                    availableKinds: availableKinds,
                    selectedKind: $selectedKind
                )
            }
        }
    }

    private var address: String? {
        resolvedAccounts?.account(for: selectedKind)?.address
            ?? resolvedAccounts?.primary.address
    }

    private var availableKinds: [SolanaDerivationKind] {
        resolvedAccounts?.all.map(\.kind)
            ?? SolanaDerivationKind.allCases
    }

    private var networkBadge: some View {
        ReceiveNetworkLabel(
            networkName: WalletLocalization.string(
                "network.solana.name"
            ),
            logoSource: .nativeCoin(blockchain: .solana)
        )
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(WalletTheme.mutedSecondaryFill, in: Capsule())
    }

    private func shareContext(_ address: String) -> ReceiveShareContext {
        ReceiveShareContext(
            address: address,
            qrPayload: address,
            assetSymbol: asset.symbol,
            assetLogoSource: asset.logoSource,
            networkName: WalletLocalization.string(
                "network.solana.name"
            ),
            networkLogoSource: .network(
                blockchain: .solana
            )
        )
    }

    private var warning: some View {
        Text(
            EnglishNumbers.localized(
                "receive.details.warning",
                asset.symbol,
                WalletLocalization.string("network.solana.name")
            )
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    private var resolvedAccounts: SolanaAccountSet? {
        if let accounts {
            return accounts
        }
        guard
            let address = ReceiveAddressResolver
                .validatedIndependentAddress(
                    asset.receiveAddress,
                    for: .solana
                )
        else {
            return nil
        }
        return SolanaAccountSet(
            primary: SolanaAccountMaterial(
                kind: .phantom,
                address: address,
                publicKey: "",
                derivationPath:
                    SolanaDerivationKind.phantom.derivationPath
            ),
            alternatives: []
        )
    }

}
