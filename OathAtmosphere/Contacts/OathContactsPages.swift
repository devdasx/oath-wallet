import SwiftUI
import OathDatabase

struct OathContactsPage: View {
    let onAdd: () -> Void
    let onSelect: (String) -> Void
    @Environment(\.oathLocalizer) private var strings
    @State private var model = OathContactsModel()
    @State private var query = ""
    @State private var retry = UUID()

    var body: some View {
        List {
            ForEach(model.contacts) { contact in
                OathButton { onSelect(contact.id) } label: {
                    OathSettingsRow(title: contact.name, icon: "person.crop.circle", truncatesTitle: true,
                        subtitle: strings.format(.contactAddressCount, strings.number(contact.addressCount)))
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .oathContactListRow()
                .accessibilityIdentifier("contacts.row.\(contact.id)")
            }
        }
        .id(strings.language.isRightToLeft)
        .oathContactList()
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(strings.text(.searchContacts)))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OathButton(action: onAdd) { Image(systemName: "plus") }
                    .oathNeutralControl()
                    .accessibilityLabel(strings.text(.addContact))
                    .accessibilityIdentifier("contacts.add")
            }
        }
        .overlay {
            if model.loading { ProgressView() }
            else if model.failed {
                OathContactsFailure(onRetry: { retry = UUID() })
            } else if model.contacts.isEmpty {
                OathEmptyStateScrollView {
                    OathEmptyState(title: strings.text(query.isEmpty ? .contactsEmpty : .noSearchResults),
                        systemImage: query.isEmpty ? "person.crop.rectangle.stack.fill" : "magnifyingglass",
                        description: strings.text(query.isEmpty ? .contactsEmptyDetail : .contactsNoResults)) {
                        if query.isEmpty {
                            OathActionButton(title: strings.text(.addContact), appearance: .secondary, action: onAdd)
                                .oathActionArea()
                        }
                    }
                }
            }
        }
        .task(id: query) { await model.observe(query: query) }
        .id(retry)
        .accessibilityIdentifier("contacts.list")
    }
}

struct OathContactDetailPage: View {
    let session: OathWalletSession
    let onEdit: (ContactSnapshot) -> Void
    let onDeleted: () -> Void
    @State private var model: OathContactDetailModel
    @State private var deletionRevision: Int64?
    @State private var addressEditor: OathContactAddressModel?
    @State private var addressRemoval: AddressRemoval?
    @State private var sendDestination: SendDestination?
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<String> = []
    @State private var rows: [ContactAddressRecord] = []
    @State private var work: Task<Void, Never>?
    @State private var retry = UUID()
    @ScaledMetric(relativeTo: .body) private var networkIconSize = 38.0
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct AddressRemoval {
        let ids: Set<String>
        let snapshot: ContactSnapshot
    }
    private struct SendDestination: Identifiable {
        let id = UUID()
        let walletID: String
        let recipient: SendRecipient
    }
    private var isAllowed: Bool { session.isUnlocked && !session.changingWallet && !session.resetting }
    private var busy: Bool { model.deleting || work != nil }
    private var canInteract: Bool { isAllowed && !busy && scenePhase != .background }
    private var selectedAddress: ContactAddressRecord? {
        selection.count == 1 ? rows.first { selection.contains($0.id) } : nil
    }

    init(id: String, session: OathWalletSession, onEdit: @escaping (ContactSnapshot) -> Void,
         onDeleted: @escaping () -> Void) {
        self.session = session; self.onEdit = onEdit; self.onDeleted = onDeleted
        _model = State(initialValue: OathContactDetailModel(id: id))
    }

