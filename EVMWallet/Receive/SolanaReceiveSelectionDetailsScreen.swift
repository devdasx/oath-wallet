import SwiftUI

struct SolanaReceiveSelectionDetailsScreen: View {
    let token: ReceiveToken
    let variant: ReceiveTokenVariant
    let accounts: SolanaAccountSet?

    @State private var selectedKind = SolanaDerivationKind.phantom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        token: ReceiveToken,
        variant: ReceiveTokenVariant,
        accounts: SolanaAccountSet?
    ) {
        self.token = token
        self.variant = variant
        self.accounts = accounts
    }

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
                    unavailableContent
                }
            }
            .walletActionScreenMargins()
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
                token.symbol
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
        accounts?.account(for: selectedKind)?.address
            ?? accounts?.primary.address
    }

    private var availableKinds: [SolanaDerivationKind] {
        accounts?.all.map(\.kind) ?? SolanaDerivationKind.allCases
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
            assetSymbol: token.symbol,
            assetLogoSource: variant.logoSource,
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
                token.symbol,
                WalletLocalization.string("network.solana.name")
            )
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    private var unavailableContent: some View {
        ContentUnavailableView(
            "receive.address.unavailable",
            systemImage: "qrcode",
            description: Text("receive.address.unavailable.message")
        )
        .frame(minHeight: 320)
    }

}
