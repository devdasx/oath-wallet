import SwiftUI

private enum OathWebsiteLinks {
    static let privacyPolicy = URL(
        string: "https://oathwallet.org/privacy"
    )!
    static let termsOfUse = URL(
        string: "https://oathwallet.org/terms"
    )!
}

enum AppBundleMetadata {
    static var version: String {
        bundleValue(for: "CFBundleShortVersionString")
    }

    static var build: String {
        bundleValue(for: "CFBundleVersion")
    }

    static var localizedVersionSummary: String {
        let label = String(localized: "settings.about.version")
        return "\(label) \(version)"
    }

    private static func bundleValue(for key: String) -> String {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: key
        ) as? String else {
            return "—"
        }

        let trimmedValue = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmedValue.isEmpty ? "—" : trimmedValue
    }
}

struct AboutSettingsView: View {
    var body: some View {
        List {
            Group {
                Section("settings.about.app_details.section") {
                    LabeledContent("settings.about.version") {
                        Text(verbatim: AppBundleMetadata.version)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("settings.about.build") {
                        Text(verbatim: AppBundleMetadata.build)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    NavigationLink {
                        Group {
                            VersionHistorySettingsView()
                        }

                    } label: {
                        Text("settings.about.history.section")
                            .foregroundStyle(WalletTheme.primaryLabel)
                    }
                }

                Section("settings.about.legal.section") {
                    ExternalWebsiteLinkRow(
                        title: "settings.about.privacy",
                        destination: OathWebsiteLinks.privacyPolicy
                    )

                    ExternalWebsiteLinkRow(
                        title: "settings.about.terms",
                        destination: OathWebsiteLinks.termsOfUse
                    )
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("settings.about.title")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ExternalWebsiteLinkRow: View {
    let title: LocalizedStringKey
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack {
                Text(title)
                    .foregroundStyle(WalletTheme.primaryLabel)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
    }
}
