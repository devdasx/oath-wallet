import SwiftUI
import OathDatabase
import OathAnkr

struct OathSendRecipientPage: View {
    @Bindable var model: OathSendModel
    let allowed: Bool
    @Environment(\.oathLocalizer) private var strings
    @State private var focused: Field?
    @State private var pending: Action?
    @State private var scanner = false
    @State private var continueAfterScan = false
    @State private var scanError: OathRecoveryScanError?
    @State private var pendingScanError: OathRecoveryScanError?
    @State private var contactsRetry = UUID()
    private enum Field { case address, memo }
    private enum Action { case scan, next }
    private var isContinuing: Bool { pending == .next }
    private var ready: Bool { allowed && model.path.last == .recipient && pending == nil && !scanner }
    private var canContinue: Bool {
        ready && !model.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.selfTransferRestriction == nil
    }

    var body: some View {
        OathEmptyStateScrollView(centersContent: model.contactsFailed || model.recipients.isEmpty, maximumWidth: 600) {
            VStack(alignment: .leading, spacing: 24) {
                heading
                fields.disabled(!ready)
                if model.memoKind != nil || model.addressError || model.memoError || model.selfTransferRestriction != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.memoKind != nil {
                            Text(strings.text(.sendMemoHint)).oathFont(.footnote).foregroundStyle(.secondary)
                        }
                        if let restriction = model.selfTransferRestriction { error(restriction.message) }
                        else if model.addressError { error(.sendAddressInvalid) }
                        if model.memoError { error(.sendMemoInvalid) }
                    }.fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 16) {
                    OathHairline().padding(.vertical, 4)
                    Text(strings.text(.contacts)).oathFont(.title3, weight: .semibold)
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        } content: {
            contacts.disabled(!ready).padding(.horizontal, 20).padding(.bottom, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            OathSendToolbarAction(isEnabled: canContinue, isWorking: isContinuing,
                                  identifier: "send.recipient.continue", action: requestContinue)
        }
        .background {
            OathKeyboardDismissal(requested: pending != nil, onDismiss: performPendingAction).frame(width: 0, height: 0)
        }
        .task(id: "\(model.holding?.networkID ?? "")-\(contactsRetry)-\(allowed)") {
            if allowed { await model.observeRecipients() }
        }
        .oathScannerCover(isPresented: $scanner, onDismiss: {
            scanError = pendingScanError; pendingScanError = nil
            // Push only after the camera cover has finished dismissing. A
            // canceled/failed scan never advances, and this intent is one-shot.
            let shouldContinue = continueAfterScan
            continueAfterScan = false
            if shouldContinue && scanError == nil { requestContinue() }
        }) {
            OathScanner(strings: strings, onPayload: { payload in
                if allowed && scanner && model.path.last == .recipient {
                    model.recipientName = nil
                    model.address = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Do not silently strip URI parameters, tags, amounts, or a
                    // requested network from a QR. Only valid addresses proceed.
                    continueAfterScan = model.validateRecipient()
                    if !continueAfterScan { OathHaptics.shared.play(.error) }
                }
                scanner = false
            }, onFailure: { pendingScanError = $0; scanner = false },
               onClose: { scanner = false }, title: .contactScanAddress, identifier: "send.scanner",
               context: .recipient(model.chain), onRecipient: { result, chain in
                    guard allowed, scanner, model.path.last == .recipient else { scanner = false; return }
                    if model.receiveScan(result, chain: chain) {
                        continueAfterScan = model.validateRecipient()
                    } else { pendingScanError = .invalidPhrase }
                    scanner = false
               })
                .oathLanguage(strings.language).ignoresSafeArea().statusBarHidden(false)
        }
        .alert(strings.text(.contactScanAddress), isPresented: Binding(
            get: { scanError != nil }, set: { if !$0 { scanError = nil } }
        )) {
            if scanError == .denied {
                OathButton(strings.text(.openSettings)) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) {}.oathConfirmationControl()
                    .accessibilityLabel(strings.text(.done))
            } else {
                OathButton(strings.text(.done)) {}.oathConfirmationControl()
            }
        } message: { Text(strings.text(scanFailure)) }
        .onChange(of: allowed) { _, value in
            if !value { focused = nil; pending = nil; continueAfterScan = false; scanner = false; pendingScanError = nil; scanError = nil }
        }
        .onDisappear { focused = nil; pending = nil }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let holding = model.holding {
                HStack(spacing: 10) {
                    OathSendLogo(holding: holding, size: 30)
                    Text(strings.format(.sendAssetOnNetwork, holding.symbol, model.chain?.name ?? ""))
                        .oathFont(.subheadline, weight: .medium).lineLimit(2)
                }
            }
            Text(strings.format(.sendNetworkHint, model.chain?.name ?? ""))
                .oathFont(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fields: some View {
        OathInputGroup {
            OathPasteInput(hasText: !model.address.isEmpty, identifier: "send.paste", clearIdentifier: "send.clear",
                           scanIdentifier: "send.scan", onScan: requestScan, onPaste: {
                guard ready, model.address.isEmpty else { return }
                if let value = OathClipboard.paste() {
                    model.address = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.recipientName = nil; model.addressError = false; focused = .address
                    requestContinue()
                }
            }, onClear: {
                guard ready else { return }
                model.address = ""; model.recipientName = nil; model.addressError = false; focused = .address
            }) {
                OathTextInput(text: Binding(get: { model.address }, set: {
                    model.address = $0; model.recipientName = nil; model.addressError = false
                }), focused: focus(.address), title: strings.text(.contactAddress), identifier: "send.address",
                              address: true, returnKeyType: model.memoKind == nil ? .continue : .next) {
                    if model.memoKind != nil { focused = .memo }
                    else { requestContinue() }
                }
            }
            if let memo = model.memoKind {
                OathInputSeparator()
                if model.supportsStellarSend {
                    Picker(strings.text(.stellarMemoType), selection:$model.stellarMemoType) {
                        Text(strings.text(.stellarMemoText)).tag(StellarSendMemoType.text)
                        Text(strings.text(.stellarMemoID)).tag(StellarSendMemoType.id)
                        Text(strings.text(.stellarMemoHash)).tag(StellarSendMemoType.hash)
                        Text(strings.text(.stellarMemoReturn)).tag(StellarSendMemoType.returnHash)
                    }.pickerStyle(.menu).oathNeutralControl().oathInputRow()
                    OathInputSeparator()
                }
                OathTextInput(text: $model.memo, focused: focus(.memo), title: strings.text(memo), identifier: "send.memo",
                              returnKeyType: .continue, onSubmit: requestContinue)
                    .oathInputRow()
            }
        }
    }

    private var contacts: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.contactsFailed {
                OathEmptyState(title: strings.text(.contactsLoadFailed), systemImage: "exclamationmark.circle", isError: true) {
                    OathButton(strings.text(.tryAgain)) { contactsRetry = UUID() }.oathNeutralControl()
                }
            } else if model.recipients.isEmpty {
                emptyContacts
            } else {
                ForEach(model.recipients) { entry in
                    OathButton(feedback: .selection) {
                        guard ready, entry.networkID == model.holding?.networkID else { return }
                        model.setRecipient(entry); focused = nil
                        requestContinue()
                    } label: {
                        HStack(spacing: 14) {
                            Text(String(entry.name.prefix(1))).oathFont(.headline)
                                .frame(width: 40, height: 40)
                                .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.name).oathFont(.body, weight: .medium).lineLimit(1)
                                Text(entry.label.isEmpty ? entry.address : entry.label + " · " + entry.address)
                                    .oathFont(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 4)
                            if model.address == entry.address {
                                Image(systemName: "checkmark").foregroundStyle(OathOnboardingColors.blue)
                            }
                        }.foregroundStyle(.primary).padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("send.contact.\(entry.id)")
                }
            }
        }
    }

