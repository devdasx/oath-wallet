import SwiftUI

struct BitcoinTransactionQRScannerView: View {
    let onRecognized: (BitcoinTransactionBroadcastPreview) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var recognitionError: String?

    private let service: BitcoinTransactionBroadcastService

    init(
        service: BitcoinTransactionBroadcastService =
            BitcoinTransactionBroadcastService(),
        onRecognized: @escaping (
            BitcoinTransactionBroadcastPreview
        ) -> Void
    ) {
        self.service = service
        self.onRecognized = onRecognized
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 18) {
                if let recognitionError {
                    Text(verbatim: recognitionError)
                        .foregroundStyle(WalletTheme.danger)
                } else {
                    Text("settings.tools.broadcast_bitcoin.input.footer")
                        .foregroundStyle(WalletTheme.secondaryLabel)
                }

                NativeQRCodeScannerView(
                    unavailableTitle:
                        "import.scanner.unavailable.title",
                    unavailableMessage:
                        "import.scanner.unavailable.message",
                    onPayload: recognize
                )
                .clipShape(
                    WalletConcentricRectangle(minimumCornerRadius: 26)
                )
                .overlay {
                    WalletConcentricRectangle(minimumCornerRadius: 26)
                    .stroke(.secondary.opacity(0.18), lineWidth: 1)
                }
                .frame(
                    height: min(
                        560,
                        max(300, proxy.size.height * 0.72)
                    )
                )

                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 680)
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WalletBackground())
        .navigationTitle("settings.tools.broadcast_bitcoin.title")
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

    @MainActor
    private func recognize(_ payload: String) -> Bool {
        do {
            let preview = try service.preview(for: payload)
            recognitionError = nil
            onRecognized(preview)
            dismiss()
            return true
        } catch {
            recognitionError = WalletLocalization.string(
                "settings.tools.broadcast_bitcoin.input.footer"
            )
            UniHaptic.play(.error)
            return false
        }
    }
}
