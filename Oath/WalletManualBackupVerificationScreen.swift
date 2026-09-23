import SwiftUI
import UIKit

struct WalletManualBackupVerificationScreen: View {
    let words: [String]
    let passphrase: String
    let onVerified: () async throws -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var answers: [Int: String]
    @State private var missingIndices: Set<Int>
    @State private var invalidWordIndices: Set<Int> = []
    @State private var isSaving = false
    @State private var verificationErrorKey: String?
    @State private var passphraseAnswer = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case word(Int)
        case passphrase
    }

    init(
        words: [String],
        passphrase: String,
        onVerified: @escaping () async throws -> Void
    ) {
        self.words = words
        self.passphrase = passphrase
        self.onVerified = onVerified

        var generator = SystemRandomNumberGenerator()
        let selected = Set(
            Array(words.indices)
                .shuffled(using: &generator)
                .prefix(min(3, words.count))
        )
        _missingIndices = State(initialValue: selected)
        _answers = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: selected.map { ($0, "") }
            )
        )
    }

    var body: some View {
        List {
            Group {
                VStack(spacing: 10) {
                    Text("wallet.creation.verification.title")
                        .font(WalletTypography.title(.title2))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    Text("wallet.creation.verification.message")
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
                } footer: {
                    if let verificationErrorKey {
                        Text(LocalizedStringKey(verificationErrorKey))
                            .foregroundStyle(WalletTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }


                if !passphrase.isEmpty {
                    Section {
                        SecureField(
                            "wallet.recovery.passphrase.verify_field",
                            text: $passphraseAnswer
                        )
                        .walletTextInputSubmitAction(
                            identifier: "manualBackupPassphrase",
                            returnKeyType: returnKeyType(for: .passphrase)
                        ) {
                            focusNextIncompleteField(after: .passphrase)
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .walletSensitiveValue()
                        .focused($focusedField, equals: .passphrase)
                    } header: {
                        Text("wallet.recovery.passphrase.verify_section")
                    } footer: {
                        Text("wallet.recovery.passphrase.verify_footer")
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .walletKeyboardUsesScreenAction()
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            verificationAction
        }
        .navigationTitle("wallet.creation.verification.navigation")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            focusedField = requiredFields.first
        }
        .onChange(of: answers) {
            verificationErrorKey = nil
        }
        .onChange(of: passphraseAnswer) {
            verificationErrorKey = nil
        }
    }

    private var rowCount: Int {
        (words.count + 1) / 2
    }

    private func wordRow(_ rowIndex: Int) -> some View {
        let leadingIndex = rowIndex * 2
        let trailingIndex = leadingIndex + 1

        return HStack(alignment: .center, spacing: 20) {
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

    @ViewBuilder
    private func wordCell(_ index: Int) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: EnglishNumbers.integer(Int64(index + 1)))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .trailing)

            if missingIndices.contains(index) {
                TextField(
                    EnglishNumbers.localized(
                        "wallet.creation.verification.word_placeholder",
                        index + 1
                    ),
                    text: answerBinding(for: index)
                )
                .walletTextInputSubmitAction(
                    identifier: "manualBackupWord\(index + 1)",
                    returnKeyType: returnKeyType(for: .word(index))
                ) {
                    focusNextIncompleteField(after: .word(index))
                }
                .walletSensitiveValue()
                .foregroundStyle(
                    invalidWordIndices.contains(index)
                        ? WalletTheme.danger
                        : WalletTheme.primaryLabel
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .word(index))
                .padding(.horizontal, 10)
                .frame(minHeight: 38)
                .background(
                    WalletTheme.tertiaryFill,
                    in: RoundedRectangle(
                        cornerRadius: 10,
                        style: .continuous
                    )
                )
                .accessibilityLabel(
                    Text(
                        EnglishNumbers.localized(
                            "wallet.creation.verification.word_number",
                            index + 1
                        )
                    )
                )
                .accessibilityHint(Text(verbatim:
                    invalidWordIndices.contains(index)
                        ? WalletLocalization.string("wallet.creation.verification.error")
                        : ""
                ))
            } else {
                Text(verbatim: words[index])
                    .font(.body.weight(.medium))
                    .walletSensitiveValue()
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 38,
                        alignment: .leading
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verificationAction: some View {
        PrimaryWalletButton(
            title: "wallet.creation.verification.confirm",
            action: verify
        )
        .disabled(!hasAllAnswers || isSaving)
        .walletActionScreenMargins()
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var hasAllAnswers: Bool {
        incompleteFields.isEmpty
    }

    private func returnKeyType(for field: Field) -> UIReturnKeyType {
        if isFieldComplete(field) && requiredFields.filter({ $0 != field }).allSatisfy(isFieldComplete) {
            return .done
        }
        return .next
    }

    private func isFieldComplete(_ field: Field) -> Bool {
        switch field {
        case .word(let index):
            return !normalized(answers[index] ?? "").isEmpty
        case .passphrase:
            return !passphraseAnswer.isEmpty
        }
    }

    private var requiredFields: [Field] {
        missingIndices.sorted().map { .word($0) }
            + (passphrase.isEmpty ? [] : [.passphrase])
    }

    private var incompleteFields: [Field] {
        requiredFields.filter { field in
            switch field {
            case .word(let index):
                normalized(answers[index] ?? "").isEmpty
            case .passphrase:
                passphraseAnswer.isEmpty
            }
        }
    }

    private func focusNextIncompleteField(after submittedField: Field) {
        let incomplete = incompleteFields
        guard !incomplete.isEmpty else {
            focusedField = nil
            WalletTextInputReturnKey.dismissKeyboard()
            return
        }

        let fields = requiredFields
        let nextIndex = (fields.firstIndex(of: submittedField) ?? -1) + 1
        // Skip completed answers and wrap to any word skipped earlier.
        let nextField = (Array(fields.dropFirst(nextIndex))
            + Array(fields.prefix(nextIndex)))
            .first { incomplete.contains($0) }
        focusedField = nextField
    }

    private var incorrectWordIndices: Set<Int> {
        Set(missingIndices.filter {
            normalized(answers[$0] ?? "") != normalized(words[$0])
        })
    }

    private func answerBinding(for index: Int) -> Binding<String> {
        Binding(
            get: { answers[index] ?? "" },
            set: { value in
                guard answers[index] != value else { return }
                answers[index] = value
                invalidWordIndices.remove(index)
            }
        )
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizedPassphrase(_ value: String) -> String {
        value.decomposedStringWithCompatibilityMapping
    }

    private func verify() {
        guard hasAllAnswers, !isSaving else { return }
        invalidWordIndices = incorrectWordIndices
        guard invalidWordIndices.isEmpty,
              normalizedPassphrase(passphraseAnswer)
                == normalizedPassphrase(passphrase) else {
            UniHaptic.play(.error)
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                verificationErrorKey =
                    "wallet.creation.verification.error"
            }
            focusedField = invalidWordIndices.min().map { .word($0) }
                ?? .passphrase
            return
        }

        isSaving = true
        verificationErrorKey = nil
        focusedField = nil
        UniHaptic.play(.successQuiet)

        Task {
            do {
                try await onVerified()
            } catch {
                UniHaptic.play(.error)
                await MainActor.run {
                    withAnimation(
                        reduceMotion ? nil : .smooth(duration: 0.24)
                    ) {
                        isSaving = false
                        verificationErrorKey =
                            "settings.wallets.backup.manual.error"
                    }
                }
            }
        }
    }
}
