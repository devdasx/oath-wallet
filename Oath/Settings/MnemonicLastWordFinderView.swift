import SwiftUI
import UIKit

/// Finds every checksum-valid final word for an otherwise complete BIP-39
/// recovery phrase. Input remains transient and never leaves this screen.
struct MnemonicLastWordFinderView: View {
    @State private var precedingPhrase = ""
    @State private var candidates: [BIP39WordEntry] = []
    @State private var completedRequest: String?
    @FocusState private var isInputFocused: Bool

    @State private var backgroundExpiry = WalletSensitiveContentLifecycleState()

    var body: some View {
        List {
            Group {
                inputSection

                if completedRequest == lookupRequest {
                    candidateSection
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .walletSecretScreenExpiry(lifecycle: $backgroundExpiry)
        .navigationTitle("settings.tools.mnemonic_last_word.title")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .walletFocusOnPresentation { isInputFocused = true }
        .task(id: lookupRequest) {
            await findCandidates()
        }
        .onDisappear {
            precedingPhrase = ""
            candidates = []
            completedRequest = nil
        }
    }

    private var inputSection: some View {
        Section {
            TextField(
                "import.credential.recovery.placeholder",
                text: $precedingPhrase,
                axis: .vertical
            )
            .walletTextInputDirection()
            .walletNonHyphenatingInput()
            .lineLimit(4, reservesSpace: true)
            .walletSensitiveValue()
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isInputFocused)

            HStack(spacing: 20) {
                Button("common.paste", action: UniHaptic.action(pasteFromClipboard))

                Spacer(minLength: 0)

                if !precedingPhrase.isEmpty {
                    Button("common.clear", role: .destructive, action: UniHaptic.action {
                        precedingPhrase = ""
                        isInputFocused = true
                    })
                }
            }
            .buttonStyle(.borderless)
        } header: {
            Text("import.recovery.title")
        } footer: {
            Text("settings.tools.mnemonic_last_word.footer")
        }
    }

    private var candidateSection: some View {
        Section {
            if candidates.isEmpty {
                Text("import.recovery.suggestions.empty")
                    .foregroundStyle(WalletTheme.secondaryLabel)
            } else {
                ForEach(candidates) { candidate in
                    MnemonicLastWordCandidateRow(entry: candidate)
                }
            }
        } header: {
            Text(
                verbatim: EnglishNumbers.localized(
                    "import.recovery.suggestions.section",
                    candidates.count
                )
            )
        }
    }

    private var lookupRequest: String {
        BIP39Mnemonic.normalizedPhrase(precedingPhrase)
    }

    private var hasPermittedWordCount: Bool {
        let wordCount = lookupRequest
            .split(separator: " ")
            .count
        return BIP39Mnemonic.permittedIncompleteWordCounts
            .contains(wordCount)
    }

    @MainActor
    private func findCandidates() async {
        completedRequest = nil
        candidates = []
        guard hasPermittedWordCount else { return }

        let request = lookupRequest
        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            return
        }
        guard !Task.isCancelled, request == lookupRequest else { return }

        let worker = Task.detached(priority: .userInitiated) {
            BIP39Mnemonic.lastWordCandidates(
                precedingPhrase: request
            )
        }
        let found = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, request == lookupRequest else { return }

        candidates = found
        completedRequest = request
    }

    @MainActor
    private func pasteFromClipboard() {
        guard let value = UIPasteboard.general.string else { return }
        precedingPhrase = BIP39Mnemonic.normalizedPhrase(value)
        isInputFocused = true
        UniHaptic.play(.selection)
    }
}

private struct MnemonicLastWordCandidateRow: View {
    let entry: BIP39WordEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: entry.word)
                    .font(.body.weight(.semibold))
                    .walletSensitiveValue()
                    .textSelection(.enabled)

                Spacer(minLength: 12)

                Text(verbatim: entry.language.localizedName)
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
            }

            Text(
                EnglishNumbers.localized(
                    "import.recovery.word_list.binary",
                    entry.binaryIndex
                )
            )
            .font(.footnote.monospaced())
            .foregroundStyle(WalletTheme.secondaryLabel)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Find Last Recovery Word") {
    NavigationStack {
        MnemonicLastWordFinderView()
    }
}
