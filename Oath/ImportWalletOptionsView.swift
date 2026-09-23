import SwiftUI

enum ImportWalletOption: String, CaseIterable, Identifiable, Sendable {
    case recoveryPhrase
    case privateKey
    case physicalEntropy
    case restoreICloud
    case transferFromIPhone

    var id: Self { self }

    var titleKey: String {
        switch self {
        case .recoveryPhrase: "import.recovery.title"
        case .privateKey: "import.private_key.title"
        case .physicalEntropy: "onboarding.creation.method.physical.title"
        case .restoreICloud: "import.icloud.title"
        case .transferFromIPhone: "device_migration.import.option.title"
        }
    }

    var detail: String {
        switch self {
        case .recoveryPhrase:
            EnglishNumbers.localized("import.recovery.detail", 12, 24)
        case .privateKey:
            WalletLocalization.string("import.private_key.detail")
        case .physicalEntropy:
            WalletLocalization.string(
                "onboarding.creation.method.physical.subtitle"
            )
        case .restoreICloud:
            WalletLocalization.string("import.icloud.detail")
        case .transferFromIPhone:
            WalletLocalization.string("device_migration.import.option.detail")
        }
    }

    var systemImage: String {
        switch self {
        case .recoveryPhrase: "doc.text"
        case .privateKey: "key.horizontal"
        case .physicalEntropy: "dice"
        case .restoreICloud: "icloud.and.arrow.down"
        case .transferFromIPhone: "iphone.and.arrow.forward"
        }
    }

    var iconColor: Color {
        switch self {
        case .recoveryPhrase:
            WalletTheme.settingsIconBlue
        case .privateKey:
            WalletTheme.settingsIconGreen
        case .physicalEntropy:
            WalletTheme.settingsIconOrange
        case .restoreICloud:
            WalletTheme.settingsIconIndigo
        case .transferFromIPhone:
            WalletTheme.settingsIconGray
        }
    }
}

/// Shared artwork only. Each import flow continues to own its native row,
/// navigation, lifecycle, and actions independently.
struct ImportMethodIconTile: View {
    let option: ImportWalletOption

    @ScaledMetric(relativeTo: .body)
    private var size = WalletIconTileStyle.size

    var body: some View {
        WalletIconTile(
            systemImage: option.systemImage,
            color: option.iconColor,
            size: size
        )
    }
}

struct ImportWalletOptionsView: View {
    let onRecoveryPhrase: () -> Void
    let onPrivateKey: () -> Void
    let onPhysicalEntropy: () -> Void
    let onRestoreICloud: () -> Void
    let onTransferFromIPhone: (() -> Void)?
    let onMuunRecovery: () -> Void
    let onTrustWalletRestore: (TrustWalletBackupDescriptor) -> Void

    @State private var isPresentingTrustWalletPicker = false
    @State private var trustWalletSelectionTask: Task<Void, Never>?
    @State private var trustWalletErrorKey: String?

    var options: [ImportWalletOption] {
        ImportWalletOption.allCases.filter {
            $0 != .transferFromIPhone || onTransferFromIPhone != nil
        }
    }

