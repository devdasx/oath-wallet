import SwiftUI
import UIKit

struct SendNoteEditorScreen: View {
    let initialNote: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note: String
    @State private var hasRequestedInitialFocus = false
    @FocusState private var noteFieldIsFocused: Bool

    init(
        initialNote: String,
        onSave: @escaping (String) -> Void
    ) {
        self.initialNote = initialNote
        self.onSave = onSave
        _note = State(initialValue: initialNote)
    }

    var body: some View {
        NavigationStack {
            Group {
                Form {
                    Group {
                        Section {
                            TextField(
                                "send.notes.placeholder",
                                text: noteBinding,
                                axis: .vertical
                            )
                            .walletTextInputDirection()
                            .walletNonHyphenatingInput()
                            .lineLimit(3...8)
                            .focused($noteFieldIsFocused)
                        }
                    }
                    .walletListRowSurface()
                }
                .walletListAppearance()
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .background(WalletTheme.groupedBackground)
                .navigationTitle("send.notes.section")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        WalletCloseButton {
                            dismiss()
                        }
                        .accessibilityIdentifier("sendNoteCancel")
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        WalletConfirmationButton {
                            onSave(
                                WalletTransactionNote.normalized(note) ?? ""
                            )
                            dismiss()
                        }
                        .accessibilityIdentifier("sendNoteConfirm")
                    }
                }
            }

        }
        .background {
            SendNotePresentationCompletionObserver {
                focusNoteFieldAfterPresentation()
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    @MainActor
    private func focusNoteFieldAfterPresentation() {
        guard !hasRequestedInitialFocus else { return }
        hasRequestedInitialFocus = true
        noteFieldIsFocused = true
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { note },
            set: { nextValue in
                guard WalletTransactionNote.acceptsEditableInput(
                    nextValue
                ) else {
                    return
                }
                note = nextValue
            }
        )
    }
}

struct SendBroadcastNoteSection: View {
    let note: String?
    let isPersisting: Bool
    let feedbackKey: String?
    let feedbackIsSuccess: Bool
    let onEdit: () -> Void

    var body: some View {
        Section {
            Button(action: UniHaptic.action(nil, perform: onEdit)) {
                LabeledContent {
                    Group {
                        if let note {
                            Text(verbatim: note)
                                .foregroundStyle(
                                    WalletTheme.secondaryLabel
                                )
                        } else {
                            Text("send.notes.add.action")
                                .foregroundStyle(WalletTheme.accent)
                        }
                    }
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
                } label: {
                    Text("send.notes.section")
                        .foregroundStyle(WalletTheme.primaryLabel)
                }
            }
            .disabled(isPersisting)
            .accessibilityIdentifier("sendBroadcastNote")
        } footer: {
            if let feedbackKey {
                Text(LocalizedStringKey(feedbackKey))
                    .foregroundStyle(
                        feedbackIsSuccess
                            ? WalletTheme.success
                            : WalletTheme.danger
                    )
            } else {
                Text("wallet.transaction.details.notes.footer")
            }
        }
    }
}

struct SendNotePresentationCompletionObserver:
    UIViewControllerRepresentable {
    let onDidFinishPresentation: @MainActor () -> Void

    func makeUIViewController(
        context: Context
    ) -> SendNotePresentationObserverController {
        SendNotePresentationObserverController(
            onDidFinishPresentation: onDidFinishPresentation
        )
    }

    func updateUIViewController(
        _ controller: SendNotePresentationObserverController,
        context: Context
    ) {
        controller.onDidFinishPresentation = onDidFinishPresentation
    }
}

@MainActor
final class SendNotePresentationObserverController: UIViewController {
    var onDidFinishPresentation: @MainActor () -> Void

    private var hasNotified = false

    init(
        onDidFinishPresentation: @escaping @MainActor () -> Void
    ) {
        self.onDidFinishPresentation = onDidFinishPresentation
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        self.view = view
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasNotified else { return }
        hasNotified = true
        onDidFinishPresentation()
    }
}
