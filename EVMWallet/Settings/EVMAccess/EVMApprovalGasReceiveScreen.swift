import SwiftUI

/// Receive destination owned by the EVM permission-revocation flow.
struct EVMApprovalGasReceiveScreen: View {
    let funding: EVMApprovalGasFunding

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ReceiveNetworkLabel(
                        networkName: funding.network.localizedName,
                        logoSource: funding.network.logoSource
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WalletTheme.secondaryLabel)

                    ReceiveQRCodeAddressCard(
                        address: funding.address,
                        payload: funding.paymentPayload
                    )

                    ReceiveAddressActionButtons(context: ReceiveShareContext(
                        address: funding.address,
                        qrPayload: funding.paymentPayload,
                        assetSymbol: funding.network.symbol,
                        assetLogoSource: funding.network.logoSource,
                        networkName: funding.network.localizedName,
                        networkLogoSource: funding.network.logoSource
                    ))

                    Text(verbatim: EnglishNumbers.localized(
                        "receive.details.warning",
                        funding.network.symbol,
                        funding.network.localizedName
                    ))
                    .font(.footnote)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .background(WalletTheme.groupedBackground)
            .navigationTitle(EnglishNumbers.localized(
                "receive.details.navigation.title", funding.network.symbol
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    WalletCloseButton { dismiss() }
                }
            }
        }
        .walletSheetBackground(nativeGlass: false)
    }
}
