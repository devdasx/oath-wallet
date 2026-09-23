import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WalletCore

enum BitcoinWIFExportSource: Hashable {
    case hd(BitcoinHDAddressType, BitcoinHDAddressBranch, Int)
}

struct BitcoinWIFExportPresentation: Identifiable {
    let id = UUID()
    let authorization: WalletSecretExportAuthorization
}

struct BitcoinAddressWIFExportScreen: View {
    let walletID: String
    let source: BitcoinWIFExportSource
    let authorization: WalletSecretExportAuthorization
    let database: WalletDatabase

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var wif: String?
    @State private var detail: String?
    @State private var feedbackKey = "common.copy"
    @State private var errorMessage: String?
    @State private var sensitiveLifecycle =
        WalletSensitiveContentLifecycleState()

    init(
        walletID: String,
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch,
        index: Int,
        authorization: WalletSecretExportAuthorization,
        database: WalletDatabase
    ) {
        self.walletID = walletID
        source = .hd(addressType, branch, index)
        self.authorization = authorization
        self.database = database
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let wif {
                    WalletQRCodeCard(
                        payload: wif,
                        title: "bitcoin.settings.wif.section",
                        detail: detail,
                        accessibilityLabel:
                            "bitcoin.settings.wif.qr.accessibility",
                        cachesRenderedImage: false
                    ) {
                        WalletExactText(
                            wif, monospaced: true,
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
                        copy(wif)
                    }) {
                        Text(LocalizedStringKey(feedbackKey))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .walletSecondaryActionButtonStyle()
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .walletFlexibleButtonSizing()

                    Text("bitcoin.settings.wif.warning")
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
        .navigationTitle("bitcoin.settings.wif.title")
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
                        wif = nil
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
            wif = nil
            detail = nil
        }
    }

    @MainActor
    private func load() async {
        do {
            switch source {
            case let .hd(type, branch, index):
                wif = try await database.bitcoinHDWIFForExport(
                    walletID: walletID,
                    addressType: type,
                    branch: branch,
                    index: index,
                    authorization: authorization
                )
                detail = BitcoinHDDerivationService().derivationPath(
                    addressType: type,
                    branch: branch,
                    index: index
                )
            }
            guard wif != nil else {
                throw BitcoinHDWalletDatabaseError.invalidAddressState
            }
            _ = sensitiveLifecycle.acceptLoadedContent()
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            wif = nil
            errorMessage = WalletLocalization.string(
                "bitcoin.settings.wif.error"
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
