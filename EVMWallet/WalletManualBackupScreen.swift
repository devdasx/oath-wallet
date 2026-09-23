import SwiftUI

struct WalletManualBackupScreen: View {
    let words: [String]
    let passphrase: String
    let onVerified: () async throws -> Void

    @Environment(\.walletSensitiveValuesProtected)
    private var sensitiveValuesProtected
    @State private var isVerificationPresented = false
    @State private var verificationAttemptID = UUID()

    var body: some View {
        List {
            Group {
                VStack(spacing: 10) {
                    Text("wallet.creation.recovery.title")
                        .font(WalletTypography.title(.title2))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    Text("wallet.creation.recovery.message")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    ForEach(0..<rowCount, id: \.self) { rowIndex in
                        wordRow(rowIndex)
                    }
                } footer: {
                    Text("wallet.creation.recovery.warning")
                        .foregroundStyle(WalletTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !passphrase.isEmpty {
                    Section {
                        WalletExactText(passphrase)
                            .walletSensitiveValue()
                    } header: {
                        Text("wallet.recovery.passphrase.section")
                    } footer: {
                        Text("wallet.recovery.passphrase.footer")
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .walletCallSafetyWarning(.secret)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            PrimaryWalletButton(
                title: "settings.wallets.backup.manual.confirm",
                hapticPolicy: .silent
            ) {
                beginVerification()
            }
            .walletActionScreenMargins()
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .navigationDestination(isPresented: $isVerificationPresented) {
            WalletManualBackupVerificationScreen(
                words: words,
                passphrase: passphrase,
                onVerified: onVerified
            )
            .id(verificationAttemptID)
        }
        .navigationTitle("settings.wallets.backup.manual.navigation")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var rowCount: Int {
        (words.count + 1) / 2
    }

    private func wordRow(_ rowIndex: Int) -> some View {
        let leadingIndex = rowIndex * 2
        let trailingIndex = leadingIndex + 1

        return HStack(alignment: .firstTextBaseline, spacing: 20) {
            wordCell(leadingIndex)

            if words.indices.contains(trailingIndex) {
                wordCell(trailingIndex)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
    }

    private func wordCell(_ index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: EnglishNumbers.integer(Int64(index + 1)))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .trailing)

            if isVerificationPresented {
                Text(verbatim: "••••••")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: words[index])
                    .font(.body.weight(.medium))
                    .walletSensitiveValue()
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isVerificationPresented || sensitiveValuesProtected
                ? Text("wallet.home.balance.hidden")
                : Text(
                    verbatim: EnglishNumbers.localized(
                        "wallet.creation.recovery.word.accessibility",
                        index + 1,
                        words[index]
                    )
                )
        )
    }

    private func beginVerification() {
        verificationAttemptID = UUID()
        isVerificationPresented = true
    }

}

private struct PostCreationWalletBackupSheet: View {
    let database: WalletDatabase
    let presentation: PostCreationWalletBackupPresentation
    let onBackupCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var sensitiveLifecycle:
        WalletSensitiveContentLifecycleState

    init(
        database: WalletDatabase,
        presentation: PostCreationWalletBackupPresentation,
        onBackupCompleted: @escaping () -> Void
    ) {
        self.database = database
        self.presentation = presentation
        self.onBackupCompleted = onBackupCompleted
        var lifecycle = WalletSensitiveContentLifecycleState()
        _ = lifecycle.acceptLoadedContent()
        _sensitiveLifecycle = State(initialValue: lifecycle)
    }

    var body: some View {
        NavigationStack {
            Group {
                WalletManualBackupScreen(
                    words: presentation.words,
                    passphrase: presentation.passphrase,
                    onVerified: completeBackup
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        WalletCloseButton {
                            dismiss()
                        }
                    }
                }
            }

        }
        .walletSensitiveContentMask(
            isProtected: sensitiveLifecycle.isMasked,
            requiresProtection: sensitiveLifecycle.isMasked || sensitiveLifecycle.hasExpired
        )
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .inactive:
                protectSensitiveContent(for: .sceneInactive)
            case .background:
                protectSensitiveContent(for: .sceneBackground)
            case .active:
                resumeSensitiveContentAfterInactive()
            @unknown default:
                protectSensitiveContent(for: .sceneInactive)
            }
        }
        .onDisappear {
            protectSensitiveContent(for: .viewDisappeared)
        }
    }

    private func completeBackup() async throws {
        try await database.markManualBackupVerified(
            walletID: presentation.walletID
        )
        await MainActor.run {
            onBackupCompleted()
            dismiss()
        }
    }

    @MainActor
    private func protectSensitiveContent(
        for trigger: WalletSensitiveContentLifecycleTrigger
    ) {
        _ = sensitiveLifecycle.protect(for: trigger)
    }

    @MainActor
    private func resumeSensitiveContentAfterInactive() {
        guard sensitiveLifecycle.resumeAfterInactive() else {
            if sensitiveLifecycle.hasExpired { dismiss() }
            return
        }
        _ = sensitiveLifecycle.acceptLoadedContent()
    }
}

private struct PostCreationWalletBackupSheetModifier: ViewModifier {
    @Binding var presentation: PostCreationWalletBackupPresentation?
    let database: WalletDatabase
    let securitySettings: WalletSecuritySettings
    let showsWalletLock: Bool
    let callbacks: WalletCoveringModalCallbacks
    let onAuthenticated: () -> Void
    let onBackupCompleted: () -> Void
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content.sheet(
            item: $presentation,
            onDismiss: {
                callbacks.didDismiss(.postCreationWalletBackup)
                onDismiss()
            }
        ) { presentation in
            PostCreationWalletBackupSheet(
                database: database,
                presentation: presentation,
                onBackupCompleted: onBackupCompleted
            )
            .walletSheetPresentation(nativeGlass: false)
            .walletCoveringModal(
                .postCreationWalletBackup,
                callbacks: callbacks
            )
            .walletAppLockOverlay(
                isPresented: showsWalletLock,
                database: database,
                settings: securitySettings,
                onAuthenticated: onAuthenticated
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}

extension View {
    func postCreationWalletBackupSheet(
        presentation: Binding<PostCreationWalletBackupPresentation?>,
        database: WalletDatabase,
        securitySettings: WalletSecuritySettings,
        showsWalletLock: Bool,
        callbacks: WalletCoveringModalCallbacks,
        onAuthenticated: @escaping () -> Void,
        onBackupCompleted: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) -> some View {
        modifier(
            PostCreationWalletBackupSheetModifier(
                presentation: presentation,
                database: database,
                securitySettings: securitySettings,
                showsWalletLock: showsWalletLock,
                callbacks: callbacks,
                onAuthenticated: onAuthenticated,
                onBackupCompleted: onBackupCompleted,
                onDismiss: onDismiss
            )
        )
    }
}
