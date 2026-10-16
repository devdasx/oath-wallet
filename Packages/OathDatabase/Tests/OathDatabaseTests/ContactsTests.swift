import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class ContactsTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("contacts.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: [
            NetworkRecord(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH", decimals: 18, derivationPath: "fixture", logo: "eth", sortOrder: 0),
            NetworkRecord(id: "base", name: "Base", family: "evm", symbol: "ETH", decimals: 18, derivationPath: "fixture", logo: "base", sortOrder: 1),
            NetworkRecord(id: "bitcoin", name: "Bitcoin", family: "utxo", symbol: "BTC", decimals: 8, derivationPath: "fixture", logo: "btc", sortOrder: 2)
        ], assets: [])
        return (db, url)
    }
    private func address(_ text: String = "0x0123456789abcdef0123456789abcdef01234567", network: String = "ethereum", label: String = "") -> ContactAddressInput {
        .init(networkID: network, address: text, label: label)
    }

    func testSendRecipientsAreNetworkScopedAndObserveEditsAndDeletion() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID().uuidString
        _ = try await db.saveContact(id: UUID().uuidString, name: "Name only", addresses: [])
        let saved = try await db.saveContact(id: id, name: "Alice", addresses: [
            address(network: "ethereum", label: "Ethereum savings"),
            address(network: "base", label: "Base spending"),
            address("public-bitcoin-fixture", network: "bitcoin")
        ])
        let ethereum = try await db.sendRecipients(networkID: "ethereum")
        let base = try await db.sendRecipients(networkID: "base")
        XCTAssertEqual(ethereum.count, 1)
        XCTAssertEqual(base.count, 1)
        XCTAssertEqual(ethereum.first?.address, base.first?.address)
        XCTAssertNotEqual(ethereum.first?.id, base.first?.id)
        XCTAssertEqual(base.first?.label, "Base spending")
        let unknown = try await db.sendRecipients(networkID: "unknown")
        XCTAssertTrue(unknown.isEmpty)
        var observer = db.observeSendRecipients(networkID: "base").makeAsyncIterator()
        let initial = try await observer.next()
        XCTAssertEqual(initial, base)
        let changed = try await db.saveContact(id: id, name: "Alice renamed", addresses: saved.addresses.map(\.input), expectedRevision: saved.contact.revision)
        let renamed = try await observer.next()
        XCTAssertEqual(renamed?.first?.name, "Alice renamed")
        try await db.deleteContact(id, expectedRevision: changed.contact.revision)
        let deleted = try await observer.next()
        XCTAssertTrue(deleted?.isEmpty == true)
    }

    func testCreateEditReopenAndDeleteKeepAddressesAndSearchConsistent() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID().uuidString
        let first = try await db.saveContact(id: id, name: "  Álice Smith  ", addresses: [address(label: "Personal"), address("public-bitcoin-fixture", network: "bitcoin")])
        XCTAssertEqual(first.contact.name, "Álice Smith")
        XCTAssertEqual(first.addresses.map(\.networkID), ["ethereum", "bitcoin"])
        let found = try await db.contacts(matching: "alice per")
        XCTAssertEqual(found.map(\.id), [id])
        XCTAssertEqual(found.first?.addressCount, 2)
        let updated = try await db.saveContact(id: id, name: "Bob", addresses: [first.addresses[1].input], expectedRevision: first.contact.revision)
        XCTAssertEqual(updated.contact.revision, 2)
        XCTAssertEqual(updated.contact.createdAt, first.contact.createdAt)
        let staleSearch = try await db.contacts(matching: "alice")
        XCTAssertTrue(staleSearch.isEmpty)
        let reopened = try await OathDatabase.open(at: url)
        let saved = try await reopened.contact(id)
        XCTAssertEqual(saved, updated)
        try await reopened.deleteContact(id, expectedRevision: updated.contact.revision)
        let removed = try await db.contact(id)
        let removedSearch = try await db.contacts(matching: "Bob")
        let count = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM contactAddresses") }
        XCTAssertNil(removed)
        XCTAssertTrue(removedSearch.isEmpty)
        XCTAssertEqual(count, 0)
    }

    func testNameOnlyContactIsSearchableAndSurvivesReopen() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID().uuidString
        let created = try await db.saveContact(id: id, name: "  أحمد Smith  ", addresses: [])
        XCTAssertEqual(created.contact.name, "أحمد Smith")
        XCTAssertTrue(created.addresses.isEmpty)
        for query in ["", "أح", "smi"] {
            let list = try await db.contacts(matching: query)
            XCTAssertEqual(list.map(\.id), [id])
            XCTAssertEqual(list.first?.addressCount, 0)
        }
        let reopened = try await OathDatabase.open(at: url)
        let restored = try await reopened.contact(id)
        XCTAssertEqual(restored, created)
    }

    func testNameOnlyContactCanAddRenameEditAndRemoveLastAddress() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID().uuidString
        let created = try await db.saveContact(id: id, name: "Alice", addresses: [])
        let added = try await db.saveContact(id: id, name: created.contact.name,
            addresses: [address(label: "Personal")], expectedRevision: created.contact.revision)
        let renamed = try await db.saveContact(id: id, name: "Alice Smith",
            addresses: added.addresses.map(\.input), expectedRevision: added.contact.revision)
        XCTAssertEqual(renamed.addresses, added.addresses)
        var changed = renamed.addresses[0].input
        changed.networkID = "base"; changed.label = "Work"
        let edited = try await db.saveContact(id: id, name: renamed.contact.name,
            addresses: [changed], expectedRevision: renamed.contact.revision)
        let staleSearch = try await db.contacts(matching: "Personal")
        XCTAssertTrue(staleSearch.isEmpty)
        let workSearch = try await db.contacts(matching: "Work Base")
        XCTAssertEqual(workSearch.map(\.id), [id])
        let cleared = try await db.saveContact(id: id, name: edited.contact.name,
            addresses: [], expectedRevision: edited.contact.revision)
        XCTAssertTrue(cleared.addresses.isEmpty)
        XCTAssertEqual(cleared.contact.createdAt, created.contact.createdAt)
        XCTAssertEqual(cleared.contact.revision, 5)
        let removedAddressSearch = try await db.contacts(matching: "Work")
        XCTAssertTrue(removedAddressSearch.isEmpty)
        let contacts = try await db.contacts(matching: "Alice")
        XCTAssertEqual(contacts.first?.addressCount, 0)
        XCTAssertEqual(contacts.first?.id, id)
    }

    func testConcurrentFirstAddressesCannotOverwriteEachOther() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID().uuidString
        let created = try await db.saveContact(id: id, name: "Alice", addresses: [])
        let added = try await db.saveContact(id: id, name: created.contact.name,
            addresses: [address()], expectedRevision: created.contact.revision)
        do {
            try await db.saveContact(id: id, name: "Stale rename", addresses: [], expectedRevision: created.contact.revision)
            XCTFail("A stale name editor removed the newly added address")
        } catch { XCTAssertEqual(error as? ContactStoreError, .conflict) }
        do {
            try await db.saveContact(id: id, name: "Alice", addresses: [address(network: "base")], expectedRevision: created.contact.revision)
            XCTFail("A stale address sheet overwrote the first address")
        } catch { XCTAssertEqual(error as? ContactStoreError, .conflict) }
        let unchanged = try await db.contact(id)
        XCTAssertEqual(unchanged, added)
        try await db.deleteContact(id, expectedRevision: added.contact.revision)
        do {
            try await db.saveContact(id: id, name: "Alice", addresses: [], expectedRevision: added.contact.revision)
            XCTFail("A deleted contact was recreated")
        } catch { XCTAssertEqual(error as? ContactStoreError, .missingContact) }
    }

    func testObservationPublishesNameOnlyThenFirstAndLastAddressChanges() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID().uuidString
        var detail = db.observeContact(id).makeAsyncIterator()
        var list = db.observeContacts().makeAsyncIterator()
        _ = try await detail.next(); _ = try await list.next()
        let created = try await db.saveContact(id: id, name: "Alice", addresses: [])
        let emptyDetail = try await detail.next(), emptyList = try await list.next()
        XCTAssertEqual(emptyDetail!, created)
        XCTAssertEqual(emptyList?.first?.addressCount, 0)
        let added = try await db.saveContact(id: id, name: "Alice", addresses: [address()], expectedRevision: 1)
        let addedDetail = try await detail.next(), addedList = try await list.next()
        XCTAssertEqual(addedDetail!, added)
        XCTAssertEqual(addedList?.first?.addressCount, 1)
        let removed = try await db.saveContact(id: id, name: "Alice", addresses: [], expectedRevision: 2)
        let removedDetail = try await detail.next(), removedList = try await list.next()
        XCTAssertEqual(removedDetail!, removed)
        XCTAssertEqual(removedList?.first?.addressCount, 0)
    }

    func testMigrationPreservesExistingSettingsAndWallets() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("v4.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = try DatabaseQueue(path: url.path)
        try Schema.migrator.migrate(old, upTo: "v4_wallet_customization_completion")
        try await old.write { db in
            try db.execute(sql: "INSERT INTO settings VALUES('language','ar',1)")
            try db.execute(sql: "INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES('fixture','Existing','hd','local-fixture',1,0)")
        }
        let upgraded = try await OathDatabase.open(at: url)
        let settings = try await upgraded.settings(), wallets = try await upgraded.wallets()
        let contacts = try await upgraded.contacts()
        XCTAssertEqual(settings["language"], "ar")
        XCTAssertEqual(wallets.map(\.name), ["Existing"])
        XCTAssertTrue(contacts.isEmpty)
    }

    func testDuplicateEVMAddressesAreCaseInsensitiveButNetworksStayDistinct() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID().uuidString
        let lower = "0x0123456789abcdef0123456789abcdef01234567"
        let upper = "0x0123456789ABCDEF0123456789ABCDEF01234567"
        do {
            try await db.saveContact(id: id, name: "One", addresses: [address(lower), address(upper)])
            XCTFail("Duplicate network address was stored")
        } catch { XCTAssertEqual(error as? ContactStoreError, .duplicateAddress) }
        let absent = try await db.contact(id)
        XCTAssertNil(absent)
        let contact = try await db.saveContact(id: id, name: "One", addresses: [address(lower), address(upper, network: "base")])
        XCTAssertEqual(contact.addresses.count, 2)
        XCTAssertEqual(contact.addresses.last?.address, upper, "Display/copy preserves the original address")
    }

    func testInvalidNetworkAndForeignAddressIdentityCannotPartiallyOverwrite() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let a = try await db.saveContact(id: UUID().uuidString, name: "Alice", addresses: [address()])
        let b = try await db.saveContact(id: UUID().uuidString, name: "Bob", addresses: [address()])
        for entries in [[address(), address(network: "unknown")], [b.addresses[0].input]] {
            do {
                try await db.saveContact(id: a.contact.id, name: "Changed", addresses: entries, expectedRevision: a.contact.revision)
                XCTFail("Invalid update committed")
            } catch { XCTAssertTrue(error is ContactStoreError) }
            let unchanged = try await db.contact(a.contact.id)
            XCTAssertEqual(unchanged, a)
        }
    }

    func testConcurrentEditsHaveOneWinnerAndStaleDeleteCannotRemoveIt() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let initial = try await db.saveContact(id: UUID().uuidString, name: "Original", addresses: [address()])
        let wins = await withTaskGroup(of: Bool.self) { group in
            for name in ["First edit", "Second edit"] {
                group.addTask {
                    do {
                        try await db.saveContact(id: initial.contact.id, name: name, addresses: initial.addresses.map(\.input), expectedRevision: 1)
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await result in group where result { count += 1 }
            return count
        }
        XCTAssertEqual(wins, 1)
        do {
            try await db.deleteContact(initial.contact.id, expectedRevision: 1)
            XCTFail("A stale confirmation deleted a newer edit")
        } catch { XCTAssertEqual(error as? ContactStoreError, .conflict) }
        let current = try await db.contact(initial.contact.id)
        XCTAssertEqual(current?.contact.revision, 2)
    }

    func testDeletedContactCannotBeResurrectedByAnOldEditor() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let value = try await db.saveContact(id: UUID().uuidString, name: "Original", addresses: [address()])
        try await db.deleteContact(value.contact.id, expectedRevision: 1)
        do {
            try await db.saveContact(id: value.contact.id, name: "Old draft", addresses: value.addresses.map(\.input), expectedRevision: 1)
            XCTFail("Deleted contact was resurrected")
        } catch { XCTAssertTrue(error is ContactStoreError) }
        let remainsDeleted = try await db.contact(value.contact.id)
        XCTAssertNil(remainsDeleted)
    }

    func testObservationsPublishCommittedNameAndAddressSets() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID().uuidString
        var detail = db.observeContact(id).makeAsyncIterator()
        var list = db.observeContacts().makeAsyncIterator()
        let initialDetail = try await detail.next(), initialList = try await list.next()
        XCTAssertNil(initialDetail!)
        XCTAssertEqual(initialList, [])
        let inserted = try await db.saveContact(id: id, name: "New contact", addresses: [address(), address(network: "base")])
        let detailUpdate = try await detail.next(), listUpdate = try await list.next()
        XCTAssertEqual(detailUpdate!, inserted)
        XCTAssertEqual(listUpdate?.first?.addressCount, 2)
        let changed = try await db.saveContact(id: id, name: "Edited contact", addresses: [inserted.addresses[0].input], expectedRevision: 1)
        let edited = try await detail.next(), editedList = try await list.next()
        XCTAssertEqual(edited!, changed)
        XCTAssertEqual(editedList?.first?.name, "Edited contact")
        XCTAssertEqual(editedList?.first?.addressCount, 1)
    }

    func testSearchTreatsOperatorsLiterallyAndFindsArabicAndAddressPrefixes() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let value = try await db.saveContact(id: UUID().uuidString, name: "أحمد Smith", addresses: [address(label: "Exchange")])
        for query in ["أح", "smi", "0x012345", "smith exch", "ethereum"] {
            let result = try await db.contacts(matching: query)
            XCTAssertEqual(result.map(\.id), [value.contact.id])
        }
        for query in ["\" OR *", "' UNION SELECT *", "() NEAR", "***", "\"", "-", "NOT Nobody"] {
            let result = try await db.contacts(matching: query)
            XCTAssertTrue(result.isEmpty, "Search operators must not become executable syntax")
        }
    }

    func testInvalidDraftsDoNotCreateContacts() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let drafts: [(String, [ContactAddressInput])] = [
            (" ", [address()]), (String(repeating: "a", count: 101), [address()]),
            ("Name", [address(" ")]), ("Name", [address("not an address")]),
            ("Name", [address(label: String(repeating: "b", count: 61))]),
            ("Name\nTwo", [address()]), ("Name", [address("abc\u{202E}def")])
        ]
        for (name, addresses) in drafts {
            do {
                try await db.saveContact(id: UUID().uuidString, name: name, addresses: addresses)
                XCTFail("Invalid contact draft was saved")
            } catch { XCTAssertTrue(error is ContactStoreError) }
        }
        let saved = try await db.contacts()
        XCTAssertTrue(saved.isEmpty)
    }

    func testAddressLookupAndDisplayOrderUseIndexes() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let plans = try await db.pool.read { db in
            try [
                "EXPLAIN QUERY PLAN SELECT * FROM contactAddresses WHERE networkID='ethereum' AND addressKey='public'",
                "EXPLAIN QUERY PLAN SELECT * FROM contactAddresses WHERE contactID='contact' ORDER BY position,id",
                "EXPLAIN QUERY PLAN SELECT * FROM contacts ORDER BY name COLLATE NOCASE,id"
            ].map { sql in try Row.fetchAll(db, sql: sql).map { $0["detail"] as String }.joined(separator: " ") }
        }
        XCTAssertTrue(plans[0].contains("contact_addresses_lookup"))
        XCTAssertTrue(plans[1].contains("contact_addresses_order"))
        XCTAssertTrue(plans[2].contains("contacts_name"))
    }

    func testNetworkBrandingUpdatesSearchWithoutChangingContactRevision() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let contact = try await db.saveContact(id: UUID().uuidString, name: "Alice", addresses: [address()])
        try await db.seed(networks: [NetworkRecord(id: "ethereum", name: "New Display Name", family: "evm", symbol: "NEW",
            decimals: 18, derivationPath: "fixture", logo: "eth", sortOrder: 0)], assets: [])
        let matches = try await db.contacts(matching: "New Display")
        let unchanged = try await db.contact(contact.contact.id)
        XCTAssertEqual(matches.map(\.id), [contact.contact.id])
        XCTAssertEqual(unchanged, contact)
    }
}
