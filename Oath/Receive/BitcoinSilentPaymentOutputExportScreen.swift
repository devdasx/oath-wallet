import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BitcoinSilentPaymentOutputExportScreen: View {
    let walletID: String
    let transactionHash: String
    let outputIndex: Int
    let authorization: WalletSecretExportAuthorization
    let database: WalletDatabase

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var descriptor: String?
    @State private var detail: String?
    @State private var feedbackKey = "common.copy"
    @State private var errorMessage: String?
    @State private var sensitiveLifecycle =
        WalletSensitiveContentLifecycleState()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let descriptor {
                    WalletQRCodeCard(
                        payload: descriptor,
                        title: "settings.wallets.private_key.section",
                        detail: detail,
                        accessibilityLabel:
                            "settings.wallets.private_key.export.qr.accessibility",
                        cachesRenderedImage: false
                    ) {
                        WalletExactText(
                            descriptor, monospaced: true,
                            foregroundColor: WalletTheme.qrCodeInk, selectable: false
                        )
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .walletSensitiveValue()
                    }
                    .walletSensitiveGraphic(
                        cornerRadius: WalletQRCodeCardMetrics.cornerRadius
                    )

                    Button(action: UniHaptic.action(.successQuiet) {
                        copy(descriptor)
                    }) {
                        Text(LocalizedStringKey(feedbackKey))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .walletSecondaryActionButtonStyle()
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .walletFlexibleButtonSizing()

                    Text("settings.wallets.private_key.export.warning")
                        .font(.footnote)
                        .foregroundStyle(WalletTheme.danger)
                        .multilineTextAlignment(.center)
                } else if let errorMessage {
                    Text(verbatim: errorMessage)
                        .foregroundStyle(WalletTheme.danger)
                } else {
                    Text("receive.details.loading")
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 280)
                }
            }
            .walletActionScreenMargins()
            .padding(.top, 20)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
        .background(WalletTheme.groupedBackground)
        .walletCallSafetyWarning(.secret)
        .navigationTitle("import.private_key.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                WalletCloseButton {
                    dismiss()
                }
            }
        }
        .walletSensitiveContentMask(
            isProtected: sensitiveLifecycle.isMasked,
            requiresProtection: sensitiveLifecycle.isMasked || sensitiveLifecycle.hasExpired
        )
        .task {
            await load()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive:
                protect(for: .sceneInactive)
            case .background:
                protect(for: .sceneBackground)
            case .active:
                guard sensitiveLifecycle.resumeAfterInactive() else {
                    if sensitiveLifecycle.hasExpired {
                        descriptor = nil
                        detail = nil
                        dismiss()
                    }
                    return
                }
                _ = sensitiveLifecycle.acceptLoadedContent()
            @unknown default:
                protect(for: .sceneInactive)
            }
        }
        .onDisappear {
            descriptor = nil
            detail = nil
        }
    }

    @MainActor
    private func load() async {
        do {
            descriptor = try await database.bitcoinSilentPaymentOutputDescriptorForExport(
                walletID: walletID, transactionHash: transactionHash, outputIndex: outputIndex,
                authorization: authorization
            )
            detail = WalletLocalization.string("bitcoin.settings.silent.wif.footer")
            guard descriptor != nil else {
                throw BitcoinHDWalletDatabaseError.invalidAddressState
            }
            _ = sensitiveLifecycle.acceptLoadedContent()
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            descriptor = nil
            errorMessage = WalletLocalization.string(
                "settings.wallets.private_key.export.load.error"
            )
        }
    }

    private func copy(_ value: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: value]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(120)
            ]
        )
        feedbackKey = "common.copied_to_clipboard"
    }

    @MainActor
    private func protect(
        for trigger: WalletSensitiveContentLifecycleTrigger
    ) {
        _ = sensitiveLifecycle.protect(for: trigger)
    }
}
