import OathDiagnostics
import Foundation
import Observation
import OathDatabase

@MainActor @Observable final class OathContactsModel {
    private(set) var contacts: [ContactSummary] = []
    private(set) var loading = true
    private(set) var failed = false

    func observe(query: String) async {
        loading = true; failed = false
        do {
            let database = try await OathDataEnvironment.shared.database()
            for try await contacts in database.observeContacts(matching: query) {
                try Task.checkCancellation()
                self.contacts = contacts
                loading = false
            }
        } catch is CancellationError { }
        catch { OathDiagnostics.record(error); if !Task.isCancelled { failed = true; loading = false } }
    }
}

@MainActor @Observable final class OathContactDetailModel {
    let id: String
    private(set) var snapshot: ContactSnapshot?
    private(set) var networks: [NetworkRecord] = []
    private(set) var loading = true
    private(set) var failed = false
    private(set) var deleting = false
    var failure: OathStringKey?

    init(id: String) { self.id = id }

    func observe() async {
        loading = true; failed = false
        do {
            let database = try await OathDataEnvironment.shared.database()
            networks = try await database.networks(enabledOnly: false)
            for try await value in database.observeContact(id) {
                try Task.checkCancellation()
                if let value, let current = snapshot, value.contact.revision < current.contact.revision { continue }
                snapshot = value; loading = false
            }
        } catch is CancellationError { }
        catch { OathDiagnostics.record(error); if !Task.isCancelled { failed = true; loading = false } }
    }

    func removeAddress(_ addressID: String, from snapshot: ContactSnapshot) async -> Bool {
        await removeAddresses([addressID], from: snapshot)
    }

    func removeAddresses(_ addressIDs: Set<String>, from snapshot: ContactSnapshot) async -> Bool {
        guard !addressIDs.isEmpty, addressIDs.isSubset(of: Set(snapshot.addresses.map(\.id))) else { return false }
        return await saveAddresses(snapshot.addresses.filter { !addressIDs.contains($0.id) }.map(\.input),
                                   from: snapshot, operation: "remove_addresses")
    }

    func reorderAddresses(_ addressIDs: [String], from snapshot: ContactSnapshot) async -> Bool {
        guard addressIDs.count == snapshot.addresses.count,
              Set(addressIDs) == Set(snapshot.addresses.map(\.id)) else { return false }
        let entries = Dictionary(uniqueKeysWithValues: snapshot.addresses.map { ($0.id, $0.input) })
        return await saveAddresses(addressIDs.compactMap { entries[$0] }, from: snapshot, operation: "reorder_addresses")
    }

    private func saveAddresses(_ addresses: [ContactAddressInput], from snapshot: ContactSnapshot,
                               operation: String) async -> Bool {
        guard !deleting, snapshot.contact.id == id else { return false }
        deleting = true; failure = nil
        defer { deleting = false }
        let networks = Set(snapshot.addresses.map(\.networkID))
        return await OathDiagnostics.$chain.withValue(networks.count == 1 ? networks.first : nil) {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    try Task.checkCancellation()
                    let database = try await OathDataEnvironment.shared.database()
                    try Task.checkCancellation()
                    let saved = try await database.saveContact(id: id, name: snapshot.contact.name,
                        addresses: addresses, expectedRevision: snapshot.contact.revision)
                    guard !Task.isCancelled else { return false }
                    self.snapshot = saved
                    OathHaptics.shared.play(.success)
                    return true
                } catch is CancellationError { return false }
                catch {
                    OathDiagnostics.record(error, component: "address_book", operation: operation)
                    if !Task.isCancelled { failure = contactFailure(error) }
                    return false
                }
            }
        }
    }

    func delete(revision: Int64) async -> Bool {
        guard !deleting else { return false }
        deleting = true; failure = nil
        defer { deleting = false }
        do {
            let database = try await OathDataEnvironment.shared.database()
            try await database.deleteContact(id, expectedRevision: revision)
            if !Task.isCancelled { OathHaptics.shared.play(.success) }
            return !Task.isCancelled
        } catch is CancellationError { return false }
        catch { OathDiagnostics.record(error);
            if !Task.isCancelled {
                failure = (error as? ContactStoreError) == .conflict ? .contactChanged : .contactsSaveFailed
                OathHaptics.shared.play(.error)
            }
            return false
        }
    }
}

/// Normal creation/renaming preserves the snapshot's addresses. Receipt quick-add
/// creates the contact and its fixed destination together in one transaction.
@MainActor @Observable final class OathContactEditorModel {
    let id: String
    let revision: Int64?
    var name: String
    var addressLabel = ""
    let prefilledAddress: ContactAddressInput?
    private let addresses: [ContactAddressInput]
    private(set) var saving = false
    var failure: OathStringKey?

    init(snapshot: ContactSnapshot? = nil) {
        id = snapshot?.contact.id ?? UUID().uuidString
        revision = snapshot?.contact.revision
        name = snapshot?.contact.name ?? ""
        addresses = snapshot?.addresses.map(\.input) ?? []
        prefilledAddress = nil
    }

    init(recipient: ContactAddressInput) {
        id = UUID().uuidString
        revision = nil
        name = ""
        addresses = [recipient]
        prefilledAddress = recipient
        addressLabel = recipient.label
    }

    func save() async -> Bool {
        await OathDiagnostics.$chain.withValue(prefilledAddress?.networkID) {
            await OathDiagnostics.$operationID.withValue(UUID()) { await saveDraft() }
        }
    }

