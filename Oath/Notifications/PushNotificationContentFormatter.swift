import Foundation

enum PushNotificationContentFormatter {
    private static let maximumArgumentsJSONBytes = 4_096
    private static let maximumArgumentBytes = 256
    private static let formatLocale = Locale(identifier: "en_US_POSIX")

    static func content(
        for notification: DBNotificationRecord,
        languageIdentifier: String = WalletAppLanguage.selectedIdentifier
    ) -> PushNotificationDisplayContent {
        let bundle = WalletAppLanguage.localizedBundle(for: languageIdentifier)
        func localized(_ key: String) -> String {
            bundle.localizedString(forKey: key, value: nil, table: nil)
        }
        let category = PushNotificationCategory(
            rawValue: notification.category
        ) ?? .admin
        guard category != .admin else {
            return PushNotificationDisplayContent(
                title: notification.titleText
                    ?? localized(
                        "notification.generic.title"
                    ),
                body: notification.bodyText
                    ?? localized(
                        "notification.generic.body"
                    )
            )
        }

        guard
            let argumentCount = transactionArgumentCount(
                category: category,
                bodyKey: notification.bodyKey
            ),
            let arguments = transactionArguments(
                from: notification.argumentsJSON,
                expectedCount: argumentCount
            )
        else {
            return PushNotificationDisplayContent(
                title: notification.titleText
                    ?? localized(
                        "notification.generic.title"
                    ),
                body: notification.bodyText
                    ?? localized(
                        "notification.generic.body"
                    )
            )
        }

        let titleKey = category == .received
            ? "notification.received.title"
            : "notification.sent.title"
        let symbol = notification.assetSymbol
            ?? legacyAssetSymbol(notification.titleText, titleKey: titleKey)
            ?? (argumentCount == 4 ? arguments[1] : nil)
        let body: String
        if argumentCount == 3, let symbol, arguments[1] != symbol,
           let amount = EnglishNumbers.notificationCurrency(arguments[0], currencyCode: arguments[1]) {
            body = formatted(localized("notification.\(category.rawValue).body.currency"),
                             arguments: [amount, arguments[2]])
        } else {
            body = formatted(localized(notification.bodyKey), arguments: arguments)
        }
        return PushNotificationDisplayContent(
            title: symbol.map { formatted(localized(titleKey + ".compact"), arguments: [$0]) }
                ?? localized("notification.generic.title"),
            body: body,
            assetSymbol: symbol
        )
    }

    // Older pushes stored only their rendered title; fiat body arguments contain
    // the currency code, not the asset ticker. Recover only an exact known title.
    private static func legacyAssetSymbol(_ title: String?, titleKey: String) -> String? {
        guard let title, title.utf8.count <= 500 else { return nil }
        for identifier in WalletAppLanguage.supportedIdentifiers {
            let template = WalletAppLanguage.localizedBundle(for: identifier)
                .localizedString(forKey: titleKey, value: nil, table: nil)
            let parts = template.components(separatedBy: "%@")
            guard parts.count == 2, title.hasPrefix(parts[0]), title.hasSuffix(parts[1]),
                  title.count > parts[0].count + parts[1].count else { continue }
            let symbol = String(title.dropFirst(parts[0].count).dropLast(parts[1].count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{2066}\u{2067}\u{2068}\u{2069}"))
            if !symbol.isEmpty, symbol.utf8.count <= maximumArgumentBytes { return symbol }
        }
        return nil
    }

    private static func transactionArgumentCount(
        category: PushNotificationCategory,
        bodyKey: String
    ) -> Int? {
        switch (category, bodyKey) {
        case (.received, "notification.received.body"),
             (.received, "notification.received.body.priced"),
             (.sent, "notification.sent.body"):
            4
        case (.received, "notification.received.body.unpriced"),
             (.sent, "notification.sent.body.v2"):
            3
        default:
            nil
        }
    }

    private static func transactionArguments(
        from data: Data?,
        expectedCount: Int
    ) -> [String]? {
        guard let data,
              data.count <= maximumArgumentsJSONBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let arguments = object as? [String],
              arguments.count == expectedCount,
              arguments.allSatisfy({
                  $0.utf8.count <= maximumArgumentBytes
              }) else {
            return nil
        }
        return arguments
    }

    private static func formatted(
        _ key: String,
        arguments: [String]
    ) -> String {
        String(
            format: key,
            locale: formatLocale,
            arguments: arguments.map { $0 as NSString }
        )
    }
}
