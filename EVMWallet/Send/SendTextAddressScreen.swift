import SwiftUI

struct SendTextAddressScreen: View {
    let prepareRequest:
        (SendPaymentRequest) -> SendScanPreparation
    let onProceed: (SendFlowRoute) -> Void

    @State private var address = ""
    @State private var amount = ""
    @State private var addressValidationMessage: String?
    @State private var amountValidationMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case recipient
        case amount
    }

    var body: some View {
        Form {
            Group {
                Section {
                    TextField(
                        "send.recipient.section",
                        text: addressBinding,
                        prompt: Text("send.recipient.placeholder")
                    )
                    .walletTextInputDirection()
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.default)
                    .textContentType(.none)
                    .focused($focusedField, equals: .recipient)

                    TextField(
                        "send.amount.section",
                        text: amountBinding,
                        prompt: Text(
                            verbatim: WalletLocalization.string(
                                "send.amount.unselected_placeholder"
                            )
                        )
                    )
                    .walletTextInputDirection()
                    .keyboardType(.decimalPad)
                    .walletTextInputSubmitAction(identifier: "sendTextAmount", returnKeyType: .done) {
                        focusedField = nil
                    }
                    .focused($focusedField, equals: .amount)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let addressValidationMessage {
                            Text(verbatim: addressValidationMessage)
                                .foregroundStyle(WalletTheme.danger)
                        }

                        if let amountValidationMessage {
                            Text(verbatim: amountValidationMessage)
                                .foregroundStyle(WalletTheme.danger)
                        }
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .formStyle(.grouped)
        .listSectionSpacing(12)
        .contentMargins(.top, 12, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .navigationTitle(
            Text(
                verbatim: WalletLocalization.string(
                    "send.recipient_details.title"
                )
            )
        )
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .walletKeyboardUsesScreenAction()
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            PrimaryWalletButton(
                title: "common.continue",
                action: proceed
            )
            .walletActionScreenMargins()
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }

    private var addressBinding: Binding<String> {
        Binding(
            get: { address },
            set: { nextValue in
                guard
                    nextValue.utf8.count <= 255,
                    !nextValue.contains(where: \.isNewline)
                else {
                    return
                }
                address = nextValue
                addressValidationMessage = nil
            }
        )
    }

    private var amountBinding: Binding<String> {
        Binding(
            get: { amount },
            set: { nextValue in
                let normalizedInput =
                    SendDecimalAmount.normalizedDecimalKeyboardInput(
                        nextValue
                    )
                guard SendDecimalAmount.acceptsEditableInput(
                    normalizedInput,
                    maximumFractionDigits: 200
                ) else {
                    return
                }
                amount = normalizedInput
                amountValidationMessage = nil
            }
        )
    }

    @MainActor
    private func proceed() {
        focusedField = nil
        addressValidationMessage = nil
        amountValidationMessage = nil

        let trimmed = address.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            addressValidationMessage = WalletLocalization.string(
                "send.recipient.error.required"
            )
            UniHaptic.play(.error)
            return
        }

        if let issue = SendTextAddressPreparation.amountIssue(amount) {
            amountValidationMessage = issue.localizedMessage
            UniHaptic.play(.error)
            return
        }

        do {
            let request = try SendTextAddressPreparation.request(
                from: trimmed,
                amount: amount
            )
            switch prepareRequest(request) {
            case let .ready(route):
                UniHaptic.play(.selection)
                onProceed(route)
            case let .failed(message):
                addressValidationMessage = message
                UniHaptic.play(.error)
            }
        } catch let error as SendPaymentRequestError {
            addressValidationMessage = error.localizedMessage
            UniHaptic.play(.error)
        } catch let error as SendRecipientNameError {
            addressValidationMessage = error.localizedMessage
            UniHaptic.play(.error)
        } catch {
            addressValidationMessage = WalletLocalization.string(
                "send.error.unsupported_format"
            )
            UniHaptic.play(.error)
        }
    }

}

enum SendTextAddressPreparation {
    static func request(
        from address: String,
        amount: String
    ) throws -> SendPaymentRequest {
        let request = try SendPaymentRequestParser.parse(address)
        guard
            request.source == .bareAddress
                || request.source == .name
        else {
            throw SendPaymentRequestError.invalidMainnetAddress
        }

        let parsedAmount = try SendDecimalAmount.parseUserUnits(
            amount
        )
        return SendPaymentRequest(
            source: request.source,
            recipient: request.recipient,
            candidateNetworkIDs: request.candidateNetworkIDs,
            requestedNetworkID: request.requestedNetworkID,
            requestedAsset: request.requestedAsset,
            requestedAmount: .userUnits(parsedAmount.canonical),
            label: request.label,
            message: request.message,
            memo: request.memo,
            references: request.references
        )
    }

    static func amountIssue(
        _ amount: String
    ) -> SendAmountValidationIssue? {
        guard !amount.isEmpty else { return .required }
        do {
            let parsed = try SendDecimalAmount.parseUserUnits(amount)
            return parsed.isZero ? .zero : nil
        } catch {
            return .invalid
        }
    }
}
