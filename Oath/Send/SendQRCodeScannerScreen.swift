import PhotosUI
import SwiftUI
import UIKit

struct SendQRCodeScannerScreen: View {
    let prepareRequest:
        (SendPaymentRequest) -> SendScanPreparation
    let onProceed: (SendFlowRoute) -> Void
    let onEnterTextAddress: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.walletCurrencyContext) private var currencyContext
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isAnalyzingPhoto = false
    @State private var isPhotoErrorPresented = false
    @State private var recognitionError: String?
    @State private var review: SendScannerReview?

    var body: some View {
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
                GeometryReader { proxy in
                    Group {
                        if verticalSizeClass == .compact {
                            compactContent
                        } else {
                            regularContent(
                                availableHeight: proxy.size.height
                            )
                        }
                    }
                    .frame(maxWidth: 940)
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .padding(.bottom, 20)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                }
            }
        }
        .background(WalletTheme.groupedBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if review == nil {
                scannerBottomActionArea
            }
        }
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

    private func regularContent(
        availableHeight: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            scannerMessage

            Spacer(minLength: 18)

            cameraViewport
                .frame(maxWidth: 680)
                .frame(
                    height: cameraHeight(
                        for: availableHeight
                    )
                )

            Spacer(minLength: 18)
        }
    }

    private var compactContent: some View {
        HStack(spacing: 24) {
            cameraViewport
                .aspectRatio(1, contentMode: .fit)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )

            scannerMessage
            .frame(maxWidth: 360)
        }
    }

    private var scannerBottomActionArea: some View {
        scannerActionsContainer
            .walletActionScreenMargins()
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(WalletTheme.groupedBackground)
    }

    private var scannerMessage: some View {
        ZStack {
            if let recognitionError {
                Text(verbatim: recognitionError)
                    .foregroundStyle(WalletTheme.danger)
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
        VStack(spacing: 12) {
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

            enterTextAddressButton
        }
    }

    private var scannerActionsContainer: some View {
        ZStack {
            if isAnalyzingPhoto {
                scannerActionsSkeleton
            } else {
                scannerActions
            }
        }
        .animation(
            reduceMotion
                ? nil
                : .smooth(duration: 0.22),
            value: isAnalyzingPhoto
        )
    }

    private var scannerActionsSkeleton: some View {
        VStack(spacing: 12) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 12) {
                        scannerActionSkeleton
                        scannerActionSkeleton
                    }
                } else {
                    HStack(spacing: 12) {
                        scannerActionSkeleton
                        scannerActionSkeleton
                    }
                }
            }

            scannerActionSkeleton
        }
        .sendSkeletonPulse()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("import.scanner.gallery.processing")
        )
    }

    private var scannerActionSkeleton: some View {
        Capsule()
            .fill(WalletTheme.tertiaryFill)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .accessibilityHidden(true)
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
        Button(action: UniHaptic.action(nil) {
            guard
                let clipboardText = UIPasteboard.general.string?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                !clipboardText.isEmpty
            else {
                recognitionError = WalletLocalization.string(
                    "send.error.empty_payload"
                )
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

    private var enterTextAddressButton: some View {
        Button(action: UniHaptic.action {
            onEnterTextAddress()
        }) {
            Text(
                verbatim: WalletLocalization.string(
                    "send.scan.enter_text_address.action"
                )
            )
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .walletPrimaryActionButtonStyle()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .walletFlexibleButtonSizing()
        .disabled(isAnalyzingPhoto)
    }

    @MainActor
    private func recognize(_ payload: String) -> Bool {
        do {
            let request = try ScannerPayloadPolicy.sendRequest(
                from: payload
            )
            switch prepareRequest(request) {
            case let .ready(route):
                recognitionError = nil
                review = SendScannerReview(
                    request: request,
                    route: route,
                    currencyContext: currencyContext
                )
                UniHaptic.play(.successQuiet)
                return true
            case let .failed(message):
                recognitionError = message
                UniHaptic.play(.error)
                return false
            }
        } catch let error as SendPaymentRequestError {
            recognitionError = error.localizedMessage
            UniHaptic.play(.error)
            return false
        } catch let error as SendRecipientNameError {
            recognitionError = error.localizedMessage
            UniHaptic.play(.error)
            return false
        } catch {
            recognitionError = WalletLocalization.string(
                "send.error.unsupported_format"
            )
            UniHaptic.play(.error)
            return false
        }
    }

    @MainActor
    private func cancelReview() {
        review = nil
        recognitionError = nil
        UniHaptic.play(.selection)
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
            isAnalyPhotoCleanup()
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
            if !recognize(payload) {
                isPhotoErrorPresented = true
            }
        } catch {
            guard !Task.isCancelled else { return }
            isPhotoErrorPresented = true
        }
    }

    @MainActor
    private func isAnalyPhotoCleanup() {
        isAnalyzingPhoto = false
        selectedPhoto = nil
    }
}