    var body: some View {
        addressList
            .toolbar {
                if !rows.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Group {
                            if editMode.isEditing {
                                OathDoneButton(action: toggleEditing)
                            } else {
                                OathButton(strings.text(.editWallets), action: toggleEditing)
                                    .oathNeutralControl()
                            }
                        }
                        .disabled(!canInteract || model.snapshot == nil)
                        .accessibilityIdentifier("contacts.editAddresses")
                    }
                }
                OathContactAddressToolbar(isEditing: editMode.isEditing, addressCount: rows.count,
                    selectedCount: selection.count, canInteract: canInteract,
                    editTitle: strings.text(.contactEditAddress), deleteTitle: strings.text(.delete),
                    deleteAllTitle: strings.text(.contactDeleteAllAddresses), onEdit: {
                        guard canInteract, let snapshot = model.snapshot, let address = selectedAddress else { return }
                        addressEditor = OathContactAddressModel(snapshot: snapshot, address: address)
                    }, onDelete: {
                        guard canInteract, let snapshot = model.snapshot, !selection.isEmpty else { return }
                        addressRemoval = AddressRemoval(ids: selection, snapshot: snapshot)
                    })
            }
            .toolbar(editMode.isEditing && !rows.isEmpty ? .visible : .hidden, for: .bottomBar)
            .overlay {
                if model.loading { ProgressView() }
                else if model.failed { OathContactsFailure(onRetry: { retry = UUID() }) }
                else if model.snapshot == nil {
                    OathEmptyStateScrollView {
                        OathEmptyState(strings.text(.contactNotFound), systemImage: "person.crop.circle.badge.questionmark")
                    }
                }
            }
            .alert(strings.text(.deleteContact), isPresented: Binding(
                get: { deletionRevision != nil }, set: { if !$0 { deletionRevision = nil } }
            )) {
                if let revision = deletionRevision {
                    OathButton(strings.text(.delete), role: .destructive) {
                        guard canInteract else { return }
                        work = Task {
                            if await model.delete(revision: revision) { onDeleted() }
                            work = nil
                        }
                    }
                }
                OathButton(strings.text(.cancel), role: .cancel) { deletionRevision = nil }
            } message: { Text(strings.text(.deleteContactDetail)) }
            .alert(strings.text(.contacts), isPresented: Binding(
                get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }
            )) {
                if #available(iOS 26.0, *) {
                    OathButton(role: .confirm) { model.failure = nil }
                        .accessibilityLabel(strings.text(.done))
                        .accessibilityIdentifier("confirmation.done")
                        .oathConfirmationControl()
                } else {
                    OathButton(strings.text(.done)) { model.failure = nil }
                        .accessibilityIdentifier("confirmation.done")
                        .oathConfirmationControl()
                }
            } message: { if let failure = model.failure { Text(strings.text(failure)) } }
            .alert(strings.text(addressRemoval?.ids.count == 1 ? .removeContactAddress : .delete), isPresented: Binding(
                get: { addressRemoval != nil }, set: { if !$0 { addressRemoval = nil } }
            )) {
                if let removal = addressRemoval {
                    OathButton(strings.text(.delete), role: .destructive) {
                        guard canInteract else { return }
                        work = Task {
                            if await model.removeAddresses(removal.ids, from: removal.snapshot) {
                                selection.subtract(removal.ids)
                            }
                            updateRows()
                            work = nil
                        }
                    }
                }
                OathButton(strings.text(.cancel), role: .cancel) { addressRemoval = nil }
            } message: {
                if let removal = addressRemoval {
                    if removal.ids.count == 1 { Text(strings.text(.contactRemoveAddressDetail)) }
                    else { Text(strings.format(.contactAddressCount, strings.number(removal.ids.count))) }
                }
            }
            .sheet(item: $addressEditor) { editor in
                OathContactAddressSheet(model: editor, isAllowed: isAllowed).oathLanguage(strings.language)
            }
            .sheet(item: $sendDestination) { destination in
                OathSendFlow(session: session, walletID: destination.walletID, recipient: destination.recipient)
                    .oathLanguage(strings.language)
            }
            .task(id: retry) { await model.observe() }
            .onChange(of: model.snapshot, initial: true) { _, _ in
                if !model.deleting { updateRows() }
            }
            .onChange(of: isAllowed) { _, allowed in
                if !allowed {
                    work?.cancel(); work = nil
                    deletionRevision = nil; addressRemoval = nil; addressEditor = nil; sendDestination = nil
                    selection = []; editMode = .inactive
                }
            }
            .onDisappear { work?.cancel(); work = nil }
            .accessibilityIdentifier("contacts.detail")
    }

    private func toggleEditing() {
        guard canInteract, !rows.isEmpty else { return }
        withAnimation(reduceMotion ? nil : .default) {
            editMode = editMode.isEditing ? .inactive : .active
            selection = []
        }
    }

    private var addressList: some View {
        // Native List selection otherwise updates toolbar membership without an
        // animation transaction, so an action can snap in/out on multi-selection.
        List(selection: editMode.isEditing ? $selection.animation(reduceMotion ? nil : .default) : nil) {
            if let snapshot = model.snapshot {
                Section {
                    VStack(alignment: .leading, spacing: 0) {
                        OathSettingsRow(title: snapshot.contact.name, icon: "person.crop.circle",
                            truncatesTitle: true, accessory: .none)
                        OathButton { onEdit(snapshot) } label: {
                            OathSettingsRow(title: strings.text(.editContact), icon: "pencil")
                        }
                        .buttonStyle(OathSettingsRowButtonStyle())
                        .disabled(!canInteract || editMode.isEditing)
                        .accessibilityIdentifier("contacts.edit")
                        OathSettingsSectionRule()
                    }
                    .padding(.top, 12)
                    .selectionDisabled()
                    .oathContactListRow()
                }.listSectionSeparator(.hidden)
                Section {
                    ForEach(rows) { address in
                        Group {
                            if editMode.isEditing {
                                addressContent(address)
                            } else {
                                OathButton(feedback: nil) {
                                    guard canInteract, let walletID = session.displayedProfile?.id.uuidString else { return }
                                    sendDestination = SendDestination(walletID: walletID,
                                        recipient: .init(address: address, contactName: snapshot.contact.name))
                                } label: { addressContent(address) }
                                .buttonStyle(OathSettingsRowButtonStyle())
                                .accessibilityHint(strings.text(.sendChooseAsset))
                                .contextMenu {
                                    OathButton(strings.text(.copyAddress), feedback: nil) { OathClipboard.copy(address.address) }
                                }
                            }
                        }
                        .tag(address.id)
                        .oathContactListRow()
                        .disabled(!canInteract)
                        .moveDisabled(!editMode.isEditing || !canInteract)
                        .accessibilityIdentifier("contacts.selectAddress.\(address.id)")
                    }
                    .onMove(perform: moveAddresses)
                }.listSectionSeparator(.hidden)
                Section {
                    VStack(alignment: .leading, spacing: 0) {
                        if snapshot.addresses.count < 50 {
                            OathButton { addressEditor = OathContactAddressModel(snapshot: snapshot) } label: {
                                OathSettingsRow(title: strings.text(.addContactAddress), icon: "plus.circle")
                            }
                            .buttonStyle(OathSettingsRowButtonStyle())
                            .disabled(!canInteract || editMode.isEditing)
                            .accessibilityIdentifier("contacts.addAddress")
                        } else {
                            Text(strings.text(.contactAddressLimit)).oathFont(.footnote).foregroundStyle(.secondary).padding(20)
                        }
                        OathSettingsSectionRule()
                        OathButton(role: .destructive) { deletionRevision = snapshot.contact.revision } label: {
                            Label(strings.text(.deleteContact), systemImage: "trash")
                                .oathFont(.body).foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(20).contentShape(Rectangle())
                        }
                        .buttonStyle(OathSettingsRowButtonStyle())
                        .disabled(!canInteract || editMode.isEditing)
                        .accessibilityIdentifier("contacts.delete")
                    }
                    .padding(.bottom, 12)
                    .selectionDisabled()
                    .oathContactListRow()
                }.listSectionSeparator(.hidden)
            }
        }
        .id(strings.language.isRightToLeft)
        .oathContactList()
        .environment(\.defaultMinListRowHeight, 0)
        .environment(\.editMode, $editMode)
    }

    private func addressContent(_ address: ContactAddressRecord) -> some View {
        let network = model.networks.first { $0.id == address.networkID }
        let networkName = strings.invariant(network?.name ?? address.networkID)
        return OathListRow {
            if let logo = network?.logo { OathNetworkLogo(asset: logo, size: networkIconSize) }
            else { OathSettingsIcon(symbol: "network") }
        } content: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(networkName).oathFont(.body)
                        .foregroundStyle(Color(uiColor: .label))
                        .lineLimit(1).layoutPriority(1)
                    if !address.label.isEmpty {
                        Text(address.label.count > 18 ? String(address.label.prefix(17)) + "…" : address.label)
                            .oathFont(.caption, weight: .medium)
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                            .lineLimit(1).truncationMode(.tail)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                Text(verbatim: address.address).oathFont(.subheadline)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .lineLimit(1).truncationMode(.middle)
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityIdentifier("contacts.address.\(address.id)")
            }.frame(maxWidth: .infinity, alignment: .leading)
        } accessory: { EmptyView() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [networkName, address.label, address.address]
            .filter { !$0.isEmpty }.joined(separator: ", ")))
    }

    private func moveAddresses(from offsets: IndexSet, to destination: Int) {
        guard canInteract, editMode.isEditing, let snapshot = model.snapshot else { return }
        rows.move(fromOffsets: offsets, toOffset: destination)
        let ids = rows.map(\.id)
        work = Task {
            _ = await model.reorderAddresses(ids, from: snapshot)
            updateRows()
            work = nil
        }
    }

    private func updateRows() {
        withAnimation(reduceMotion ? nil : .default) {
            rows = model.snapshot?.addresses ?? []
            selection.formIntersection(rows.map(\.id))
            if rows.isEmpty { editMode = .inactive }
        }
    }
}

