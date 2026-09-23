import SwiftUI

struct SendBitcoinOPReturnScreen: View {
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editor: SendBitcoinOPReturnEditorState
    @FocusState private var messageFieldIsFocused: Bool

    init(
        initialMessage: String?,
        onSave: @escaping (String?) -> Void
    ) {
        self.onSave = onSave
        _editor = State(
            initialValue: SendBitcoinOPReturnEditorState(
                message: initialMessage ?? ""
            )
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                List {
                    Group {
                        Section {
                            TextField(
                                "send.bitcoin.op_return.placeholder",
                                text: messageBinding,
                                axis: .vertical
                            )
                            .walletTextInputDirection()
                            .walletNonHyphenatingInput()
                            .lineLimit(1...10)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($messageFieldIsFocused)
                            .accessibilityIdentifier(
                                "sendBitcoinOPReturnMessage"
                            )

                            Text(verbatim: byteCountDescription)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(WalletTheme.secondaryLabel)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityIdentifier(
                                    "sendBitcoinOPReturnByteCount"
                                )
                        } footer: {
                            Text("send.bitcoin.op_return.footer")
                        }
                    }
                    .walletListRowSurface()
                }
                .walletListAppearance()
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(WalletTheme.groupedBackground)
                .navigationTitle("send.bitcoin.op_return.insert")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        WalletCloseButton { dismiss() }
                            .accessibilityIdentifier(
                                "sendBitcoinOPReturnCancel"
                            )
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        WalletConfirmationButton("common.save") {
                            onSave(editor.savedMessage)
                            dismiss()
                        }
                        .disabled(!editor.isWithinLimit)
                        .accessibilityIdentifier(
                            "sendBitcoinOPReturnSave"
                        )
                    }
                }
            }

        }
        .walletFocusOnPresentation {
            messageFieldIsFocused = true
        }
    }

    private var messageBinding: Binding<String> {
        Binding(
            get: { editor.message },
            set: { candidate in
                if !editor.replaceMessage(candidate) {
                    UniHaptic.play(.error)
                }
            }
        )
    }

    private var byteCountDescription: String {
        EnglishNumbers.localized(
            "send.bitcoin.op_return.byte_count",
            editor.byteCount,
            SendBitcoinOPReturn.maximumPayloadBytes,
            editor.remainingByteCount
        )
    }
}
