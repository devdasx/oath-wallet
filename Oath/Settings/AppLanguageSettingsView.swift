import Foundation
import SwiftUI

struct SettingsLanguage: Identifiable, Hashable {
    let id: String

    func localizedName(in locale: Locale) -> String {
        locale.localizedString(forIdentifier: id) ?? id
    }

    var nativeName: String {
        Locale(identifier: id).localizedString(forIdentifier: id) ?? id
    }

    var flag: String {
        guard let regionCode = Self.representativeRegionByIdentifier[id]
        else { return "" }
        return Self.flagEmoji(for: regionCode)
    }

    private static let representativeRegionByIdentifier: [String: String] = [
        "en": "US",
        "zh-Hans": "CN",
        "hi": "IN",
        "es": "ES",
        "fr": "FR",
        "ar": "SA",
        "bn": "BD",
        "pt-BR": "BR",
        "pt-PT": "PT",
        "ru": "RU",
        "ur": "PK",
        "id": "ID",
        "ms": "MY",
        "de": "DE",
        "ja": "JP",
        "sw": "TZ",
        "mr": "IN",
        "te": "IN",
        "tr": "TR",
        "ta": "IN",
        "zh-Hant": "TW",
        "vi": "VN",
        "ko": "KR",
        "fa": "IR",
        "ha": "NG",
        "th": "TH",
        "gu": "IN",
        "pa": "IN",
        "fil": "PH",
        "it": "IT",
        "pl": "PL",
        "uk": "UA",
        "ml": "IN",
        "kn": "IN",
        "or": "IN",
        "my": "MM",
        "nl": "NL",
        "ro": "RO",
        "am": "ET",
        "uz": "UZ",
        "sd": "PK",
        "yo": "NG",
        "ne": "NP",
        "si": "LK",
        "km": "KH",
        "cs": "CZ",
        "sk": "SK",
        "sl": "SI",
        "hr": "HR",
        "ka": "GE",
        "el": "GR",
        "sv": "SE",
        "hu": "HU",
        "he": "IL",
        "da": "DK",
        "fi": "FI",
        "nb": "NO"
    ]

    private static func flagEmoji(for regionCode: String) -> String {
        let regionalIndicatorOffset: UInt32 = 127_397
        let scalars = regionCode.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(regionalIndicatorOffset + $0.value)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

struct AppLanguageSettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(WalletSettingsStore.self) private var applicationSettings
    @State private var searchText = ""

    private let languages = WalletAppLanguage.supportedIdentifiers
        .map(SettingsLanguage.init(id:))

    var body: some View {
        let visibleLanguages = filteredLanguages

        List {
            Group {
                Section {
                    Picker(
                        "settings.language.title",
                        selection: languageSelection
                    ) {
                        ForEach(visibleLanguages) { language in
                            LanguagePickerRow(
                                flag: language.flag,
                                localizedName: language.localizedName(
                                    in: locale
                                ),
                                nativeName: language.nativeName
                            )
                            .tag(language.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } footer: {
                    Text("settings.language.footer")
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("settings.language.title")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text("settings.language.search")
        )
        .walletTextInputDirection()
        .walletAutomaticSearchToolbarBehavior()
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: applicationSettings.languageIdentifier
        )
    }

    private var languageSelection: Binding<String> {
        Binding(
            get: { applicationSettings.languageIdentifier },
            set: { identifier in
                guard identifier != applicationSettings.languageIdentifier else {
                    return
                }

                applicationSettings.setLanguageIdentifier(identifier)
                UniHaptic.play(.selection)
            }
        )
    }

    private var filteredLanguages: [SettingsLanguage] {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return languages }

        return languages.filter { language in
            language.localizedName(in: locale).localizedStandardContains(query)
                || language.nativeName.localizedStandardContains(query)
                || language.id.localizedStandardContains(query)
        }
    }
}

private struct LanguagePickerRow: View {
    let flag: String
    let localizedName: String
    let nativeName: String

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: flag)
                .font(.title2)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: localizedName)
                    .foregroundStyle(WalletTheme.primaryLabel)
                    .fixedSize(horizontal: false, vertical: true)

                Text(verbatim: nativeName)
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
