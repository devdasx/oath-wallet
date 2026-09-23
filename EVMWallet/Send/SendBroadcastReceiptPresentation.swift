import Foundation
import SwiftUI

enum SendBroadcastReceiptPresentation {
    static func showsNetworkVariant(
        for asset: SendAssetChoice
    ) -> Bool {
        let identity = AssetIdentityKey.canonical(asset.id)
        guard let token = ReceiveAssetCatalog.tokens.first(where: { token in
            token.variants.contains { variant in
                AssetIdentityKey.canonical(variant.assetIdentity)
                    == identity
            }
        }) else {
            return false
        }
        let matchingTokens = ReceiveAssetCatalog.tokens.filter {
            $0.name.caseInsensitiveCompare(token.name) == .orderedSame
                && $0.symbol.caseInsensitiveCompare(token.symbol)
                    == .orderedSame
        }
        return Set(
            matchingTokens.flatMap { $0.variants.map(\.networkID) }
        ).count > 1
    }

    static func compactIdentity(_ value: String) -> String {
        let leadingCount = 8
        let trailingCount = 6
        guard value.count > leadingCount + trailingCount + 3 else {
            return value
        }
        return "\(value.prefix(leadingCount))…\(value.suffix(trailingCount))"
    }

    static func networkFeeUSDValue(
        nativeFee: String?,
        nativeUnitUSDPrice: Decimal?
    ) -> Decimal? {
        guard let nativeFee,
              let nativeUnitUSDPrice,
              nativeUnitUSDPrice > 0,
              let fee = Decimal(
                  string: nativeFee,
                  locale: Locale(identifier: "en_US_POSIX")
              ), fee >= 0 else {
            return nil
        }
        return fee * nativeUnitUSDPrice
    }

    static func visibleTransactionHash(
        _ transactionHash: String?,
        submissionWasAccepted: Bool,
        submissionMayHaveSucceeded: Bool
    ) -> String? {
        guard submissionWasAccepted || submissionMayHaveSucceeded else {
            return nil
        }
        return transactionHash
    }

    static func showsSubmissionError(
        networkStatus: SendTransactionNetworkStatus?
    ) -> Bool {
        networkStatus != .confirmed
    }
}

struct SendBroadcastNetworkFeeLabel: View {
    let showsInformationButton: Bool
    @Binding var isInformationPresented: Bool

    private var informationTitle: String {
        WalletLocalization.string(
            "send.broadcast.network_fee.info.title"
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            Text("wallet.transaction.details.network_fee")

            if showsInformationButton {
                Button(action: UniHaptic.action(nil) {
                    isInformationPresented = true
                }) {
                    Image(systemName: "info.circle")
                        .symbolRenderingMode(.monochrome)
                        .imageScale(.medium)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .tint(WalletTheme.secondaryLabel)
                .popover(
                    isPresented: $isInformationPresented,
                    attachmentAnchor: .rect(.bounds)
                ) {
                    SendBroadcastNetworkFeeInfoPopover()
                        .presentationCompactAdaptation(.popover)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(informationTitle))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { UniHaptic.action(nil) { isInformationPresented = true }() }
                .accessibilityIdentifier("sendBroadcastNetworkFeeInfo")
            }
        }
    }
}

struct SendBroadcastSkeletonModifier: ViewModifier {
    let isActive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content
                .sendSkeletonPulse()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    Text("send.broadcast.loading.accessibility")
                )
        } else {
            content
        }
    }
}