    private func saveDraft() async -> Bool {
        guard !saving else { return false }
        saving = true; failure = nil
        defer { saving = false }
        do {
            let database = try await OathDataEnvironment.shared.database()
            try Task.checkCancellation()
            var addresses = addresses
            if prefilledAddress != nil { addresses[0].label = addressLabel }
            try await database.saveContact(id: id, name: name, addresses: addresses, expectedRevision: revision,
                                           rejectExistingAddresses: prefilledAddress != nil)
            if !Task.isCancelled { OathHaptics.shared.play(.success) }
            return !Task.isCancelled
        } catch is CancellationError { return false }
        catch let error as ContactStoreError where isContactDraftValidation(error) {
            // diagnostics: contact-draft-validation — rejected form fields are
            // expected; storage, revision and configuration failures report below.
            if !Task.isCancelled { failure = contactFailure(error) }
            return false
        }
        catch { OathDiagnostics.record(error, component: "contacts", operation: "save_contact");
            if !Task.isCancelled { failure = contactFailure(error) }
            return false
        }
    }
}

/// One address draft owns its snapshot revision. Cancelling the sheet never
/// persists a draft, and concurrent edits cannot silently overwrite each other.
@MainActor @Observable final class OathContactAddressModel: Identifiable {
    let id = UUID()
    let snapshot: ContactSnapshot
    let isEditing: Bool
    var draft: ContactAddressInput
    private(set) var networks: [NetworkRecord] = []
    private(set) var loading = true
    private(set) var loadFailed = false
    private(set) var saving = false
    var failure: OathStringKey?

    init(snapshot: ContactSnapshot, address: ContactAddressRecord? = nil) {
        self.snapshot = snapshot
        isEditing = address != nil
        draft = address?.input ?? .init(networkID: "", address: "")
    }

    func loadNetworks() async {
        loading = true; loadFailed = false
        defer { loading = false }
        do {
            let database = try await OathDataEnvironment.shared.database()
            let values = try await database.networks(enabledOnly: false)
            try Task.checkCancellation()
            networks = values.filter { OathImportChain(rawValue: $0.id) != nil }
            loadFailed = networks.isEmpty
        } catch { OathDiagnostics.record(error); if !Task.isCancelled { loadFailed = true } }
    }

    func chooseNetwork(_ id: String) {
        guard !saving, networks.contains(where: { $0.id == id }) else { return }
        draft.networkID = id
        failure = nil
    }

    func receiveScan(_ payload: String) {
        // QR codes supply an address, never a guessed network or a transaction.
        // Validate against the network the user explicitly selected.
        let address = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OathContactAddressValidator.isValid(address, networkID: draft.networkID) else {
            failure = .contactAddressInvalid
            OathHaptics.shared.play(.error)
            return
        }
        draft.address = address
        failure = nil
    }

    func save() async -> Bool {
        await OathDiagnostics.$chain.withValue(OathImportChain(rawValue: draft.networkID)?.rawValue) {
            await OathDiagnostics.$operationID.withValue(UUID()) { await saveDraft() }
        }
    }

    private func saveDraft() async -> Bool {
        guard !saving, !loading, !loadFailed else { return false }
        saving = true; failure = nil
        defer { saving = false }
        let draft = draft
        do {
            let validation = Task.detached(priority: .userInitiated) {
                OathContactAddressValidator.isValid(draft.address, networkID: draft.networkID)
            }
            let valid = await withTaskCancellationHandler { await validation.value } onCancel: { validation.cancel() }
            try Task.checkCancellation()
            guard valid else { throw ContactStoreError.invalidAddress }
            var addresses = snapshot.addresses.map(\.input)
            if isEditing {
                guard let index = addresses.firstIndex(where: { $0.id == draft.id }) else {
                    throw ContactStoreError.conflict
                }
                addresses[index] = draft
            } else {
                addresses.append(draft)
            }
            let database = try await OathDataEnvironment.shared.database()
            try Task.checkCancellation()
            try await database.saveContact(id: snapshot.contact.id, name: snapshot.contact.name,
                addresses: addresses, expectedRevision: snapshot.contact.revision)
            if !Task.isCancelled { OathHaptics.shared.play(.success) }
            return !Task.isCancelled
        } catch is CancellationError { return false }
        catch let error as ContactStoreError where isContactDraftValidation(error) {
            // diagnostics: contact-draft-validation — rejected form fields are
            // expected; storage, revision and configuration failures report below.
            if !Task.isCancelled { failure = contactFailure(error) }
            return false
        }
        catch { OathDiagnostics.record(error, component: "address_book", operation: "save_address");
            if !Task.isCancelled { failure = contactFailure(error) }
            return false
        }
    }
}

private func isContactDraftValidation(_ error: ContactStoreError) -> Bool {
    switch error {
    case .invalidName, .invalidAddress, .invalidLabel, .duplicateAddress, .tooManyAddresses: true
    case .unknownNetwork, .conflict, .missingContact, .emptyAddresses: false
    }
}

@MainActor private func contactFailure(_ error: Error) -> OathStringKey {
    // Emit per failed attempt, even when an inline message stays unchanged.
    OathHaptics.shared.play(.error)
    return switch error as? ContactStoreError {
    case .invalidName: .contactNameInvalid
    case .invalidAddress, .unknownNetwork: .contactAddressInvalid
    case .invalidLabel: .contactLabelInvalid
    case .duplicateAddress: .contactDuplicateAddress
    case .tooManyAddresses: .contactAddressLimit
    case .conflict, .missingContact: .contactChanged
    default: .contactsSaveFailed
    }
}
