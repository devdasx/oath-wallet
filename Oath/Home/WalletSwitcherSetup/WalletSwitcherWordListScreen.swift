import Foundation
import SwiftUI

@MainActor
struct WalletSwitcherWordListScreen: View {
    @State private var selectedLanguage: BIP39Language
    @State private var searchText = ""

    init(initialLanguage: BIP39Language) {
        _selectedLanguage = State(initialValue: initialLanguage)
    }

    var body: some View {
        List {
            Group {
                Section {
                    Picker(
                        "import.recovery.word_list.language",
                        selection: $selectedLanguage
                    ) {
                        ForEach(
                            BIP39Mnemonic.supportedLanguages,
                            id: \.self
                        ) { language in
                            Text(LocalizedStringKey(language.localizationKey))
                                .tag(language)
                        }
                    }
                } footer: {
                    Text("import.recovery.word_list.language.footer")
                }

                Section {
                    if visibleEntries.isEmpty {
                        Text("import.recovery.word_list.empty")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleEntries) { entry in
                            BIP39WordListRow(entry: entry)
                        }
                    }
                } header: {
                    Text("import.recovery.word_list.words.section")
                } footer: {
                    Text("import.recovery.word_list.binary.footer")
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("import.recovery.word_list.title")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text("import.recovery.word_list.search")
        )
        .walletTextInputDirection()
        .walletAutomaticSearchToolbarBehavior()
        .scrollDismissesKeyboard(.interactively)
    }

    private var visibleEntries: [BIP39WordEntry] {
        let entries = BIP39Mnemonic.wordEntries(for: selectedLanguage)
        let query = normalizedSearchValue(searchText)
        guard !query.isEmpty else { return entries }

        return entries.filter { entry in
            normalizedSearchValue(entry.word).contains(query)
                || entry.binaryIndex.contains(query)
                || String(entry.index).contains(query)
                || String(entry.index + 1).contains(query)
        }
    }

    private func normalizedSearchValue(_ value: String) -> String {
        value
            .decomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale.current
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct BIP39WordListRow: View {
    let entry: BIP39WordEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: entry.word)
                    .font(.body)

                Spacer(minLength: 12)

                Text(
                    EnglishNumbers.localized(
                        "import.recovery.word_list.position",
                        entry.index + 1
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text(
                EnglishNumbers.localized(
                    "import.recovery.word_list.binary",
                    entry.binaryIndex
                )
            )
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }
}
