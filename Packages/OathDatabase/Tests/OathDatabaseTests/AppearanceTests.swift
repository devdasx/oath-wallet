import XCTest
@testable import OathDatabase

final class AppearanceTests: XCTestCase {
    func testExplicitChoiceSurvivesReopenAndUnrelatedSettingChanges() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("appearance.sqlite")
        let database = try await OathDatabase.open(at: url)
        var updates = database.observeSettings().makeAsyncIterator()
        let initial = try await updates.next()
        XCTAssertEqual(AppAppearance(settings: initial ?? [:]), .system)

        try await database.setSetting(AppAppearance.settingKey, value: "light")
        let light = try await updates.next()
        XCTAssertEqual(AppAppearance(settings: light ?? [:]), .light)
        try await database.setSetting("language", value: "ar")
        let changedLanguage = try await updates.next()
        XCTAssertEqual(AppAppearance(settings: changedLanguage ?? [:]), .light)

        let reopened = try await OathDatabase.open(at: url)
        let saved = try await reopened.settings()
        XCTAssertEqual(AppAppearance(settings: saved), .light)
        try await database.setSetting(AppAppearance.settingKey, value: "dark")
        let dark = try await updates.next()
        XCTAssertEqual(AppAppearance(settings: dark ?? [:]), .dark)
        let again = try await OathDatabase.open(at: url)
        let savedDark = try await again.settings()
        XCTAssertEqual(AppAppearance(settings: savedDark), .dark)
    }

    func testOnlyExplicitSystemSelectionRestoresDeviceFollowing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try await OathDatabase.open(at: folder.appendingPathComponent("appearance.sqlite"))
        try await database.setSetting(AppAppearance.settingKey, value: "light")
        do {
            try await database.setSetting(AppAppearance.settingKey, value: "automatic-dark")
            XCTFail("An invalid choice overwrote the user's appearance")
        } catch {
            XCTAssertEqual(error as? StoreError, .invalidValue("appearance"))
        }
        let retained = try await database.settings()
        XCTAssertEqual(AppAppearance(settings: retained), .light)
        try await database.setSetting(AppAppearance.settingKey, value: "system")
        let system = try await database.settings()
        XCTAssertEqual(AppAppearance(settings: system), .system)
    }
}
