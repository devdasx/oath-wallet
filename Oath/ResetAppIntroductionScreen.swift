import SwiftUI

struct ResetAppIntroductionScreen: View {
    let database: WalletDatabase
    let onResetComplete: () -> Void
    let onNotNow: () -> Void

    @Environment(WalletSettingsStore.self)
    private var applicationSettings
#if DEBUG
    @Environment(\.appResetTestActions) private var testActions
#endif
    @State private var settings: WalletSecuritySettings?
    @State private var loadFailed = false
    @State private var authenticationRoute: ResetAppAuthenticationRoute?
    @State private var isPreparingAuthentication = false
    @State private var beginsResetAfterAuthentication = false
    @State private var progressPresented = false
    @State private var didCompleteReset = false
    @State private var learnMorePresented = false

    var body: some View {
        List {
            Group {
                Section {
                    WalletDataRemovalRow(
                        title: "settings.reset.contents.wallets",
                        detail: "settings.reset.contents.wallets.detail",
                        icon: .wallets
                    )
                    WalletDataRemovalRow(
                        title: "settings.reset.contents.security",
                        detail: "settings.reset.contents.security.detail",
                        icon: .secrets
                    )
                    WalletDataRemovalRow(
                        title: "settings.reset.contents.activity",
                        detail: "settings.reset.contents.activity.detail",
                        icon: .activity
                    )
                } header: {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("settings.reset.navigation.title")
                            .font(WalletTypography.title(.largeTitle))
                            .foregroundStyle(WalletTheme.primaryLabel)
                            .textCase(nil)

                        Text("settings.reset.review.message")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textCase(nil)
                    }
                    .padding(.bottom, 16)
                }
                .headerProminence(.increased)

                if loadFailed {
                    Section {
                        Text("settings.reset.error.settings_message")
                            .foregroundStyle(WalletTheme.danger)

                        Button("settings.reset.error.retry", action: UniHaptic.action {
                            loadFailed = false
                            Task {
                                await load()
                            }
                        })
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.visible, for: .navigationBar)
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            actionBar
        }
        .fullScreenCover(
            item: $authenticationRoute,
            onDismiss: authenticationFullScreenDidDismiss
        ) { route in
            WalletAuthenticationFullScreenContainer(
                title: "security.authentication.navigation_title"
            ) {
                ResetAppAuthenticationScreen(
                    database: database,
                    context: route.context,
                    onAuthenticationGranted:
                        completePasscodeAuthentication
                )
            }
        }
        .sheet(
            isPresented: $progressPresented,
            onDismiss: resetProgressDidDismiss
        ) {
            ResetAppProgressSheet(
                database: database,
                applicationSettings: applicationSettings,
                onResetComplete: {
                    didCompleteReset = true
                    progressPresented = false
                }
            ) {
                progressPresented = false
            }
        }
        .sheet(isPresented: $learnMorePresented) {
            ResetAppLearnMoreSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            guard settings == nil, !loadFailed else { return }
            await load()
#if DEBUG
            testActions?.begin = { Task { await prepareAuthentication() } }
#endif
        }
    }

    private var actionBar: some View {
        VStack(spacing: 0) {
            DestructiveActionWarning(
                message: WalletLocalization.string(
                    "settings.reset.review.irreversible"
                ),
                learnMoreTitle: WalletLocalization.string(
                    "common.learn_more.inline"
                ),
                learnMoreAccessibilityIdentifier:
                    "resetAppLearnMore"
            ) {
                learnMorePresented = true
            }

            VStack(spacing: 10) {
                PrimaryWalletButton(
                    title: "common.continue",
                    hapticPolicy: .custom(.warning)
                ) {
                    Task {
                        await prepareAuthentication()
                    }
                }
                .disabled(settings == nil || isPreparingAuthentication)
                .accessibilityIdentifier("resetAppContinue")

                SecondaryWalletButton(
                    title: "common.not_now"
                ) {
                    onNotNow()
                }
                .disabled(isPreparingAuthentication)
            }
        }
        .walletActionScreenMargins()
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @MainActor
    private func load() async {
        do {
            settings = try await database.walletSecuritySettings()
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    @MainActor
    private func prepareAuthentication() async {
        guard let settings, !isPreparingAuthentication else { return }
        isPreparingAuthentication = true
        defer { isPreparingAuthentication = false }

        switch WalletAuthenticationAction.preparePasscodeOnly(
            settings: settings
        ) {
        case .authorized:
            progressPresented = true
        case let .requiresPasscode(context):
            authenticationRoute = ResetAppAuthenticationRoute(
                context: context
            )
        case .cancelled:
            break
        }
    }

    private func completePasscodeAuthentication() {
        beginsResetAfterAuthentication = true
        authenticationRoute = nil
    }

    private func authenticationFullScreenDidDismiss() {
        guard beginsResetAfterAuthentication else { return }
        beginsResetAfterAuthentication = false
        progressPresented = true
    }

    private func resetProgressDidDismiss() {
        guard didCompleteReset else { return }
        didCompleteReset = false
        onResetComplete()
    }
}
