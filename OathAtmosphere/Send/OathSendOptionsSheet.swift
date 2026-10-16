import SwiftUI
import OathBitcoin

struct OathSendOptionsSheet: View {
    let network: UTXONetwork
    @State var replaceable: Bool
    @State var message: String
    let apply: (Bool, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings
    private var byteCount: Int { message.utf8.count }
    private var limit: Int { BitcoinSendOptions.maximumMessageBytes(network) }

    var body: some View {
        NavigationStack {
            Form {
                if BitcoinSendOptions.supportsRBF(network) {
                    Section {
                        Toggle(strings.text(.sendRBF), isOn: $replaceable)
                            .accessibilityIdentifier("send.options.rbf")
                            .onChange(of: replaceable) { _, _ in OathHaptics.shared.play(.selection) }
                    } footer: {
                        Text(strings.text(network == .bitcoin ? .sendRBFBitcoinHint : .sendRBFHint))
                    }
                }
                Section {
                    TextField(strings.text(.sendPublicMessage), text: $message, axis: .vertical)
                        .lineLimit(4...10).textInputAutocapitalization(.sentences).autocorrectionDisabled()
                        .oathInputRow()
                        .oathInputBackground()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("send.options.message")
                    HStack {
                        Text(strings.format(.sendMessageBytes, String(byteCount), String(limit)))
                            .foregroundStyle(byteCount > limit ? .red : .secondary)
                        Spacer()
                        if !message.isEmpty {
                            OathButton(strings.text(.clear), feedback: .selection) { message = "" }
                                .oathNeutralControl()
                        }
                    }.oathFont(.footnote)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } header: {
                    Text(strings.text(.sendOnChainMessage))
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(strings.text(.sendMessageHint))
                        if network == .bitcoin { Text(strings.text(.sendMessageBitcoinHint)) }
                        if byteCount > limit { Text(strings.text(.sendMessageTooLarge)).foregroundStyle(.red) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: OathSurfaceColors.canvas))
            .listRowSeparator(.hidden)
            .oathFont(.body).scrollDismissesKeyboard(.interactively)
            .navigationTitle(strings.text(.sendOptions)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { OathCloseButton { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    OathDoneButton {
                        apply(BitcoinSendOptions.supportsRBF(network) && replaceable, message)
                        dismiss()
                    }.disabled(byteCount > limit)
                }
            }
        }
        .oathNativeLocalization()
        .presentationBackground(Color(uiColor: OathSurfaceColors.canvas))
        .presentationDragIndicator(.visible)
    }
}
