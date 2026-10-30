import SwiftUI
import OathDatabase

/// Receipt quick-add includes the fixed destination and a connected name/label
/// form; ordinary contact creation continues to ask only for the name.
struct OathContactEditorPage: View {
    @Bindable var model: OathContactEditorModel
    let isAllowed: Bool
    let onSaved: () -> Void
    @Environment(\.oathLocalizer) private var strings
    @State private var focused = false
    @State private var labelFocused = false
    @State private var didFocus = false
    @State private var dismissingKeyboard = false
    @State private var work: Task<Void, Never>?

    private var busy: Bool { dismissingKeyboard || model.saving }
    private var canSave: Bool { isAllowed && !busy && !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let recipient = model.prefilledAddress {
                    if let chain = OathImportChain(rawValue: recipient.networkID) {
                        HStack(spacing: 10) {
                            OathNetworkLogo(asset: chain.logoAsset, size: 32)
                            Text(strings.invariant(chain.name)).oathFont(.body, weight: .medium)
                        }.accessibilityIdentifier("contacts.prefilledNetwork")
                    }
                    OathInputGroup {
                        OathTextInput(text: $model.name, focused: $focused, title: strings.text(.contactName),
                            identifier: "contacts.name", returnKeyType: .next) {
                                focused = false; labelFocused = true
                            }.oathInputRow()
                        OathInputSeparator()
                        OathTextInput(text: $model.addressLabel, focused: $labelFocused, title: strings.text(.contactAddressLabel),
                            identifier: "contacts.addressLabel", onSubmit: requestSave)
                            .oathInputRow()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(strings.text(.contactAddress)).oathFont(.footnote).foregroundStyle(.secondary)
                        OathAddressText(address: recipient.address, identifier: "contacts.prefilledAddress", centered: false)
                    }
                } else {
                    OathTextInput(text: $model.name, focused: $focused, title: strings.text(.contactName),
                        identifier: "contacts.name", onSubmit: requestSave)
                        .oathSettingsField()
                }
                if let failure = model.failure {
                    Text(strings.text(failure)).oathFont(.footnote).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("contacts.formError")
                }
            }
            .padding(20).frame(maxWidth: 700).frame(maxWidth: .infinity)
            .disabled(busy || !isAllowed)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationBarBackButtonHidden(busy)
        .interactiveDismissDisabled(busy)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if busy {
                    ProgressView()
                        .oathConfirmationControl()
                        .accessibilityLabel(strings.text(.save))
                        .accessibilityIdentifier("contacts.saving")
                } else {
                    OathDoneButton(label: .save, action: requestSave)
                        .disabled(!canSave)
                        .accessibilityIdentifier("contacts.save")
                }
            }
        }
        .background {
            OathKeyboardDismissal(requested: dismissingKeyboard, onDismiss: startSave)
                .frame(width: 0, height: 0)
        }
        .oathAutofocus(when: isAllowed && !busy) {
            if !didFocus { didFocus = true; focused = true }
        }
        .onChange(of: isAllowed) { _, allowed in if !allowed { cancelWork() } }
        .onDisappear { cancelWork() }
        .accessibilityIdentifier("contacts.editor")
    }

    private func requestSave() {
        guard canSave, work == nil else { return }
        focused = false
        labelFocused = false
        dismissingKeyboard = true
    }

    private func startSave() {
        guard dismissingKeyboard, work == nil, isAllowed else { return }
        dismissingKeyboard = false
        work = Task {
            if await model.save(), isAllowed { onSaved() }
            work = nil
        }
    }

    private func cancelWork() {
        work?.cancel(); work = nil
        dismissingKeyboard = false
        focused = false
        labelFocused = false
    }
}

