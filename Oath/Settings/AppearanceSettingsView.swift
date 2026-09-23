import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WalletSettingsStore.self) private var applicationSettings

    var body: some View {
        List {
            Group {
                Section {
                    Picker(
                        "settings.appearance.title",
                        selection: appearanceSelection
                    ) {
                        ForEach(WalletAppearancePreference.allCases) { option in
                            Text(option.titleKey)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } footer: {
                    Text(applicationSettings.appearance.footerKey)
                        .id(applicationSettings.appearance)
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("settings.appearance.title")
        .navigationBarTitleDisplayMode(.inline)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.22),
            value: applicationSettings.appearance
        )
    }

    private var appearanceSelection:
        Binding<WalletAppearancePreference> {
        Binding(
            get: { applicationSettings.appearance },
            set: { applicationSettings.setAppearance($0) }
        )
    }
}
