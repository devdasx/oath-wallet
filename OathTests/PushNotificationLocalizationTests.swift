import Foundation
import GRDB
import Testing
@testable import Aperture

struct PushNotificationLocalizationTests {
    // Foundation may insert directional isolation around interpolated values.
    // Compare visible content without removing those protections in production.
    private func visible(_ value: String) -> String {
        value.unicodeScalars.filter { !(0x2066...0x2069).contains($0.value) }
            .map(String.init).joined()
    }

    private func record(symbol: String? = "BTC") throws -> DBNotificationRecord {
        DBNotificationRecord(
            id: "localization-test", profileID: WalletDatabase.defaultProfileID,
            category: "received", titleKey: "notification.received.title",
            bodyKey: "notification.received.body.unpriced",
            argumentsJSON: try JSONEncoder().encode(["429.88", "USD", "Bitcoin"]),
            relatedTransactionID: nil, createdAt: 0, readAt: nil, deliveredAt: 0,
            remoteNotificationID: "628d9f45-ce69-4f5d-aa18-50371ea19d0c",
            titleText: "Received: BTC", bodyText: "Received 429.88 USD through Bitcoin.",
            assetSymbol: symbol
        )
    }

    @Test(arguments: WalletAppLanguage.supportedIdentifiers)
    func persistedEnglishIsRenderedInSelectedLanguage(language: String) throws {
        let result = PushNotificationContentFormatter.content(for: try record(), languageIdentifier: language)
        #expect(result.title.contains("BTC"))
        #expect(!result.title.contains("USD"))
        #expect(visible(result.body).contains("$429.88"))
        #expect(result.body.contains("Bitcoin"))
        #expect(!result.body.contains("%@"))
        if language != "en" {
            #expect(result.title != "Received: BTC")
            #expect(result.body != "Received 429.88 USD through Bitcoin.")
        }
    }

    @Test
    func sameStoredNotificationChangesLanguageWithoutChangingAmounts() throws {
        let item = try record()
        let arabic = PushNotificationContentFormatter.content(for: item, languageIdentifier: "ar")
        #expect(visible(arabic.title) == "تم الاستلام BTC")
        #expect(visible(arabic.body) == "تم استلام $429.88 عبر Bitcoin")
        let english = PushNotificationContentFormatter.content(for: item, languageIdentifier: "en")
        #expect(english.body == "Received $429.88 through Bitcoin")
        #expect(english.title == "Received BTC")
    }

    @Test
    func olderFiatPushRecoversTickerFromRenderedTitle() throws {
        let result = PushNotificationContentFormatter.content(for: try record(symbol: nil), languageIdentifier: "ar")
        #expect(visible(result.title) == "تم الاستلام BTC")
    }

    @Test
    func missingAssetIdentityNeverLabelsFiatCurrencyAsTheTransferredAsset() throws {
        var item = try record(symbol: nil)
        item.titleText = nil
        let result = PushNotificationContentFormatter.content(for: item, languageIdentifier: "en")
        #expect(result.title == "Aperture Notification")
        #expect(result.body == "Received 429.88 USD through Bitcoin.")
    }

    @Test @MainActor
    func localizationBackfillProgressPersistsWithoutDeletingNotifications() async throws {
        let database = try WalletDatabase.temporary()
        try await PushNotificationRegistrationRepository(database: database).prepareInstallationIdentity(
            installationID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            remoteUserID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        )
        let persistence = PushNotificationPersistence(database: database)
        #expect(try await persistence.needsLocalizationBackfill())
        try await persistence.setHistoryBackfillCursor("opaque-cursor")
        #expect(try await persistence.historyBackfillCursor() == "opaque-cursor")
        try await persistence.completeLocalizationBackfill()
        #expect(try await !persistence.needsLocalizationBackfill())
    }

    @Test
    func olderArabicTitleRecoversSymbolWithoutRetainingDirectionMarkers() throws {
        var item = try record(symbol: nil)
        item.titleText = "تم الاستلام: \u{2068}BTC\u{2069}"
        let result = PushNotificationContentFormatter.content(for: item, languageIdentifier: "en")
        #expect(result.title == "Received BTC")
    }

