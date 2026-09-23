import SwiftUI

/// A Send-owned destination; opening it never switches wallets or networks.
struct SendFeeDepositScreen: View {
    let funding: SendReviewFunding
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ReceiveNetworkLabel(networkName: funding.network.localizedName,
                                        logoSource: funding.network.logoSource)
                        .font(.subheadline.weight(.semibold))
                    ReceiveQRCodeAddressCard(address: funding.address, payload: funding.paymentPayload)
                    ReceiveAddressActionButtons(context: ReceiveShareContext(
                        address: funding.address, qrPayload: funding.paymentPayload,
                        assetSymbol: funding.network.symbol, assetLogoSource: funding.network.logoSource,
                        networkName: funding.network.localizedName, networkLogoSource: funding.network.logoSource
                    ))
                    Text(verbatim: EnglishNumbers.localized("receive.details.warning",
                        funding.network.symbol, funding.network.localizedName))
                        .font(.footnote)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    ReceiveMemoGuidance(blockchain: funding.network.blockchain)
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .background(WalletTheme.groupedBackground)
            .navigationTitle(funding.actionTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    WalletCloseButton { dismiss() }
                }
            }
        }
        .walletSheetPresentation(nativeGlass: false)
    }
}
