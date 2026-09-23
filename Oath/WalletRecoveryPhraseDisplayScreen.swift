import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct WalletRecoveryPhraseDisplayScreen: View {
    let words: [String]
    let passphrase: String

    @Environment(\.walletSensitiveValuesProtected)
    private var sensitiveValuesProtected
    @State private var copyFeedback = WalletClipboardCopyFeedback()

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

                    Button(action: UniHaptic.action(copyPhrase)) {
                        WalletRecoveryPhraseCopyLabel(
                            state: copyFeedback.state
                        )
                            .font(.body.weight(.semibold))
                            .foregroundStyle(WalletTheme.accent)
                    }
                    .buttonStyle(.automatic)
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
        .navigationTitle("settings.wallets.recovery.navigation")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: words) { _, _ in
            copyFeedback.reset()
        }
        .onDisappear {
            copyFeedback.reset()
        }
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

            Text(verbatim: words[index])
                .font(.body.weight(.medium))
                .walletSensitiveValue()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            sensitiveValuesProtected
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

    private func copyPhrase() {
        UIPasteboard.general.setItems(
            [
                [
                    UTType.utf8PlainText.identifier:
                        words.joined(separator: " ")
                ]
            ],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(120)
            ]
        )

        copyFeedback.markCopied()
        // Keep feedback in the button action, not in a competing row gesture.
        UniHaptic.play(.successQuiet)
    }
}