/// A single sheet owns network selection and the address draft. No data is
/// written until Add/Save succeeds; Back preserves the draft within this sheet.
struct OathContactAddressSheet: View {
    @Bindable var model: OathContactAddressModel
    let isAllowed: Bool
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String]
    @State private var retry = UUID()

    init(model: OathContactAddressModel, isAllowed: Bool) {
        self.model = model
        self.isAllowed = isAllowed
        _path = State(initialValue: model.isEditing ? ["address"] : [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if model.loadFailed { OathContactsFailure(onRetry: { retry = UUID() }) }
                else {
                    OathContactNetworkPage(networks: model.networks, selectedID: model.draft.networkID) { id in
                        guard isAllowed else { return }
                        model.chooseNetwork(id)
                        path.append("address")
                    }
                }
            }
            .oathNativeLocalization()
            .navigationTitle(strings.text(.contactChooseNetwork))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    OathButton { dismiss() } label: { Image(systemName: "chevron.backward") }
                        .oathNeutralControl()
                        .accessibilityLabel(strings.text(.back))
                        .accessibilityIdentifier("contacts.addressSheet.back")
                }
            }
            .navigationDestination(for: String.self) { _ in
                OathContactAddressEntry(model: model, isAllowed: isAllowed, onSaved: { dismiss() })
                    .oathNativeLocalization()
                    .navigationTitle(strings.text(model.isEditing ? .contactEditAddress : .addContactAddress))
                    .navigationBarTitleDisplayMode(.inline)
                    .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
            }
            .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        }
        // Match Settings' password page: extend only the existing page canvas,
        // leaving the accessory transparent and native keyboard avoidance intact.
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .task(id: retry) { await model.loadNetworks() }
        .onChange(of: isAllowed) { _, allowed in if !allowed { dismiss() } }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .oathLanguage(strings.language)
        .accessibilityIdentifier("contacts.addressSheet")
    }
}

private struct OathContactAddressEntry: View {
    @Bindable var model: OathContactAddressModel
    let isAllowed: Bool
    let onSaved: () -> Void
    @Environment(\.oathLocalizer) private var strings
    @State private var focused: Field?
    @State private var didFocus = false
    @State private var pendingAction: PendingAction?
    @State private var work: Task<Void, Never>?
    @State private var showsScanner = false
    @State private var scanError: OathRecoveryScanError?
    @State private var pendingScanError: OathRecoveryScanError?

