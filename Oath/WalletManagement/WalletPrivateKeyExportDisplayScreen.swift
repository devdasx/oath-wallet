import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct WalletPrivateKeyExportDisplayScreen: View {
    let wallet: ManagedWallet
    let item: WalletPrivateKeyExportItem
    let cloudBackupService: WalletAutomaticCloudBackupService

    @State private var selectedKeyKind: WalletPrivateKeyExportValue.Kind
    @State private var copiedKeyID: WalletPrivateKeyExportValue.Kind?
    @State private var copyResetTask: Task<Void, Never>?

    init(
        wallet: ManagedWallet,
        item: WalletPrivateKeyExportItem,
        cloudBackupService: WalletAutomaticCloudBackupService = .shared
    ) {
        self.wallet = wallet
        self.item = item
        self.cloudBackupService = cloudBackupService
        _selectedKeyKind = State(
            initialValue: item.privateKeys.first?.kind ?? .standard
        )
    }

    var body: some View {
        List {
            Group {
                if let privateKey = selectedPrivateKey {
                    privateKeyExportSection(privateKey)
                } else {
                    Section {
                        chainBadge
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .walletCallSafetyWarning(.secret)
        // Every row is flush with its section, so this is the visible gap between
        // the card, the backup row and the copy action; the badge keeps the same
        // 24pt inside the card's row rather than sitting in a row of its own.
        .listSectionSpacing(24)
        .navigationTitle(item.localizedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if item.privateKeys.count > 1 {
                keySelector
            }
        }
        .onChange(of: selectedKeyKind) {
            copyResetTask?.cancel()
            copyResetTask = nil
            copiedKeyID = nil
        }
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
            copiedKeyID = nil
        }
    }

    private var selectedPrivateKey: WalletPrivateKeyExportValue? {
        item.privateKeys.first { $0.kind == selectedKeyKind }
            ?? item.privateKeys.first
    }

    private var keySelector: some View {
        Picker(
            "settings.wallets.private_key.section",
            selection: $selectedKeyKind
        ) {
            ForEach(item.privateKeys) { privateKey in
                Text(LocalizedStringKey(privateKey.kind.titleKey))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .tag(privateKey.kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 560)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(WalletTheme.groupedBackground)
        .accessibilityLabel(
            Text("settings.wallets.private_key.section")
        )
    }

    private var chainBadge: some View {
        HStack(spacing: 8) {
            AssetLogoView(
                source: item.logoSource,
                size: 22,
                animatesChanges: false
            )
            .accessibilityHidden(true)

            Text(verbatim: item.localizedTitle)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(WalletTheme.mutedSecondaryFill, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func privateKeyExportSection(
        _ privateKey: WalletPrivateKeyExportValue
    ) -> some View {
        // Hero rows: the card, the copy action and the warning span the section
        // exactly like the backup row's background, so every edge lines up. The
        // badge shares the card's row: a row of its own would be padded to the
        // list's minimum row height and open a wider gap than the sections'.
        Section {
            VStack(spacing: 24) {
                chainBadge
                privateKeyCard(privateKey)
            }
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }

        Section {
            WalletPrivateKeyICloudBackupToggle(
                wallet: wallet,
                item: item,
                privateKey: privateKey,
                service: cloudBackupService
            )
            .id(privateKey.kind)
        }

        Section {
            copyButton(privateKey)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            Text(LocalizedStringKey(item.warningKey))
                .font(.footnote)
                .foregroundStyle(WalletTheme.danger)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    private func privateKeyCard(
        _ privateKey: WalletPrivateKeyExportValue
    ) -> some View {
        WalletQRCodeCard(
            payload: privateKey.value,
            title: LocalizedStringKey(privateKey.kind.titleKey),
            detail: item.localizedDetail,
            accessibilityLabel:
                "settings.wallets.private_key.export.qr.accessibility",
            codeAccessibilityIdentifier: "wallet.private_key.export.qr",
            cachesRenderedImage: false
        ) {
            WalletExactText(
                privateKey.value, monospaced: true,
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wallet.private_key.export.card")
    }

    private func copyButton(
        _ privateKey: WalletPrivateKeyExportValue
    ) -> some View {
        let title = copiedKeyID == privateKey.id
            ? WalletLocalization.string(
                "settings.wallets.private_key.export.copied"
            )
            : privateKey.localizedCopyTitle
        return Button(action: UniHaptic.action(.successQuiet) {
            copyPrivateKey(privateKey)
        }) {
            WalletPrivateKeyExportActionLabel(
                title: title
            )
        }
        .walletSecondaryActionButtonStyle()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .walletFlexibleButtonSizing()
        .accessibilityLabel(
            Text(verbatim: title)
        )
    }

    private func copyPrivateKey(
        _ privateKey: WalletPrivateKeyExportValue
    ) {
        UIPasteboard.general.setItems(
            [
                [
                    UTType.utf8PlainText.identifier:
                        privateKey.value
                ]
            ],
            options: [
                .localOnly: true,
                .expirationDate:
                    Date().addingTimeInterval(120)
            ]
        )
        copyResetTask?.cancel()
        copiedKeyID = privateKey.id
        copyResetTask = Task {
            do {
                try await Task.sleep(
                    for: WalletClipboardCopyFeedback.displayDuration
                )
            } catch {
                return
            }
            guard !Task.isCancelled,
                  copiedKeyID == privateKey.id else { return }
            copiedKeyID = nil
            copyResetTask = nil
        }
    }
}

private struct WalletPrivateKeyExportActionLabel: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
    }
}
