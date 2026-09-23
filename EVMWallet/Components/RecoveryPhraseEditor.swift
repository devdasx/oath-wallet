import SwiftUI

/// An inline input primitive, not a navigable screen. The owning flow supplies
/// both its ephemeral editing state and the phrase consumed by validation.
struct RecoveryPhraseEditor: View {
    @Binding var state: RecoveryPhraseEditorState
    @Binding var isFocused: Bool
    let onChange: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private enum Item: Identifiable {
        case word(RecoveryPhraseEditorState.Word, position: Int)
        case input

        var id: UUID? {
            switch self {
            case .word(let word, _): word.id
            case .input: nil
            }
        }
    }

    private var hidesCompletedInput: Bool {
        !isFocused && state.editingID == nil && state.fragment.isEmpty
            && (try? WalletRecoveryCredential(mnemonic: state.text)) != nil
    }

    private var items: [Item] {
        var result = state.words.enumerated().map { index, word in
            word.id == state.editingID ? Item.input : .word(word, position: index + 1)
        }
        if state.editingID == nil && !hidesCompletedInput { result.insert(.input, at: state.inputPosition) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            wordLayout
            if state.hasContent {
                Button("common.clear", action: UniHaptic.action {
                    change { $0.clear() }
                    isFocused = true
                })
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(WalletTheme.secondaryLabel)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(WalletTheme.mutedSecondaryFill, in: Capsule())
                .contentShape(Capsule())
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("recoveryPhraseClear")
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .contain)
    }

    private var wordLayout: some View {
        RecoveryPhraseWordLayout {
            // Move one stable input among the words. Replacing the native
            // first responder cancels the keyboard's held-Delete sequence.
            ForEach(items) { item in
                switch item {
                case .input:
                    inlineInput
                case .word(let word, let position):
                    wordPill(word, position: position)
                        .transition(reduceMotion ? .identity : .scale(scale: 0.86).combined(with: .opacity))
                }
            }
        }
        // Committing words and growing the current input retain their motion.
        .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12), value: state.words)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: state.fragment)
        .transaction(value: state.editingID) { transaction in
            // One native first responder moves between word slots to preserve
            // held Delete. Change slots atomically: otherwise the newly selected
            // word is drawn in the old slot and then slides to its own position.
            // Disable the nested word/fragment animations for this change only.
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .walletSensitiveValue()
        .onChange(of: isFocused) { _, focused in
            if !focused { change { $0.finishWord() } }
        }
    }

    private var inlineInput: some View {
        HStack(spacing: 0) {
            if !state.fragment.isEmpty {
                Text(verbatim: EnglishNumbers.integer(Int64(state.inputPosition + 1)))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(invalidFragment ? WalletTheme.danger : WalletTheme.secondaryLabel)
                    .padding(.leading, 12)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            RecoveryPhraseInlineInput(
                text: state.fragment,
                isInvalid: invalidFragment,
                completion: { RecoveryPhraseCompletion.match(fragment: $0, precedingWords: state.wordsBeforeFragment) },
                hasOtherWords: state.inputPosition > 0,
                isFocused: isFocused,
                selectionRequest: state.selectionRequest,
                onFocusChange: { isFocused = $0 },
                onChange: { value in change { $0.updateFragment(value) } },
                onDeleteBackward: { wholeWordSelected in
                    if wholeWordSelected, let id = state.editingID {
                        return change { $0.remove(id) }
                    }
                    guard state.fragment.isEmpty else { return nil }
                    return change { $0.selectPreviousWord() }
                },
                onSubmit: { completion in
                    change {
                        if let completion { $0.updateFragment(completion) }
                        $0.finishWord()
                    }
                    // Validate the just-committed text, not the debounced import
                    // draft, which can still describe the preceding keystroke.
                    let isValidPhrase = (try? WalletRecoveryCredential(mnemonic: state.text)) != nil
                    isFocused = !isValidPhrase
                    return isValidPhrase
                }
            )
        }
        .id(RecoveryPhraseScrollTarget.activeWord)
        .background {
            if state.editingID == nil {
                RoundedRectangle(cornerRadius: 12)
                    .fill(WalletTheme.mutedSecondaryFill)
            }
        }
        .overlay {
            if invalidFragment && differentiateWithoutColor {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(WalletTheme.danger, lineWidth: 1.5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if state.editingID != nil {
                Capsule()
                    .strokeBorder(
                        WalletTheme.secondaryLabel,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, 4])
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func wordPill(_ word: RecoveryPhraseEditorState.Word, position: Int) -> some View {
        Group {
            if isFocused {
                Menu {
                    Button("import.recovery.word.edit", action: UniHaptic.action {
                        change { $0.edit(word.id) }
                        isFocused = true
                    })
                    Button("common.clear", role: .destructive, action: UniHaptic.action {
                        change { $0.remove(word.id) }
                        isFocused = true
                    })
                } label: {
                    wordLabel(word, position: position)
                }
            } else {
                Button(action: UniHaptic.action {
                    // Resume at the end first. Only a subsequent tap while
                    // editing opens the word's existing Edit/Clear menu.
                    change { $0.finishWord() }
                    isFocused = true
                }) {
                    wordLabel(word, position: position)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: EnglishNumbers.localized(
            "import.recovery.word_list.position", position
        )))
        .accessibilityValue(Text(verbatim: word.value))
        .accessibilityHint(Text(verbatim: RecoveryPhraseCompletion.isInvalidWord(word.value)
            ? EnglishNumbers.localized("import.recovery.validation.word", position) : ""))
        .accessibilityIdentifier("recoveryPhraseWord_\(position)")
    }

    private func wordLabel(_ word: RecoveryPhraseEditorState.Word, position: Int) -> some View {
        let invalid = RecoveryPhraseCompletion.isInvalidWord(word.value)
        return HStack(spacing: 8) {
            Text(verbatim: EnglishNumbers.integer(Int64(position)))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(invalid ? WalletTheme.danger : WalletTheme.secondaryLabel)
                .fixedSize()
            RecoveryPhraseWordLabel(word: word.value, isInvalid: invalid)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(WalletTheme.mutedSecondaryFill, in: Capsule())
        .overlay {
            if invalid && differentiateWithoutColor {
                Capsule().strokeBorder(WalletTheme.danger, lineWidth: 1.5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Capsule())
    }

    private var invalidFragment: Bool {
        RecoveryPhraseCompletion.isInvalidFragment(
            state.fragment, precedingWords: state.wordsBeforeFragment
        )
    }

    @discardableResult
    private func change(_ mutation: (inout RecoveryPhraseEditorState) -> Void) -> String {
        var next = state
        mutation(&next)
        state = next
        onChange(next.text)
        return next.fragment
    }
}

/// Scoped to the owning import scroll view; no screen or navigation state is shared.
enum RecoveryPhraseScrollTarget: Hashable { case activeWord }

extension EnvironmentValues {
    @Entry var revealRecoveryPhraseInput: RecoveryPhraseRevealAction? = nil
}

/// Keep the scroll action's inputs as values in the environment instead of a closure.
struct RecoveryPhraseRevealAction {
    let proxy: ScrollViewProxy
    let reduceMotion: Bool

    @MainActor
    func callAsFunction(_ anchor: UnitPoint) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            proxy.scrollTo(RecoveryPhraseScrollTarget.activeWord, anchor: anchor)
        }
    }
}

struct RecoveryPhraseScrollVisibility: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.environment(\.revealRecoveryPhraseInput,
                                RecoveryPhraseRevealAction(proxy: proxy, reduceMotion: reduceMotion))
        }
    }
}