    @Test
    func positionalTemplatesKeepWalletAmountAndNetworkInTheirOwnPlaces() throws {
        var item = try record()
        // Use the legacy four-argument body from older installed app versions.
        item = DBNotificationRecord(
            id: item.id, profileID: item.profileID, category: "received",
            titleKey: item.titleKey, bodyKey: "notification.received.body",
            argumentsJSON: try JSONEncoder().encode(["1.25", "BTC", "Travel", "Bitcoin"]),
            relatedTransactionID: nil, createdAt: 0, readAt: nil, deliveredAt: nil
        )
        #expect(PushNotificationContentFormatter.content(for: item, languageIdentifier: "fil").body
            == "Nakatanggap ang wallet na Travel ng 1.25 BTC sa network na Bitcoin.")
        #expect(PushNotificationContentFormatter.content(for: item, languageIdentifier: "th").body
            == "กระเป๋าเงิน Travel ได้รับ 1.25 BTC ผ่านเครือข่าย Bitcoin")
    }

    @Test(arguments: [
        ("429.88", "USD", "$429.88"), ("1,234.56", "EUR", "€1,234.56"),
        ("999999999999999999.01", "USD", "$999999999999999999.01")
    ])
    func currencySymbolsPreserveEveryDigit(amount: String, code: String, expected: String) {
        #expect(EnglishNumbers.notificationCurrency(amount, currencyCode: code) == expected)
    }

    @Test
    func currencyFormattingRejectsInvalidAmountsAndCryptoTickers() {
        #expect(EnglishNumbers.notificationCurrency("1,23.00", currencyCode: "USD") == nil)
        #expect(EnglishNumbers.notificationCurrency("1.25", currencyCode: "BTC") == nil)
        #expect(EnglishNumbers.notificationCurrency("٤٢٩.٨٨", currencyCode: "USD") == nil)
    }

    @Test
    func payloadReadsBothNewMetadataAndLegacyNativeLocalization() throws {
        let base: [AnyHashable: Any] = [
            "notification_id": "628d9f45-ce69-4f5d-aa18-50371ea19d0c", "category": "received",
            "aps": ["alert": ["title-loc-args": ["BTC"], "loc-key": "notification.received.body.unpriced",
                              "loc-args": ["429.88", "USD", "Bitcoin"]]]
        ]
        let legacy = try #require(PushNotificationPayload(userInfo: base))
        #expect(legacy.assetSymbol == "BTC")
        #expect(legacy.localizationArguments == ["429.88", "USD", "Bitcoin"])
        var current = base
        current["asset_symbol"] = "$BONK"
        #expect(PushNotificationPayload(userInfo: current)?.assetSymbol == "$BONK")
    }

    @Test @MainActor
    func historyRepairsExistingFiatMetadataAndSurvivesDatabaseRoundTrip() async throws {
        let database = try WalletDatabase.temporary()
        let old = try record(symbol: nil)
        try await database.pool.write { db in try old.insert(db) }
        let item = PushNotificationHistoryItem(
            notificationID: old.remoteNotificationID!, category: .received, state: .sent,
            titleKey: old.titleKey, bodyKey: old.bodyKey, arguments: ["429.88", "USD", "Bitcoin"],
            title: nil, body: nil, walletID: nil, networkID: "bitcoin", transactionHash: nil,
            assetSymbol: "BTC", createdAt: "2026-09-11T00:00:00.000Z", sentAt: nil, openedAt: nil
        )
        let persistence = PushNotificationPersistence(database: database)
        let result = try await persistence.record(historyItems: [item])
        #expect(result.existingCount == 1)
        let saved = try await database.pool.read { db in try DBNotificationRecord.fetchOne(db, key: old.id) }
        #expect(saved?.assetSymbol == "BTC")
        #expect(saved?.titleText == old.titleText)
        let restored = try #require(saved)
        let rendered = PushNotificationContentFormatter.content(for: restored, languageIdentifier: "ar")
        #expect(visible(rendered.title) == "تم الاستلام BTC")
    }
}
