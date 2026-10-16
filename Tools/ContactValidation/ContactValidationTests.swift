import XCTest
import OathDiagnostics
@testable import OathDatabase
@testable import ContactValidation

private actor ContactReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

@MainActor final class ContactValidationTests: XCTestCase {
    func testUserValidationKeepsFeedbackWithoutReportsAndDatabaseFailureStillReports() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = ContactReports()
        OathDiagnostics.configure(file: dir.appendingPathComponent("reports.json"), transport: capture)
        let db = try await OathDatabase.open(at: dir.appendingPathComponent("contacts.sqlite"))
        OathDataEnvironment.shared.value = db
        try await db.seed(networks: [.init(id: "near", name: "NEAR Protocol", family: "near", symbol: "NEAR",
            decimals: 24, derivationPath: "fixture", logo: "near", sortOrder: 0)], assets: [])
        let saved = try await db.saveContact(id: UUID().uuidString, name: "Private fixture contact", addresses: [])
        let address = OathContactAddressModel(snapshot: saved)
        await address.loadNetworks()
        address.chooseNetwork("near")
        for invalid in ["", "wrong..near", "alice.near word", "alice.near\u{202E}"] {
            address.draft.address = invalid
            let count = OathHaptics.shared.events.count
            let result = await address.save()
            XCTAssertFalse(result)
            XCTAssertEqual(address.failure, .contactAddressInvalid)
            XCTAssertEqual(OathHaptics.shared.events.count, count + 1)
            XCTAssertEqual(OathHaptics.shared.events.last, .error)
        }
        var stored = try await db.contact(saved.contact.id)
        XCTAssertEqual(stored?.addresses.count, 0, "Validation never persists a draft")
        address.draft.address = "alice.near"
        address.draft.label = String(repeating: "x", count: 101)
        var result = await address.save()
        XCTAssertFalse(result); XCTAssertEqual(address.failure, .contactLabelInvalid)
        address.draft.label = ""
        result = await address.save()
        XCTAssertTrue(result); XCTAssertNil(address.failure)
        XCTAssertEqual(OathHaptics.shared.events.last, .success)
        stored = try await db.contact(saved.contact.id)
        XCTAssertEqual(stored?.addresses.first?.address, "alice.near")
        let duplicate = OathContactAddressModel(snapshot: try XCTUnwrap(stored))
        await duplicate.loadNetworks(); duplicate.chooseNetwork("near")
        duplicate.draft.address = "alice.near"
        result = await duplicate.save()
        XCTAssertFalse(result); XCTAssertEqual(duplicate.failure, .contactDuplicateAddress)
        let editor = OathContactEditorModel()
        editor.name = " "
        result = await editor.save()
        XCTAssertFalse(result); XCTAssertEqual(editor.failure, .contactNameInvalid)
        let fullContact = try await db.saveContact(id: UUID().uuidString, name: "Address limit fixture",
            addresses: (0..<50).map { .init(networkID: "near", address: "contact\($0).near") })
        let overflow = OathContactAddressModel(snapshot: fullContact)
        await overflow.loadNetworks(); overflow.chooseNetwork("near")
        overflow.draft.address = "contact50.near"
        result = await overflow.save()
        XCTAssertFalse(result); XCTAssertEqual(overflow.failure, .contactAddressLimit)
        try await Task.sleep(for: .milliseconds(200))
        let validationEvents = await capture.events
        XCTAssertTrue(validationEvents.isEmpty, "Invalid fields are normal validation, not app failures")

        // A genuine SQLite failure must still leave the contact unchanged and
        // retain safe chain/operation context. No fake storage implementation.
        try await db.pool.write { connection in
            try connection.execute(sql: "CREATE TRIGGER fail_contact_write BEFORE INSERT ON contactAddresses BEGIN SELECT RAISE(ABORT, 'fixture storage failure'); END")
        }
        let failed = OathContactAddressModel(snapshot: try XCTUnwrap(stored))
        await failed.loadNetworks(); failed.chooseNetwork("near")
        failed.draft.address = "bob.near"
        result = await failed.save()
        XCTAssertFalse(result); XCTAssertEqual(failed.failure, .contactsSaveFailed)
        XCTAssertEqual(OathHaptics.shared.events.last, .error)
        stored = try await db.contact(saved.contact.id)
        XCTAssertEqual(stored?.addresses.map(\.address), ["alice.near"])
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.error.domain == "GRDB.DatabaseError" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.events
        let event = try XCTUnwrap(events.first { $0.error.domain == "GRDB.DatabaseError" })
        XCTAssertEqual(event.component, "address_book")
        XCTAssertEqual(event.operation, "save_address")
        XCTAssertEqual(event.context["chain"], "near")
        XCTAssertNotNil(event.operationID)
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for secret in [saved.contact.name, saved.contact.id, "alice.near", "bob.near", "INSERT INTO", "CREATE TRIGGER"] {
            XCTAssertFalse(encoded.contains(secret), "Diagnostics must not contain field values or SQL")
        }
        try await db.pool.write { try $0.execute(sql: "DROP TRIGGER fail_contact_write") }
        let stale = OathContactAddressModel(snapshot: saved)
        await stale.loadNetworks(); stale.chooseNetwork("near")
        stale.draft.address = "charlie.near"
        result = await stale.save()
        XCTAssertFalse(result); XCTAssertEqual(stale.failure, .contactChanged)
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.error.message == "conflict" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let conflict = await capture.events.first { $0.error.message == "conflict" }
        XCTAssertNotNil(conflict, "Revision conflicts must not be silently classified as invalid fields")
        XCTAssertNotEqual(event.operationID, conflict?.operationID)
        let canceled = Task { await failed.save() }
        canceled.cancel()
        result = await canceled.value
        XCTAssertFalse(result)
        try await Task.sleep(for: .milliseconds(100))
        let finalEvents = await capture.events
        XCTAssertEqual(finalEvents.count, 2, "Only the SQLite failure and revision conflict are app reports")
    }
}