/// Separate native toolbar items let iOS own the glass groups and transitions.
/// Use real text buttons: toolbar Label adaptation can discard their titles.
struct OathContactAddressToolbar: ToolbarContent {
    let isEditing: Bool
    let addressCount: Int
    let selectedCount: Int
    let canInteract: Bool
    let editTitle: String
    let deleteTitle: String
    let deleteAllTitle: String
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some ToolbarContent {
        if isEditing && addressCount > 0 {
            if selectedCount <= 1 {
                ToolbarItem(id: "contacts.editSelectedAddress", placement: .bottomBar) {
                    OathButton(editTitle, action: onEdit)
                        .oathNeutralControl()
                        .disabled(!canInteract || selectedCount != 1)
                        .accessibilityIdentifier("contacts.editSelectedAddress")
                }
            }
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.flexible, placement: .bottomBar)
            } else {
                ToolbarItem(placement: .bottomBar) { Spacer() }
            }
            ToolbarItem(id: "contacts.removeSelectedAddresses", placement: .bottomBar) {
                OathButton(selectedCount > 1 && selectedCount == addressCount ? deleteAllTitle : deleteTitle,
                           role: .destructive, action: onDelete)
                    .tint(.red)
                    .disabled(!canInteract || selectedCount == 0)
                    .accessibilityIdentifier("contacts.removeSelectedAddresses")
            }
        }
    }
}

