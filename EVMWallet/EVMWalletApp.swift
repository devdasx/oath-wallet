import SwiftUI

@main
struct EVMWalletApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self)
    private var appDelegate

    @State private var databaseBootstrap =
        WalletDatabaseBootstrapController()
    @State private var deepLinkCoordinator =
        WalletAppDeepLinkCoordinator()

    init() {
        ApertureAppShortcutsProvider.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            OathSplash {
                WalletDatabaseBootstrapView(
                    controller: databaseBootstrap
                )
            }
            .writingToolsBehavior(.disabled)
            .environment(deepLinkCoordinator)
            .onOpenURL { url in
                deepLinkCoordinator.handle(url)
            }
        }
    }
}

private struct WalletDatabaseBootstrapView: View {
    let controller: WalletDatabaseBootstrapController

    var body: some View {
        Group {
            switch controller.state {
            case .idle, .loading:
                WalletTheme.background
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            case let .ready(database):
                ConfiguredWalletAppRoot(database: database)
            case let .failed(failure):
                WalletDatabaseInitializationFailureScreen(
                    failure: failure
                ) {
                    Task {
                        await controller.retry()
                    }
                }
            }
        }
        .task {
            await BitcoinFamilyElectrumClient.shared
                .prewarmBalanceConnections()
        }
        .task {
            await MarketStore.shared.run()
        }
        .task {
            await controller.startIfNeeded()
        }
    }
}

private struct ConfiguredWalletAppRoot: View {
    let database: WalletDatabase

    @Environment(\.scenePhase) private var scenePhase
    @State private var settings: WalletSettingsStore
    @State private var callSafetyMonitor = WalletCallSafetyMonitor()
    @State private var pushNotifications =
        PushNotificationCoordinator.shared

    private var appLayoutDirection: LayoutDirection {
        WalletAppLanguage.layoutDirection(
            for: settings.languageIdentifier
        )
    }

    init(database: WalletDatabase) {
        self.database = database
        _settings = State(
            initialValue: WalletSettingsStore(database: database)
        )
    }

    var body: some View {
        AppRootView(database: database)
            .id(settings.languageIdentifier)
            .preferredColorScheme(
                settings.appearance.preferredColorScheme
            )
            .environment(
                \.locale,
                WalletAppLanguage.locale(
                    for: settings.languageIdentifier
                )
            )
            .environment(
                \.layoutDirection,
                appLayoutDirection
            )
            .multilineTextAlignment(WalletTextInputLayout.alignment)
            .environment(
                \.walletCurrencyContext,
                WalletCurrencyContext(
                    code: settings.currencyCode,
                    rateStorageValue:
                        settings.currencyRateStorageValue
                )
            )
            .environment(settings)
            .environment(\.walletCallSafety, callSafetyMonitor.state)
            .task { callSafetyMonitor.start() }
            .environment(pushNotifications)
            .walletTextInputConfiguration(appLayoutDirection)
            .task(id: settings.appearance) {
                WalletAppearanceWindowCoordinator.apply(
                    settings.appearance
                )
            }
            .task {
                await pushNotifications.start(
                    database: database,
                    settings: settings
                )
            }
            .task {
                await WalletPrivateDiscoverySyncCoordinator.shared.start(
                    database: database
                )
                WalletPrivateDiscoveryBackgroundTasks.shared.install(
                    database: database
                )
            }
            .task {
                await AssetCatalogSyncService.shared.synchronize(
                    database: database
                )
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await SendNetworkFeeQuoteRepository.shared.refresh(database: database)
            }
            .task(id: settings.currencyCode) {
                await prewarmCurrencyRates()
            }
            .onChange(of: settings.languageIdentifier) {
                Task {
                    await pushNotifications.preferencesDidChange(
                        settings: settings
                    )
                }
            }
            .onChange(of: settings.currencyCode) {
                Task {
                    await pushNotifications.preferencesDidChange(
                        settings: settings
                    )
                }
            }
            .onChange(of: settings.currencyRateStorageValue) {
                Task {
                    await pushNotifications.preferencesDidChange(
                        settings: settings
                    )
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    callSafetyMonitor.refresh()
                    WalletAppearanceWindowCoordinator.apply(
                        settings.appearance
                    )
                    Task {
                        await pushNotifications.appDidBecomeActive(
                            settings: settings
                        )
                    }
                    AssetCatalogSyncService.schedule(
                        database: database
                    )
                    Task {
                        await WalletPrivateDiscoverySyncCoordinator.shared
                            .synchronizeAllWallets()
                    }
                    Task {
                        await prewarmCurrencyRates()
                    }
                } else {
                    if phase == .background {
                        WalletPrivateDiscoveryBackgroundTasks.shared
                            .schedule()
                    }
                    Task {
                        await settings.flush()
                        database.releaseMemory()
                    }
                }
            }
    }

    @MainActor
    private func prewarmCurrencyRates() async {
        guard
            let snapshot = await FXRatesClient.shared.prewarm(),
            let currency = snapshot.currency(for: settings.currencyCode)
        else {
            return
        }

        settings.updateSelectedCurrencyRate(currency.ratePerUSD)
    }
}

/// Keeps UIKit presentation boundaries in the same appearance as SwiftUI.
///
/// `preferredColorScheme` updates the root hierarchy, but an already-presented
/// sheet can retain the trait collection that its hosting controller received
/// when it was created. Applying the matching interface style to every app
/// window and its existing presentation hierarchy updates those screens
/// without rebuilding the root view or discarding navigation state.
@MainActor
enum WalletAppearanceWindowCoordinator {
    static func apply(_ appearance: WalletAppearancePreference) {
        let style = appearance.userInterfaceStyle

        for case let scene as UIWindowScene
            in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                if window.overrideUserInterfaceStyle != style {
                    window.overrideUserInterfaceStyle = style
                }

                if let rootViewController = window.rootViewController {
                    apply(style, to: rootViewController)
                }
            }
        }
    }

    private static func apply(
        _ style: UIUserInterfaceStyle,
        to viewController: UIViewController
    ) {
        if viewController.overrideUserInterfaceStyle != style {
            viewController.overrideUserInterfaceStyle = style
        }

        for child in viewController.children {
            apply(style, to: child)
        }

        if let presentedViewController =
            viewController.presentedViewController {
            apply(style, to: presentedViewController)
        }
    }
}

private extension WalletAppearancePreference {
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system:
            .unspecified
        case .dark:
            .dark
        case .light:
            .light
        }
    }
}
