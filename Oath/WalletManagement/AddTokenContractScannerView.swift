import SwiftUI

struct AddTokenContractScannerView: View {
    let network: ReceiveNetwork
    let onRecognized: (String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var reviewContract: String?
    @State private var recognitionError: String?

    var body: some View {
        ZStack {
            if let reviewContract {
                SmartScannerReviewPanel(
                    presentation: reviewPresentation(
                        contract: reviewContract
                    ),
                    onConfirm: {
                        confirm(contract: reviewContract)
                    },
                    onCancel: cancelReview
                )
            } else {
                scannerContent
            }
        }
        .background(WalletBackground())
        .navigationTitle("wallet.assets.add_token.scanner.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                WalletCloseButton {
                    dismiss()
                }
                .accessibilityIdentifier("qrScannerClose")
            }
        }
    }

    private var scannerContent: some View {
        GeometryReader { proxy in
            VStack(spacing: 18) {
                ZStack {
                    if let recognitionError {
                        Text(verbatim: recognitionError)
                            .foregroundStyle(WalletTheme.danger)
                    } else {
                        Text(
                            "wallet.assets.add_token.scanner.instruction"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                scannerViewport
                    .frame(
                        height: min(
                            520,
                            max(280, proxy.size.height * 0.68)
                        )
                    )

                Spacer(minLength: 0)
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var scannerViewport: some View {
        NativeQRCodeScannerView(
            unavailableTitle:
                "wallet.assets.add_token.scanner.unavailable.title",
            unavailableMessage:
                "wallet.assets.add_token.scanner.unavailable.message",
            onPayload: recognize
        )
        .clipShape(
            WalletConcentricRectangle(minimumCornerRadius: 26)
        )
        .overlay {
            WalletConcentricRectangle(minimumCornerRadius: 26)
            .stroke(.secondary.opacity(0.18), lineWidth: 1)
        }
    }

    @MainActor
    private func recognize(_ payload: String) -> Bool {
        guard
            let contract = CustomTokenAddress.extracted(
                from: payload,
                networkID: network.id
            )
        else {
            recognitionError = WalletLocalization.string(
                "wallet.assets.add_token.scanner.review.error"
            )
            UniHaptic.play(.error)
            return false
        }
        recognitionError = nil
        reviewContract = contract
        UniHaptic.play(.successQuiet)
        return true
    }

    private func reviewPresentation(
        contract: String
    ) -> SmartScannerReviewPresentation {
        SmartScannerReviewPresentation(
            kind: .tokenContract,
            heroLogoSource: network.logoSource,
            titleKey:
                "wallet.assets.add_token.scanner.review.title",
            detailKey:
                "wallet.assets.add_token.scanner.review.detail",
            rows: [
                SmartScannerReviewRow(
                    id: "type",
                    titleKey: "smart_scanner.review.field.type",
                    value: WalletLocalization.string(
                        "wallet.assets.add_token.scanner.review.type"
                    )
                ),
                SmartScannerReviewRow(
                    id: "network",
                    titleKey: "smart_scanner.review.field.network",
                    value: network.localizedName
                ),
                SmartScannerReviewRow(
                    id: "contract",
                    titleKey: "smart_scanner.review.field.address",
                    value: contract,
                    valueStyle: .monospaced
                )
            ],
            warningKey:
                "wallet.assets.add_token.scanner.review.warning",
            primaryActionKey:
                "wallet.assets.add_token.scanner.review.action"
        )
    }

    @MainActor
    private func confirm(contract: String) {
        guard onRecognized(contract) else {
            reviewContract = nil
            recognitionError = WalletLocalization.string(
                "wallet.assets.add_token.scanner.review.error"
            )
            UniHaptic.play(.error)
            return
        }
    }

    @MainActor
    private func cancelReview() {
        reviewContract = nil
        recognitionError = nil
        UniHaptic.play(.selection)
    }

}
