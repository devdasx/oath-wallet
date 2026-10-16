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
    let isAllowed: Bool
    let onEdit: (ContactSnapshot) -> Void
    let onDeleted: () -> Void
    @State private var model: OathContactDetailModel
    @State private var deletionRevision: Int64?
    @State private var addressEditor: OathContactAddressModel?
    @State private var addressRemoval: AddressRemoval?

    private struct AddressRemoval {
        let id: String
        let snapshot: ContactSnapshot
    }
    @State private var work: Task<Void, Never>?
    @State private var copiedID: String?
    @State private var retry = UUID()
    @ScaledMetric(relativeTo: .body) private var networkIconSize = 38.0
    @Environment(\.oathLocalizer) private var strings

    init(id: String, isAllowed: Bool, onEdit: @escaping (ContactSnapshot) -> Void, onDeleted: @escaping () -> Void) {
        self.isAllowed = isAllowed; self.onEdit = onEdit; self.onDeleted = onDeleted
        _model = State(initialValue: OathContactDetailModel(id: id))
    }

    var body: some View {
        OathEmptyStateScrollView(centersContent: false) {
            if let snapshot = model.snapshot {
                VStack(alignment: .leading, spacing: 0) {
                    OathSettingsRow(title: snapshot.contact.name, icon: "person.crop.circle",
                        truncatesTitle: true, accessory: .none)
                    OathButton { onEdit(snapshot) } label: {
                        OathSettingsRow(title: strings.text(.editContact), icon: "pencil")
                    }.buttonStyle(OathSettingsRowButtonStyle())
                        .disabled(!isAllowed || model.deleting)
                        .accessibilityIdentifier("contacts.edit")
                    OathSettingsSectionRule()
                }.padding(.top, 12)
            }
        } content: {
            if let snapshot = model.snapshot {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(snapshot.addresses) { address in
                        addressRow(address, snapshot: snapshot)
                    }
                    if snapshot.addresses.count < 50 {
                        OathButton { addressEditor = OathContactAddressModel(snapshot: snapshot) } label: {
                            OathSettingsRow(title: strings.text(.addContactAddress), icon: "plus.circle")
                        }
                        .buttonStyle(OathSettingsRowButtonStyle())
                        .disabled(!isAllowed || model.deleting)
                        .accessibilityIdentifier("contacts.addAddress")
                    } else {
                        Text(strings.text(.contactAddressLimit)).oathFont(.footnote).foregroundStyle(.secondary).padding(20)
                    }
                    OathSettingsSectionRule()
                    OathButton(role: .destructive) { deletionRevision = snapshot.contact.revision } label: {
                        Label(strings.text(.deleteContact), systemImage: "trash")
                            .oathFont(.body).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20).contentShape(Rectangle())
                    }
                    .buttonStyle(OathSettingsRowButtonStyle())
                    .disabled(!isAllowed || model.deleting)
                    .accessibilityIdentifier("contacts.delete")
                    if model.deleting { ProgressView().frame(maxWidth: .infinity).padding() }
                }
                // The header's section rule already supplies the top spacing.
                .padding(.bottom, 12)
                .frame(maxWidth: 700).frame(maxWidth: .infinity)
            }
        }
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
                    guard isAllowed else { return }
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
        .alert(strings.text(.removeContactAddress), isPresented: Binding(
            get: { addressRemoval != nil }, set: { if !$0 { addressRemoval = nil } }
        )) {
            if let removal = addressRemoval {
                OathButton(strings.text(.removeContactAddress), role: .destructive) {
                    guard isAllowed, work == nil else { return }
                    work = Task {
                        _ = await model.removeAddress(removal.id, from: removal.snapshot)
                        work = nil
                    }
                }
            }
            OathButton(strings.text(.cancel), role: .cancel) { addressRemoval = nil }
        } message: { Text(strings.text(.contactRemoveAddressDetail)) }
        .sheet(item: $addressEditor) { editor in
            OathContactAddressSheet(model: editor, isAllowed: isAllowed)
                .oathLanguage(strings.language)
        }
        .task(id: retry) { await model.observe() }
        .onChange(of: isAllowed) { _, allowed in
            if !allowed { work?.cancel(); deletionRevision = nil; addressRemoval = nil; addressEditor = nil }
        }
        .onChange(of: model.snapshot) { _, _ in copiedID = nil }
        .onDisappear { work?.cancel(); work = nil }
        .accessibilityIdentifier("contacts.detail")
    }

    private func addressRow(_ address: ContactAddressRecord, snapshot: ContactSnapshot) -> some View {
        let network = model.networks.first { $0.id == address.networkID }
        let networkName = strings.invariant(network?.name ?? address.networkID)
        return HStack(spacing: 0) {
            OathButton(feedback: nil) {
                // Copy the stored value, never the visually shortened address.
                // The shared clipboard supplies the copy haptic and local-only policy.
                OathClipboard.copy(address.address)
                copiedID = address.id
            } label: {
                OathListRow {
                    if let logo = network?.logo {
                        OathNetworkLogo(asset: logo, size: networkIconSize)
                    } else {
                        OathSettingsIcon(symbol: "network")
                    }
                } content: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(networkName)
                            .oathFont(.body)
                            .foregroundStyle(Color(uiColor: .label))
                            .fixedSize(horizontal: false, vertical: true)
                        if !address.label.isEmpty {
                            Text(address.label)
                                .oathFont(.subheadline)
                                .foregroundStyle(Color(uiColor: .secondaryLabel))
                                .lineLimit(2)
                        }
                        Text(verbatim: address.address)
                            .oathFont(.subheadline)
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .environment(\.layoutDirection, .leftToRight)
                            .accessibilityIdentifier("contacts.address.\(address.id)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } accessory: {
                    if copiedID == address.id {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(OathSettingsRowButtonStyle())
            .accessibilityLabel(Text(verbatim: [networkName, address.label, address.address]
                .filter { !$0.isEmpty }.joined(separator: ", ")))
            .accessibilityHint(strings.text(.copyAddress))
            .accessibilityValue(copiedID == address.id ? strings.text(.addressCopied) : "")
            .accessibilityIdentifier("contacts.copy.\(address.id)")

            Menu {
                OathButton {
                    addressEditor = OathContactAddressModel(snapshot: snapshot, address: address)
                } label: { Label(strings.text(.contactEditAddress), systemImage: "pencil") }
                OathButton(role: .destructive) {
                    addressRemoval = AddressRemoval(id: address.id, snapshot: snapshot)
                } label: { Label(strings.text(.removeContactAddress), systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .tint(Color(uiColor: .secondaryLabel))
            .disabled(!isAllowed || model.deleting)
            .accessibilityLabel(strings.text(.contactEditAddress))
            .accessibilityIdentifier("contacts.addressOptions.\(address.id)")
            .padding(.trailing, 12)
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
