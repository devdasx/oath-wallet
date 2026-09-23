import SwiftUI
import UIKit

struct ReceiveAddressActionButtons: View {
    let context: ReceiveShareContext

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isCopied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    copyButton
                    shareButton
                }
            } else {
                HStack(spacing: 10) {
                    copyButton
                    shareButton
                }
            }
        }
        .walletAutomaticActionMargins()
        .onChange(of: context.address) { _, _ in
            resetCopyState()
        }
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
    }

    private var copyButton: some View {
        Button(action: UniHaptic.action(.successQuiet, perform: copyAddress)) {
            ReceiveAddressActionButtonLabel(
                title: isCopied
                    ? "common.copied_to_clipboard"
                    : "common.copy"
            )
        }
        .walletPrimaryActionButtonStyle()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .walletFlexibleButtonSizing()
        .frame(maxWidth: .infinity)
        .accessibilityLabel(
            Text(
                isCopied
                    ? "common.copied_to_clipboard"
                    : "common.copy"
            )
        )
    }

    private var shareButton: some View {
        ReceiveShareAction(context: context) {
            ReceiveAddressActionButtonLabel(
                title: "receive.action.share"
            )
        }
        .walletSecondaryActionButtonStyle()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .walletFlexibleButtonSizing()
        .frame(maxWidth: .infinity)
    }

    private func copyAddress() {
        UIPasteboard.general.string = context.address
        copyResetTask?.cancel()

        withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
            isCopied = true
        }

        copyResetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
                isCopied = false
            }
            copyResetTask = nil
        }
    }

    private func resetCopyState() {
        copyResetTask?.cancel()
        copyResetTask = nil
        isCopied = false
    }
}

struct ReceiveAddressActionButtonLabel: View {
    let title: LocalizedStringKey

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Text(title)
            .font(.headline)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .minimumScaleFactor(
                dynamicTypeSize.isAccessibilitySize ? 1 : 0.75
            )
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

struct ReceiveShareAction<Label: View>: View {
    let context: ReceiveShareContext
    @ViewBuilder let label: () -> Label

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var isChoosingContent = false
    @State private var sharePayload: ReceiveSharePayload?
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        Button(action: UniHaptic.action {
            isChoosingContent = true
        }) {
            label()
        }
        .confirmationDialog(
            "receive.action.share",
            isPresented: $isChoosingContent,
            titleVisibility: .visible
        ) {
            Button("receive.action.share", action: UniHaptic.action {
                sharePayload = .address(context.address)
            })

            Button("receive.action.share_qr_code", action: UniHaptic.action {
                prepareBrandedQRCode()
            })

            Button("common.cancel", role: .cancel, action: UniHaptic.action {})
        }
        .sheet(item: $sharePayload) { payload in
            ReceiveNativeShareSheet(
                activityItems: payload.activityItems
            )
        }
        .onDisappear {
            renderTask?.cancel()
            renderTask = nil
        }
    }

    @MainActor
    private func prepareBrandedQRCode() {
        renderTask?.cancel()

        let selectedTagline = ReceiveShareTagline.random()
        let capturedContext = context
        let capturedColorScheme = colorScheme
        let capturedLayoutDirection = layoutDirection

        renderTask = Task { @MainActor in
            let qrImage = await ReceiveQRCodeRenderer.shared.image(
                for: capturedContext.qrPayload
            )
            guard !Task.isCancelled else { return }

            guard
                let qrImage,
                let cardImage = ReceiveShareCardRenderer.image(
                    context: capturedContext,
                    qrImage: qrImage,
                    tagline: selectedTagline,
                    colorScheme: capturedColorScheme,
                    layoutDirection: capturedLayoutDirection
                )
            else {
                sharePayload = .address(capturedContext.address)
                renderTask = nil
                return
            }

            sharePayload = .qrCard(cardImage)
            renderTask = nil
        }
    }
}

private struct ReceiveSharePayload: Identifiable {
    enum Content {
        case address(String)
        case qrCard(UIImage)
    }

    let id = UUID()
    let content: Content

    static func address(_ address: String) -> ReceiveSharePayload {
        ReceiveSharePayload(content: .address(address))
    }

    static func qrCard(_ image: UIImage) -> ReceiveSharePayload {
        ReceiveSharePayload(content: .qrCard(image))
    }

    var activityItems: [Any] {
        switch content {
        case .address(let address):
            [address]
        case .qrCard(let image):
            [image]
        }
    }
}

private struct ReceiveNativeShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ viewController: UIActivityViewController,
        context: Context
    ) {}
}
