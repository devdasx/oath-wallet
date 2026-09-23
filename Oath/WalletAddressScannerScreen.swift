import PhotosUI
import SwiftUI
import UIKit

struct WalletAddressScannerScreen: View {
    let prepareRequest:
        (SendPaymentRequest) -> SendScanPreparation
    let onProceed: (SendFlowRoute) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.walletCurrencyContext) private var currencyContext
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isAnalyzingPhoto = false
    @State private var isPhotoErrorPresented = false
    @State private var recognitionError: String?
    @State private var review: SendScannerReview?

    var body: some View {
        NavigationStack {
            Group {
                ZStack {
                    if let review {
                        SmartScannerReviewPanel(
                            presentation: review.presentation,
                            onConfirm: {
                                onProceed(review.route)
                            },
                            onCancel: cancelReview
                        )
                    } else {
                        scannerContent
                    }
                }
                .background(WalletBackground())
                .navigationTitle("send.scan.title")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        WalletCloseButton {
                            dismiss()
                        }
                        .accessibilityIdentifier("qrScannerClose")
                    }
                }
                .alert(
                    "import.scanner.gallery.error.title",
                    isPresented: $isPhotoErrorPresented
                ) {
                    Button("common.done", role: .cancel, action: UniHaptic.action {})
                } message: {
                    Text("import.scanner.gallery.error.message")
                }
                .task(id: selectedPhoto) {
                    guard let selectedPhoto else { return }
                    await analyzePhoto(selectedPhoto)
                }
                .animation(
                    reduceMotion ? nil : .smooth(duration: 0.24),
                    value: review
                )
            }

        }
        .walletScannerPresentation()
    }

    private var scannerContent: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                scannerMessage

                Spacer(minLength: 18)

                cameraViewport
                    .frame(
                        height: cameraHeight(
                            for: proxy.size.height
                        )
                    )

                Spacer(minLength: 18)

                scannerActions
            }
            .walletActionScreenMargins()
            .padding(.top, 22)
            .padding(.bottom, 20)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity
            )
        }
    }

    private var scannerMessage: some View {
        ZStack {
            if let recognitionError {
                Text(verbatim: recognitionError)
                    .foregroundStyle(WalletTheme.danger)
            } else if isAnalyzingPhoto {
                Text("import.scanner.gallery.processing")
                    .foregroundStyle(.secondary)
            } else {
                Text("send.scan.instruction")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.22),
            value: recognitionError
        )
    }

    private var cameraViewport: some View {
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
        .accessibilityElement(children: .contain)
    }

    private var scannerActions: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    galleryButton
                    pasteButton
                }
            } else {
                HStack(spacing: 12) {
                    galleryButton
                    pasteButton
                }
            }
        }
    }

    private var galleryButton: some View {
        let usesAccessibleText = dynamicTypeSize.isAccessibilitySize
        return PhotosPicker(
            selection: $selectedPhoto,
            matching: .images
        ) {
            Text("common.gallery")
                .font(.headline)
                .lineLimit(usesAccessibleText ? 2 : 1)
                .minimumScaleFactor(usesAccessibleText ? 1 : 0.75)
                .frame(maxWidth: .infinity)
        }
        .walletSecondaryActionButtonStyle()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .walletFlexibleButtonSizing()
        .disabled(isAnalyzingPhoto)
    }

    private var pasteButton: some View {
        Button(action: UniHaptic.action {
            guard
                let clipboardText = UIPasteboard.general.string?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                !clipboardText.isEmpty
            else {
                return
            }
            _ = recognize(clipboardText)
        }) {
            Text("common.paste")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .contentShape(Capsule())
        }
        .walletPrimaryActionButtonStyle()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .walletFlexibleButtonSizing()
        .disabled(isAnalyzingPhoto)
    }

    private func cameraHeight(
        for availableHeight: CGFloat
    ) -> CGFloat {
        min(390, max(230, availableHeight * 0.52))
    }

    @MainActor
    private func analyzePhoto(_ item: PhotosPickerItem) async {
        isAnalyzingPhoto = true
        defer {
            isAnalyzingPhoto = false
            selectedPhoto = nil
        }

        do {
            guard
                let imageData = try await item.loadTransferable(
                    type: Data.self
                ),
                let payload = try await QRCodeImageDecoder
                    .firstPayload(in: imageData)
            else {
                guard !Task.isCancelled else { return }
                isPhotoErrorPresented = true
                return
            }
            try Task.checkCancellation()
            _ = recognize(payload)
        } catch {
            guard !Task.isCancelled else { return }
            isPhotoErrorPresented = true
        }
    }

    @MainActor
    private func recognize(_ payload: String) -> Bool {
        do {
            let request = try ScannerPayloadPolicy.sendRequest(
                from: payload
            )
            switch prepareRequest(request) {
            case let .ready(route):
                review = SendScannerReview(
                    request: request,
                    route: route,
                    currencyContext: currencyContext
                )
                recognitionError = nil
                UniHaptic.play(.successQuiet)
                return true
            case let .failed(message):
                recognitionError = message
                UniHaptic.play(.error)
                return false
            }
        } catch let error as SendPaymentRequestError {
            recognitionError = error.localizedMessage
        } catch let error as SendRecipientNameError {
            recognitionError = error.localizedMessage
        } catch {
            recognitionError = WalletLocalization.string(
                "send.error.unsupported_format"
            )
        }
        UniHaptic.play(.error)
        return false
    }

    @MainActor
    private func cancelReview() {
        review = nil
        recognitionError = nil
        UniHaptic.play(.selection)
    }
}
