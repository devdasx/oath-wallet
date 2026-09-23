import SwiftUI

@main
struct HomeQuickActionsMenuFixtureApp: App {
    @State private var settings = WalletSettingsStore()
    @State private var selectedAction: WalletHomeQuickAction?

    private var appLocale: Locale {
        Locale(identifier: (ProcessInfo.processInfo.environment["APERTURE_FIXTURE_LANGUAGE"] ?? "en")
               + "@numbers=latn")
    }

    private var usesBottomAnchor: Bool {
        ProcessInfo.processInfo.environment["APERTURE_FIXTURE_TOP_ANCHOR"] != "1"
    }

    private var usesLargeText: Bool {
        ProcessInfo.processInfo.environment["APERTURE_FIXTURE_LARGE_TEXT"] == "1"
    }

    private var usesDarkAppearance: Bool {
        ProcessInfo.processInfo.environment["APERTURE_FIXTURE_DARK"] == "1"
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Text(verbatim: settings.currencyCode)
                    .accessibilityIdentifier("selected-currency")
                    .navigationTitle("settings.title")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {} label: { Image(systemName: "plus") }
                                .accessibilityIdentifier("fixture-add-wallet")
                        }
                        if #available(iOS 26.0, *) {
                            ToolbarSpacer(.fixed, placement: .topBarTrailing)
                        }
                        ToolbarItem(placement: usesBottomAnchor ? .bottomBar : .topBarTrailing) {
                            WalletHomeQuickActionsMenu {
                                selectedAction = $0
                            }
                        }
                    }
                    .sheet(item: $selectedAction) { action in
                        Text(action.titleKey)
                            .accessibilityIdentifier("selected-action")
                    }
            }
            .environment(settings)
            .environment(\.locale, appLocale)
            .environment(\.layoutDirection,
                         appLocale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
            .environment(\.dynamicTypeSize, usesLargeText ? .accessibility3 : .large)
            .preferredColorScheme(usesDarkAppearance ? .dark : .light)

        }
    }

}