    private enum Field { case address, label }
    private enum PendingAction { case save, scan }
    private var busy: Bool { pendingAction != nil || model.saving }
    private var ready: Bool { isAllowed && !busy && !model.loading && !model.loadFailed && !showsScanner }
    private var canSave: Bool { ready && !model.draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var saveLabel: OathStringKey { model.isEditing ? .save : .add }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let network = model.networks.first(where: { $0.id == model.draft.networkID }) {
                    OathSettingsRow(title: strings.invariant(network.name), icon: "network", accessory: .none,
                        subtitle: model.snapshot.contact.name, networkLogo: network.logo)
                        .padding(.horizontal, -20)
                }
                OathInputGroup {
                    OathPasteInput(hasText: !model.draft.address.isEmpty, identifier: "contacts.pasteAddress",
                                   clearIdentifier: "contacts.clearAddress",
                                   scanIdentifier: "contacts.scanAddress", onScan: {
                        guard ready else { return }
                        focused = nil; pendingAction = .scan
                    }, onPaste: {
                        guard ready else { return }
                        // Read the clipboard only after this explicit Paste action.
                        if let value = OathClipboard.paste() {
                            model.draft.address = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            model.failure = nil
                            focused = .address
                        }
                    }, onClear: {
                        guard ready else { return }
                        model.draft.address = ""
                        model.failure = nil
                        focused = .address
                    }) {
                        OathTextInput(text: $model.draft.address, focused: focus(.address), title: strings.text(.contactAddress),
                            identifier: "contacts.addressInput", address: true, returnKeyType: .next) { focused = .label }
                    }
                    OathInputSeparator()
                    OathTextInput(text: $model.draft.label, focused: focus(.label), title: strings.text(.contactAddressLabel),
                        identifier: "contacts.addressLabel", onSubmit: requestSave)
                        .oathInputRow()
                }
                if model.loading { ProgressView().frame(maxWidth: .infinity) }
                if model.loadFailed {
                    Text(strings.text(.contactsLoadFailed)).oathFont(.footnote).foregroundStyle(.red)
                    OathActionButton(title: strings.text(.tryAgain), appearance: .secondary) {
                        work = Task { await model.loadNetworks(); work = nil }
                    }.oathActionArea(existingInset: 20)
                }
                if let failure = model.failure {
                    Text(strings.text(failure)).oathFont(.footnote).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("contacts.addressError")
                }
            }
            .padding(20).frame(maxWidth: 700).frame(maxWidth: .infinity)
            .disabled(busy || !isAllowed)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationBarBackButtonHidden(busy)
        .interactiveDismissDisabled(busy || showsScanner)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if pendingAction == .save || model.saving {
                    ProgressView()
                        .oathConfirmationControl()
                        .accessibilityLabel(strings.text(saveLabel))
                        .accessibilityIdentifier("contacts.savingAddress")
                } else {
                    OathDoneButton(label: saveLabel, action: requestSave)
                        .disabled(!canSave)
                        .accessibilityIdentifier("contacts.saveAddress")
                }
            }
        }
        .background {
            OathKeyboardDismissal(requested: pendingAction != nil, onDismiss: performPendingAction)
                .frame(width: 0, height: 0)
        }
        .oathAutofocus(when: ready) {
            if !didFocus { didFocus = true; focused = .address }
        }
        .oathScannerCover(isPresented: $showsScanner, onDismiss: {
            scanError = pendingScanError; pendingScanError = nil
        }) {
            OathScanner(strings: strings, onPayload: { payload in
                if isAllowed { model.receiveScan(payload) }
                showsScanner = false
            }, onFailure: { error in
                pendingScanError = error; showsScanner = false
            }, onClose: { showsScanner = false }, title: .contactScanAddress, identifier: "contacts.scanner", context: .contact(OathImportChain(rawValue: model.draft.networkID)))
                .oathLanguage(strings.language)
                .ignoresSafeArea()
                .statusBarHidden(false)
        }
        .alert(strings.text(.contactScanAddress), isPresented: Binding(
            get: { scanError != nil }, set: { if !$0 { scanError = nil } }
        ), presenting: scanError) { error in
            if error == .denied {
                OathButton(strings.text(.openSettings)) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) {}
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) {}
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        } message: { error in
            Text(strings.text(scanFailureMessage(error)))
        }
        .onChange(of: isAllowed) { _, allowed in
            if !allowed { cancelWork(); showsScanner = false; scanError = nil; pendingScanError = nil }
        }
        .onDisappear { cancelWork() }
    }

    private func scanFailureMessage(_ error: OathRecoveryScanError) -> OathStringKey {
        switch error {
        case .unavailable: .contactCameraUnavailable
        case .failed: .contactCameraFailed
        case .invalidPhrase: .contactAddressInvalid
        case .denied: .recoveryCameraDenied
        }
    }

    private func requestSave() {
        guard canSave, work == nil else { return }
        focused = nil; pendingAction = .save
    }

    private func performPendingAction() {
        guard let action = pendingAction, work == nil, isAllowed else { return }
        pendingAction = nil
        switch action {
        case .scan: showsScanner = true
        case .save:
            work = Task {
                if await model.save(), isAllowed { onSaved() }
                work = nil
            }
        }
    }

    private func focus(_ field: Field) -> Binding<Bool> {
        Binding(get: { focused == field }, set: { value in
            if value { focused = field }
            else if focused == field { focused = nil }
        })
    }

    private func cancelWork() {
        work?.cancel(); work = nil
        pendingAction = nil; focused = nil
    }
}