struct OathContactNetworkPage: View {
    let networks: [NetworkRecord]
    let selectedID: String?
    let onSelect: (String) -> Void
    @Environment(\.oathLocalizer) private var strings
    @State private var query = ""

    private var matches: [NetworkRecord] {
        networks.filter { query.isEmpty || ($0.name + " " + $0.symbol + " " + $0.id).localizedStandardContains(query) }
    }

    var body: some View {
        List {
            ForEach(matches, id: \.id) { network in
                OathButton { onSelect(network.id) } label: {
                    OathSettingsRow(title: strings.invariant(network.name), icon: "network",
                        accessory: .selection(network.id == selectedID), networkLogo: network.logo)
                }
                .buttonStyle(OathSettingsRowButtonStyle()).oathContactListRow()
                .accessibilityAddTraits(network.id == selectedID ? .isSelected : [])
                .accessibilityIdentifier("contacts.network.\(network.id)")
            }
        }
        .id(strings.language.isRightToLeft)
        .oathContactList()
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(strings.text(.searchChains)))
        .overlay {
            if matches.isEmpty {
                OathEmptyStateScrollView {
                    OathEmptyState(strings.text(.noSearchResults), systemImage: "magnifyingglass")
                }
            }
        }
    }
}

struct OathContactsFailure: View {
    let onRetry: () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathEmptyStateScrollView {
            OathEmptyState(title: strings.text(.contactsLoadFailed), systemImage: "exclamationmark.circle") {
                OathActionButton(title: strings.text(.tryAgain), appearance: .secondary, action: onRetry)
                    .oathActionArea()
            }
        }
    }
}

private extension View {
    func oathContactList() -> some View {
        listStyle(.plain).scrollContentBackground(.hidden)
            .background(Color(uiColor: OathSurfaceColors.canvas))
            .scrollDismissesKeyboard(.interactively)
    }
    func oathContactListRow() -> some View {
        listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
    }
}
