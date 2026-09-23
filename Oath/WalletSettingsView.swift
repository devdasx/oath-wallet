import Foundation
import SwiftUI

struct WalletSettingsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale
    @Environment(WalletSettingsStore.self) private var applicationSettings

    let isSecurityAuthorizationInProgress: Bool
    let onSecurityRequested: () -> Void
    let onResetRequested: () -> Void

    init(
        isSecurityAuthorizationInProgress: Bool = false,
        onSecurityRequested: @escaping () -> Void = {},
        onResetRequested: @escaping () -> Void = {}
    ) {
        self.isSecurityAuthorizationInProgress =
            isSecurityAuthorizationInProgress
        self.onSecurityRequested = onSecurityRequested
        self.onResetRequested = onResetRequested
    }

    var body: some View {
        List {
            Group {
                Section("settings.section.wallets") {
                    NavigationLink(value: WalletSettingsSearchRoute.wallets) {
                        SettingsNavigationLabel(
                            title: "settings.wallets.title",
                            icon: .wallets
                        )
                    }
                }

                Section("settings.section.preferences") {
                    Toggle(isOn: hapticPreference) {
                        SettingsRowTitle(
                            title: "settings.haptics.title",
                            icon: .haptics
                        )
                    }

                    Button(action: UniHaptic.action(nil, perform: onSecurityRequested)) {
                        SettingsNavigationLabel(
                            title: "settings.security.title",
                            icon: .security
                        )
                    }
                    .disabled(isSecurityAuthorizationInProgress)

                    NavigationLink(value: WalletSettingsSearchRoute.appearance) {
                        SettingsNavigationLabel(
                            title: "settings.appearance.title",
                            value: applicationSettings.appearance.titleKey,
                            icon: .appearance
                        )
                    }

                    NavigationLink(value: WalletSettingsSearchRoute.language) {
                        SettingsNavigationLabel(
                            title: "settings.language.title",
                            valueText: WalletAppLanguage.nativeName(
                                for: applicationSettings.languageIdentifier
                            ),
                            icon: .language
                        )
                    }

                    NavigationLink(value: WalletSettingsSearchRoute.currency) {
                        SettingsNavigationLabel(
                            title: "settings.currency.title",
                            valueText: SettingsCurrencyCatalog.localizedName(
                                for: applicationSettings.currencyCode,
                                locale: locale
                            ),
                            icon: .currency
                        )
                    }

                    NavigationLink(
                        value: WalletSettingsSearchRoute.notifications
                    ) {
                        SettingsNavigationLabel(
                            title: "settings.notifications.title",
                            icon: .notifications
                        )
                    }
                }

                Section("settings.section.tools") {
                    NavigationLink(value: WalletSettingsSearchRoute.tools) {
                        SettingsNavigationLabel(
                            title: "settings.section.tools",
                            icon: .tools
                        )
                    }
                }

                Section("settings.section.information") {
                    ForEach(WalletSettingsInformationRow.allCases) { row in
                        switch row {
                        case .about:
                            NavigationLink(
                                value: WalletSettingsSearchRoute.about
                            ) {
                                SettingsNavigationLabel(
                                    title: "settings.about.title",
                                    valueText: AppBundleMetadata.version,
                                    icon: .about
                                )
                            }
                        case .appStoreRating:
                            Button(action: UniHaptic.action(nil) {
                                openURL(
                                    AppStoreReviewDestination.writeReviewURL
                                )
                            }) {
                                SettingsNavigationLabel(
                                    title: "settings.app_store_rating.title",
                                    icon: .appStoreRating
                                )
                            }
                        }
                    }
                }


                Section {
                    Button(action: UniHaptic.action(nil, perform: onResetRequested)) {
                        Label {
                            Text("settings.reset.action")
                                .foregroundStyle(WalletTheme.danger)
                        } icon: {
                            SettingsIconTile(icon: .reset)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.automatic)
                } footer: {
                    Text("settings.reset.footer")
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("settings.title")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
        }
    }

    private var hapticPreference: Binding<Bool> {
        Binding(
            get: { applicationSettings.hapticFeedbackEnabled },
            set: { enabled in
                applicationSettings.setHapticFeedbackEnabled(enabled)
            }
        )
    }
}

private enum WalletSettingsInformationRow: CaseIterable, Identifiable {
    case about
    case appStoreRating

    var id: Self { self }
}

#Preview("Settings") {
    WalletDatabasePreviewHost { _ in
        NavigationStack {
            WalletSettingsView()
        }
    }
}