    private var emptyContacts: some View {
        // An empty network address book is expected content, not a diagnostic
        // failure. Observation errors keep the separate, reported retry state.
        OathEmptyState(strings.text(.sendNoContactsTitle), systemImage: "person.crop.rectangle.stack.fill",
                       description: strings.format(.sendNoContacts, model.chain?.name ?? ""))
            .accessibilityIdentifier("send.contacts.empty")
    }

    private var scanFailure: OathStringKey {
        switch scanError {
        case .denied: .recoveryCameraDenied
        case .unavailable: .contactCameraUnavailable
        case .invalidPhrase: .sendAddressInvalid
        default: .contactCameraFailed
        }
    }
    private func error(_ key: OathStringKey) -> some View {
        Label(strings.text(key), systemImage: "exclamationmark.circle")
            .oathFont(.footnote).foregroundStyle(.red).accessibilityIdentifier("send.recipient.error")
    }
    private func focus(_ field: Field) -> Binding<Bool> {
        Binding(get: { focused == field }, set: {
            if $0 { focused = field } else if focused == field { focused = nil }
        })
    }
    private func requestScan() {
        guard ready, model.address.isEmpty else { return }
        continueAfterScan = false
        focused = nil; pending = .scan
    }
    private func requestContinue() {
        guard canContinue else { return }
        // Set loading synchronously on tap, before keyboard dismissal begins.
        pending = .next; focused = nil
    }
    private func performPendingAction() {
        guard let pending, allowed, model.path.last == .recipient, !scanner else { self.pending = nil; return }
        switch pending {
        case .scan: self.pending = nil; scanner = true
        case .next:
            if model.validateRecipient() {
                // Keep the spinner and input lock until this page disappears.
                OathHaptics.shared.play(.navigate); model.path.append(.amount)
            } else {
                self.pending = nil
                OathHaptics.shared.play(.error)
            }
        }
    }
}
