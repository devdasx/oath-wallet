import SwiftUI

enum HomeWalletAddSheetDetent: Equatable, Sendable {
    case medium
    case large

    var presentationDetent: PresentationDetent {
        switch self {
        case .medium:
            .medium
        case .large:
            .large
        }
    }
}

enum HomeWalletAddAction: String, CaseIterable, Identifiable, Sendable {
    case create
    case importWallet = "import"
    case restoreICloud = "restore-icloud"

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .create:
            "settings.wallets.create"
        case .importWallet:
            "settings.wallets.import"
        case .restoreICloud:
            "settings.wallets.restore_icloud"
        }
    }

    var systemImage: String {
        switch self {
        case .create:
            "plus.circle"
        case .importWallet:
            "square.and.arrow.down"
        case .restoreICloud:
            "icloud.and.arrow.down"
        }
    }

    var sheetDetent: HomeWalletAddSheetDetent {
        switch self {
        case .create, .importWallet, .restoreICloud:
            .large
        }
    }

    var onboardingStartAction: OnboardingStartAction? {
        switch self {
        case .create:
            nil
        case .importWallet:
            .importWallet
        case .restoreICloud:
            .restoreICloud
        }
    }
}

struct HomeWalletAddSheet: View {
    let database: WalletDatabase
    let action: HomeWalletAddAction
    let onWalletAdded: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.walletAppLockIsPresented) private var isAppLockPresented
    @State private var creationDraft: WalletCreationDraft?
    @State private var creationErrorMessage: String?
    @State private var walletCreationTask: Task<Void, Never>?
    @State private var activation = WalletSetupActivation()
    @State private var completionErrorPresented = false
    @State private var walletCompletionTask: Task<Void, Never>?

    var body: some View {
        content
        .allowsHitTesting(walletCompletionTask == nil)
        .interactiveDismissDisabled(walletCompletionTask != nil)
        .alert(
            "settings.wallets.select.error",
            isPresented: $completionErrorPresented
        ) {
            Button("common.ok", role: .cancel, action: UniHaptic.action {})
        }
        .onDisappear(perform: cancelOwnedWork)
    }

    @ViewBuilder
    private var content: some View {
        if action == .create {
            if let creationDraft {
                SettingsWalletCreationFlow(
                    database: database,
                    draft: creationDraft,
                    onPrepareWalletForOpen: prepareWalletForOpen,
                    onCompleted: completeWalletSetup
                )
            } else {
                NavigationStack {
                    Group {
                        List {
                            Group {
                                Section {
                                    if let creationErrorMessage {
                                        Text(verbatim: creationErrorMessage)
                                            .foregroundStyle(WalletTheme.danger)

                                        Button(
                                            "common.try_again",
                                            action: UniHaptic.action(beginWalletCreation)
                                        )
                                    } else {
                                        Text("wallet.launch.loading.accessibility")
                                            .foregroundStyle(
                                                WalletTheme.secondaryLabel
                                            )
                                    }
                                }
                            }
                            .walletListRowSurface()
                        }
                        .walletListAppearance()
                        .listStyle(.insetGrouped)
                        .navigationTitle("settings.wallets.create")
                        .navigationBarTitleDisplayMode(.inline)
                    }

                }
                .task {
                    beginWalletCreation()
                }
            }
        } else if let startAction = action.onboardingStartAction {
            OnboardingView(
                database: database,
                startAction: startAction,
                usesExistingProfileSecurity: true,
                onPrepareWalletForOpen: prepareWalletForOpen,
                onOpenWallet: completeWalletSetup
            )
        }
    }

    @MainActor
    private func beginWalletCreation() {
        guard action == .create,
              creationDraft == nil,
              walletCreationTask == nil else { return }
        creationErrorMessage = nil
        walletCreationTask = Task { @MainActor in
            defer { walletCreationTask = nil }
            do {
                let draft = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try WalletCoreService.generateEVMWallet()
                }.value
                try Task.checkCancellation()
                creationDraft = draft
            } catch is CancellationError {
                return
            } catch {
                UniHaptic.play(.error)
                creationErrorMessage = WalletLocalization.string(
                    "wallet.creation.generate.error"
                )
            }
        }
    }

    @MainActor
    private func prepareWalletForOpen(_ address: String) async -> Bool {
        await activation.prepare(address: address) { address in
            await onWalletAdded(address)
        }
    }

    @MainActor
    private func completeWalletSetup(_ address: String) {
        guard walletCompletionTask == nil else { return }
        completionErrorPresented = false
        walletCompletionTask = Task { @MainActor in
            defer { walletCompletionTask = nil }
            let isReady = await prepareWalletForOpen(address)
            guard !Task.isCancelled else { return }
            guard isReady else {
                UniHaptic.play(.error)
                completionErrorPresented = true
                return
            }
            dismiss()
        }
    }

    private func cancelOwnedWork() {
        guard scenePhase == .active, !isAppLockPresented else { return }
        walletCreationTask?.cancel()
        walletCreationTask = nil
        walletCompletionTask?.cancel()
        walletCompletionTask = nil
        completionErrorPresented = false
    }
}