    var body: some View {
        List {
            Group {
                Section {
                    VStack(spacing: 0) {
                        Image(systemName: "square.and.arrow.down")
                            .font(
                                .system(
                                    size: 34,
                                    weight: WalletSFSymbol.weight
                                )
                            )
                            .foregroundStyle(WalletTheme.accent)
                            .padding(.bottom, 22)
                            .accessibilityHidden(true)

                        Text("import.heading")
                            .font(WalletTypography.title(.title))
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)

                        Text("import.message")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                            .padding(.horizontal, 20)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 34)
                    .padding(.bottom, 18)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }

                Section {
                    ForEach(options) { option in
                        ImportMethodButton(
                            option: option,
                            title: LocalizedStringKey(option.titleKey),
                            detail: option.detail,
                            action: { select(option) }
                        )
                    }
                } footer: {
                    Text("import.warning")
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("import.navigation.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: UniHaptic.action(nil, perform: onMuunRecovery)) {
                        Label(
                            "muun.recovery.menu",
                            image: "ImportWalletLogoMuun"
                        )
                    }

                    Button(action: UniHaptic.action(nil, perform: presentTrustWalletPicker)) {
                        Label(
                            LocalizedStringKey(
                                TrustWalletBackupDocumentPickerPolicy
                                    .selectionActionLocalizationKey
                            ),
                            image: "ImportWalletLogoTrust"
                        )
                    }
                    .accessibilityHint(
                        Text(
                            LocalizedStringKey(
                                TrustWalletBackupDocumentPickerPolicy
                                    .selectionDetailLocalizationKey
                            )
                        )
                    )
                    .disabled(trustWalletSelectionTask != nil)
                } label: {
                    Image(systemName: "ellipsis")
                        .accessibilityLabel(
                            Text("import.more_options.accessibility")
                        )
                }
            }
        }
        .sheet(isPresented: $isPresentingTrustWalletPicker) {
            TrustWalletBackupDocumentPicker(
                onSelect: handleTrustWalletSelection,
                onCancel: dismissTrustWalletPicker
            )
            .ignoresSafeArea()
        }
        .alert(
            "trust_wallet.restore.menu",
            isPresented: Binding(
                get: { trustWalletErrorKey != nil },
                set: { if !$0 { trustWalletErrorKey = nil } }
            )
        ) {
            Button("common.ok", role: .cancel, action: UniHaptic.action {})
        } message: {
            if let trustWalletErrorKey {
                Text(LocalizedStringKey(trustWalletErrorKey))
            }
        }
        .onDisappear(perform: cancelTrustWalletSelection)
    }

    func select(_ option: ImportWalletOption) {
        switch option {
        case .recoveryPhrase: onRecoveryPhrase()
        case .privateKey: onPrivateKey()
        case .physicalEntropy: onPhysicalEntropy()
        case .restoreICloud: onRestoreICloud()
        case .transferFromIPhone: onTransferFromIPhone?()
        }
    }

    private func presentTrustWalletPicker() {
        guard trustWalletSelectionTask == nil else { return }
        trustWalletErrorKey = nil
        isPresentingTrustWalletPicker = true
    }

    private func dismissTrustWalletPicker() {
        isPresentingTrustWalletPicker = false
    }

    private func handleTrustWalletSelection(_ selectedURL: URL) {
        guard trustWalletSelectionTask == nil else { return }
        isPresentingTrustWalletPicker = false
        trustWalletErrorKey = nil

        // Start consuming the security-scoped URL from the picker callback.
        // Waiting for SwiftUI's sheet onDismiss creates an event-order race:
        // onDismiss can observe state before the selected URL is committed and
        // silently skip both validation and navigation.
        trustWalletSelectionTask = Task { @MainActor in
            defer { trustWalletSelectionTask = nil }
            do {
                let backup = try await TrustWalletBackupSelectionReader
                    .selectedBackup(at: selectedURL)
                try Task.checkCancellation()
                onTrustWalletRestore(backup)
            } catch is CancellationError {
                return
            } catch {
                trustWalletErrorKey = TrustWalletBackupImportPresentation
                    .folderErrorKey(for: error)
            }
        }
    }

    private func cancelTrustWalletSelection() {
        trustWalletSelectionTask?.cancel()
        trustWalletSelectionTask = nil
        isPresentingTrustWalletPicker = false
    }
}

private struct ImportMethodButton: View {
    let option: ImportWalletOption
    let title: LocalizedStringKey
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: UniHaptic.action(nil) {
            action()
        }) {
            HStack(spacing: 16) {
                ImportMethodIconTile(option: option)

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(WalletTheme.primaryLabel)

                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        // Let List own the whole-row hit target and native pressed highlight.
        .buttonStyle(.automatic)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(detail))
    }
}

#Preview("Import Options") {
    NavigationStack {
        ImportWalletOptionsView(
            onRecoveryPhrase: {},
            onPrivateKey: {},
            onPhysicalEntropy: {},
            onRestoreICloud: {},
            onTransferFromIPhone: {},
            onMuunRecovery: {},
            onTrustWalletRestore: { _ in }
        )
    }
}
