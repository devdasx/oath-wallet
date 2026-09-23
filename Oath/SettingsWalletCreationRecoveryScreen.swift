import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsWalletCreationRecoveryScreen: View {
    let words: [String]
    let hasPassphrase: Bool
    let isSaving: Bool
    let onManagePassphrase: () -> Void
    let onContinue: () -> Void

    @Environment(\.walletSensitiveValuesProtected)
    private var sensitiveValuesProtected
    @State private var copyFeedback = WalletClipboardCopyFeedback()

    @State private var backgroundExpiry = WalletSensitiveContentLifecycleState()

    var body: some View {
        List {
            Group {
                Section {
                    ForEach(0..<rowCount, id: \.self) { rowIndex in
                        wordRow(rowIndex)
                    }

                    Button(action: UniHaptic.action(copyPhrase)) {
                        WalletRecoveryPhraseCopyLabel(
                            state: copyFeedback.state
                        )
                    }
                } header: {
                    Text("wallet.creation.recovery.title")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("wallet.creation.recovery.message")

                        Text("wallet.creation.recovery.warning")
                            .foregroundStyle(WalletTheme.danger)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .walletSecretScreenExpiry(lifecycle: $backgroundExpiry)
        .navigationTitle("wallet.creation.commit.navigation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: UniHaptic.action(nil, perform: onManagePassphrase)) {
                        Text(
                            LocalizedStringKey(
                                hasPassphrase
                                    ? "wallet.creation.passphrase.edit"
                                    : "wallet.creation.passphrase.add"
                            )
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(
                    Text("wallet.creation.options.toolbar")
                )
                .disabled(isSaving)
            }
        }
        .onChange(of: words) { _, _ in
            copyFeedback.reset()
        }
        .onDisappear {
            copyFeedback.reset()
        }
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            PrimaryWalletButton(
                title: "common.continue",
                hapticPolicy: .silent,
                action: onContinue
            )
            .disabled(isSaving || words.isEmpty)
            .walletActionScreenMargins()
            .padding(.top, 12)
            .padding(.bottom, 8)
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
        // A separate tap gesture intercepts native List row activation on iOS 26.
        UniHaptic.play(.successQuiet)
    }
}
