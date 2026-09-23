import Foundation
import SwiftUI
import UIKit

enum WalletSFSymbol {
    static let weight: Font.Weight = .regular
}

enum WalletTypography {
    // Match the native inline navigation title used by sheet NavigationStacks.
    static let sheetTitle: Font = .headline.weight(.semibold)
    static let contentTitleWeight: Font.Weight = .regular
    static let listRowTitle: Font = .body.weight(contentTitleWeight)
    static func title(_ style: Font.TextStyle) -> Font { .system(style, weight: .bold) }
}

enum WalletCurrencyPreference {
    static let defaultCode = "USD"
    static let defaultRateStorageValue = "1"

    static var selectedCode: String {
        let stored = WalletRuntimePreferences.shared.currencyCode
        let normalized = stored.uppercased()
        guard
            normalized.count == 3,
            normalized.allSatisfy({ $0.isASCII && $0.isLetter })
        else {
            return defaultCode
        }
        return normalized
    }

    static var selectedRatePerUSD: Decimal {
        guard selectedCode != defaultCode else { return 1 }
        let stored = WalletRuntimePreferences.shared
            .currencyRateStorageValue
        let rate = Decimal(
            string: stored,
            locale: Locale(identifier: "en_US_POSIX")
        ) ?? 1
        return rate > 0 ? rate : 1
    }

    static func rateStorageValue(for rate: Decimal) -> String {
        NSDecimalNumber(decimal: rate).stringValue
    }
}

struct WalletCurrencyContext: Equatable, Sendable {
    let code: String
    let ratePerUSD: Decimal

    static var selected: WalletCurrencyContext {
        WalletCurrencyContext(
            code: WalletCurrencyPreference.selectedCode,
            ratePerUSD: WalletCurrencyPreference.selectedRatePerUSD
        )
    }

    init(code: String, rateStorageValue: String) {
        let normalizedCode = code.uppercased()
        let storedRate = Decimal(
            string: rateStorageValue,
            locale: Locale(identifier: "en_US_POSIX")
        ) ?? 1
        self.code = normalizedCode.count == 3
            ? normalizedCode
            : WalletCurrencyPreference.defaultCode
        self.ratePerUSD = self.code == WalletCurrencyPreference.defaultCode
            ? 1
            : max(storedRate, 1e-12)
    }

    init(code: String, ratePerUSD: Decimal) {
        self.code = code
        self.ratePerUSD = ratePerUSD
    }
}

private struct WalletCurrencyContextKey: EnvironmentKey {
    static let defaultValue = WalletCurrencyContext.selected
}

extension EnvironmentValues {
    var walletCurrencyContext: WalletCurrencyContext {
        get { self[WalletCurrencyContextKey.self] }
        set { self[WalletCurrencyContextKey.self] = newValue }
    }
}

enum EnglishNumbers {
    private static let locale = Locale(identifier: "en_US_POSIX")
    private static let formatters = EnglishNumberFormatterCache(
        locale: locale
    )

    static func localized(
        _ key: String,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: WalletLocalization.string(key),
            locale: locale,
            arguments: arguments
        )
    }

    /// Format an already rounded notification amount without converting through
    /// floating point or changing the currency's supplied decimal precision.
    static func notificationCurrency(_ amount: String, currencyCode: String) -> String? {
        guard Locale.commonISOCurrencyCodes.contains(currencyCode), amount.utf8.count <= 160,
              amount.range(of: #"^(?:0|[1-9][0-9]*|[1-9][0-9]{0,2}(?:,[0-9]{3})+)(?:\.[0-9]+)?$"#,
                           options: .regularExpression) != nil else { return nil }
        let pattern = formatters.currency(NSDecimalNumber.zero, currencyCode: currencyCode)
        return compactCurrencySymbolSpacing(
            in: pattern.prefix + amount + pattern.suffix, currencySymbol: pattern.symbol
        )
    }

    /// Display small positive unit prices to eight places, truncating excess digits.
    static func unitPrice(_ usdValue: Decimal, using context: WalletCurrencyContext) -> String {
        let value = usdValue * context.ratePerUSD
        guard value > 0, value < Decimal(string: "0.01")! else {
            return currency(usdValue, using: context)
        }
        var source = value
        var truncated = Decimal()
        NSDecimalRound(&truncated, &source, 8, .down)
        let amount = decimal(
            truncated,
            minimumFractionDigits: 8,
            maximumFractionDigits: 8
        )
        return notificationCurrency(amount, currencyCode: context.code)
            ?? currency(usdValue, using: context)
    }

    static func sanitizedASCII(_ input: String, limit: Int) -> String {
        String(input.filter { $0 >= "0" && $0 <= "9" }.prefix(limit))
    }

    static func currency(
        _ value: Decimal,
        currencyCode: String? = nil,
        includesPositiveSign: Bool = false
    ) -> String {
        let resolvedCurrencyCode = currencyCode
            ?? WalletCurrencyPreference.selectedCode
        let resolvedValue = currencyCode == nil
            ? value * WalletCurrencyPreference.selectedRatePerUSD
            : value
        let number = NSDecimalNumber(decimal: resolvedValue)
        let result = formatters.currency(
            number,
            currencyCode: resolvedCurrencyCode
        )
        let formatted = result.value ?? number.stringValue
        let compactFormatted = compactCurrencySymbolSpacing(
            in: formatted,
            currencySymbol: result.symbol
        )

        guard includesPositiveSign, resolvedValue > 0 else {
            return compactFormatted
        }

        return "+" + compactFormatted
    }

    static func currency(
        _ usdValue: Decimal,
        using context: WalletCurrencyContext,
        includesPositiveSign: Bool = false
    ) -> String {
        currency(
            usdValue * context.ratePerUSD,
            currencyCode: context.code,
            includesPositiveSign: includesPositiveSign
        )
    }

    static func decimal(
        _ value: Decimal,
        minimumFractionDigits: Int = 0,
        maximumFractionDigits: Int = 8,
        includesPositiveSign: Bool = false
    ) -> String {
        let number = NSDecimalNumber(decimal: value)
        let formatted = formatters.decimal(
            number,
            minimumFractionDigits: minimumFractionDigits,
            maximumFractionDigits: maximumFractionDigits
        ) ?? number.stringValue

        guard includesPositiveSign, value > 0 else {
            return formatted
        }

        return "+" + formatted
    }

    static func percentage(
        _ value: Decimal,
        includesPositiveSign: Bool = false
    ) -> String {
        let percentageValue = NSDecimalNumber(decimal: value)
            .dividing(by: 100)
        let formatted = formatters.percentage(percentageValue)
            ?? NSDecimalNumber(decimal: value).stringValue + "%"

        guard includesPositiveSign, value > 0 else {
            return formatted
        }

        return "+" + formatted
    }

    static func walletTimestamp(
        _ date: Date,
        relativeTo now: Date = Date()
    ) -> String {
        let timeZone = TimeZone.current
        let time = formatters.time(date, timeZone: timeZone)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        if calendar.isDate(date, inSameDayAs: now) {
            return localized("wallet.activity.time.today", time)
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return localized("wallet.activity.time.yesterday", time)
        }

        return formatters.dateTime(date, timeZone: timeZone)
    }

    static func walletActivityDay(
        _ date: Date,
        relativeTo now: Date = Date()
    ) -> String {
        let timeZone = TimeZone.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        if calendar.isDate(date, inSameDayAs: now) {
            return WalletLocalization.string(
                "wallet.activity.day.today"
            )
        }

        if let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: now
        ),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return WalletLocalization.string(
                "wallet.activity.day.yesterday"
            )
        }

        return formatters.date(date, timeZone: timeZone)
    }

    static func transactionDateTime(_ date: Date) -> String {
        formatters.longDateTime(date, timeZone: .current)
    }

    static func dateTime(_ date: Date) -> String {
        formatters.dateTime(date, timeZone: .current)
    }

    static func integer(_ value: Int64) -> String {
        decimal(
            Decimal(value),
            minimumFractionDigits: 0,
            maximumFractionDigits: 0
        )
    }

    private static func compactCurrencySymbolSpacing(
        in formattedValue: String,
        currencySymbol: String?
    ) -> String {
        guard
            let currencySymbol,
            !currencySymbol.isEmpty,
            currencySymbol.unicodeScalars.contains(
                where: CharacterSet.symbols.contains
            )
        else {
            return formattedValue
        }

        return [" ", "\u{00A0}", "\u{202F}"].reduce(
            formattedValue
        ) { partialResult, separator in
            partialResult
                .replacingOccurrences(
                    of: currencySymbol + separator,
                    with: currencySymbol
                )
                .replacingOccurrences(
                    of: separator + currencySymbol,
                    with: currencySymbol
                )
        }
    }
}

private final class EnglishNumberFormatterCache: @unchecked Sendable {
    private struct DecimalKey: Hashable {
        let minimumFractionDigits: Int
        let maximumFractionDigits: Int
    }

    private let locale: Locale
    private let lock = NSLock()
    private var currencyFormatters: [String: NumberFormatter] = [:]
    private var decimalFormatters: [DecimalKey: NumberFormatter] = [:]
    private var percentageFormatter: NumberFormatter?
    private var timeFormatters: [String: DateFormatter] = [:]
    private var dateFormatters: [String: DateFormatter] = [:]
    private var dateTimeFormatters: [String: DateFormatter] = [:]
    private var longDateTimeFormatters: [String: DateFormatter] = [:]

    init(locale: Locale) {
        self.locale = locale
    }

    func currency(
        _ value: NSDecimalNumber,
        currencyCode: String
    ) -> (value: String?, symbol: String?, prefix: String, suffix: String) {
        withLock {
            let formatter = currencyFormatters[currencyCode] ?? {
                let formatter = NumberFormatter()
                formatter.locale = locale
                formatter.numberStyle = .currency
                formatter.currencyCode = currencyCode
                formatter.minimumFractionDigits = 2
                formatter.maximumFractionDigits = 2
                formatter.usesGroupingSeparator = true
                currencyFormatters[currencyCode] = formatter
                return formatter
            }()
            return (formatter.string(from: value), formatter.currencySymbol,
                    formatter.positivePrefix, formatter.positiveSuffix)
        }
    }

    func decimal(
        _ value: NSDecimalNumber,
        minimumFractionDigits: Int,
        maximumFractionDigits: Int
    ) -> String? {
        withLock {
            let key = DecimalKey(
                minimumFractionDigits: minimumFractionDigits,
                maximumFractionDigits: maximumFractionDigits
            )
            let formatter = decimalFormatters[key] ?? {
                let formatter = NumberFormatter()
                formatter.locale = locale
                formatter.numberStyle = .decimal
                formatter.minimumFractionDigits = minimumFractionDigits
                formatter.maximumFractionDigits = maximumFractionDigits
                formatter.usesGroupingSeparator = true
                decimalFormatters[key] = formatter
                return formatter
            }()
            return formatter.string(from: value)
        }
    }

    func percentage(_ value: NSDecimalNumber) -> String? {
        withLock {
            let formatter = percentageFormatter ?? {
                let formatter = NumberFormatter()
                formatter.locale = locale
                formatter.numberStyle = .percent
                formatter.minimumFractionDigits = 2
                formatter.maximumFractionDigits = 2
                percentageFormatter = formatter
                return formatter
            }()
            return formatter.string(from: value)
        }
    }

    func time(_ date: Date, timeZone: TimeZone) -> String {
        withLock {
            formatter(
                in: &timeFormatters,
                timeZone: timeZone,
                dateFormat: "h:mm a"
            ).string(from: date)
        }
    }

    func dateTime(_ date: Date, timeZone: TimeZone) -> String {
        withLock {
            formatter(
                in: &dateTimeFormatters,
                timeZone: timeZone,
                dateFormat: "yyyy-MM-dd HH:mm"
            ).string(from: date)
        }
    }

    func date(_ date: Date, timeZone: TimeZone) -> String {
        withLock {
            formatter(
                in: &dateFormatters,
                timeZone: timeZone,
                dateFormat: "yyyy-MM-dd"
            ).string(from: date)
        }
    }

    func longDateTime(_ date: Date, timeZone: TimeZone) -> String {
        withLock {
            let key = timeZone.identifier
            let formatter = longDateTimeFormatters[key] ?? {
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = timeZone
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                longDateTimeFormatters[key] = formatter
                return formatter
            }()
            return formatter.string(from: date)
        }
    }

    private func formatter(
        in cache: inout [String: DateFormatter],
        timeZone: TimeZone,
        dateFormat: String
    ) -> DateFormatter {
        let key = timeZone.identifier
        if let formatter = cache[key] {
            return formatter
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = dateFormat
        cache[key] = formatter
        return formatter
    }

    private func withLock<Result>(
        _ operation: () -> Result
    ) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

/// Charcoal surfaces keep a visible depth hierarchy without a pure-black canvas.
/// The system still owns sheet glass, navigation chrome, and accessibility effects.
/// Light appearance resolves to the original UIKit semantic colors.
enum WalletSurfacePalette {
    static let background = adaptive(.systemBackground, dark: 0x14171C, elevated: 0x1C2027,
                                     highContrast: 0x101318, elevatedHighContrast: 0x181C23)
    static let groupedBackground = adaptive(.systemGroupedBackground, dark: 0x14171C, elevated: 0x1C2027,
                                            highContrast: 0x101318, elevatedHighContrast: 0x181C23)
    static let surface = adaptive(.secondarySystemBackground, dark: 0x20252D, elevated: 0x292F39,
                                  highContrast: 0x252C36, elevatedHighContrast: 0x303946)
    static let groupedSurface = adaptive(.secondarySystemGroupedBackground, dark: 0x20252D, elevated: 0x292F39,
                                         highContrast: 0x252C36, elevatedHighContrast: 0x303946)
    // Link text is brighter on charcoal; filled buttons keep their system-blue fill.
    static let link = adaptive(UIColor(named: "AccentColor") ?? .systemBlue,
                               dark: 0x63ACFF, highContrast: 0x83BDFF)
    static let primaryLabel = adaptive(.label, dark: 0xF1F3F5, highContrast: 0xFFFFFF)
    static let secondaryLabel = adaptive(.secondaryLabel, dark: 0xAFB7C4, highContrast: 0xD0D7E1)
    static let tertiaryLabel = adaptive(.tertiaryLabel, dark: 0xA2ADBD, highContrast: 0xC4CEDC)
    static let separator = adaptive(.separator, dark: 0x3C4552, highContrast: 0x788596)
    static let disabledFill = adaptive(.systemGray4, dark: 0x343D49, highContrast: 0x424E5F)
    static let tertiaryFill = adaptive(.tertiarySystemFill, dark: 0x2B323D, elevated: 0x343D49)

    private static func adaptive(
        _ light: UIColor, dark: UInt32, elevated: UInt32? = nil,
        highContrast: UInt32? = nil, elevatedHighContrast: UInt32? = nil
    ) -> UIColor {
        UIColor { traits in
            guard traits.userInterfaceStyle == .dark else { return light.resolvedColor(with: traits) }
            let isElevated = traits.userInterfaceLevel == .elevated
            let value: UInt32
            if traits.accessibilityContrast == .high {
                value = isElevated ? (elevatedHighContrast ?? highContrast ?? elevated ?? dark)
                                   : (highContrast ?? dark)
            } else {
                value = isElevated ? (elevated ?? dark) : dark
            }
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}

enum WalletTheme {
    static let accent = Color(uiColor: WalletSurfacePalette.link)
    static let primaryAction = Color(uiColor: .systemBlue)
    static let ink = Color("BrandInk")
    static let onAccentLabel = Color("OnAccentLabel")
    // Concrete label colors stay neutral in native List buttons. Hierarchical
    // .primary/.secondary foreground styles would inherit the button's tint.
    static let primaryLabel = Color(uiColor: WalletSurfacePalette.primaryLabel)
    static let disabledControlLabel = Color(uiColor: WalletSurfacePalette.secondaryLabel)
    static let disabledControlFill = Color(uiColor: WalletSurfacePalette.disabledFill)
    static let mutedPrimaryFill = Color("MutedPrimaryFill")
    static let mutedSecondaryFill = Color("MutedSecondaryFill")
    static let walletSwitcherCapsuleFill = Color(
        "WalletSwitcherCapsuleFill"
    )
    static let textFieldSecretsSurface = Color("textfiend.color.secrets")
    static let qrCodeSurface = Color("QRCodeSurface")
    static let qrCodeInk = Color("QRCodeInk")
    static let background = Color(uiColor: WalletSurfacePalette.background)
    static let secondaryLabel = Color(uiColor: WalletSurfacePalette.secondaryLabel)
    static let tertiaryLabel = Color(uiColor: WalletSurfacePalette.tertiaryLabel)
    static let groupedBackground = Color(uiColor: WalletSurfacePalette.groupedBackground)
    static let secondarySurface = Color(uiColor: WalletSurfacePalette.surface)
    static let groupedSurface = Color(uiColor: WalletSurfacePalette.groupedSurface)
    static let keypadSurface = Color("KeypadSurface")
    static let tertiaryFill = Color(uiColor: WalletSurfacePalette.tertiaryFill)
    static let separator = Color(uiColor: WalletSurfacePalette.separator)
    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemOrange)
    static let danger = Color(uiColor: .systemRed)
    static let onDangerLabel = Color.white
    static let callSafetyBanner = Color(red: 0.72, green: 0.12, blue: 0.10)
    static let onDarkColorLabel = Color(uiColor: .white)
    static let onLightColorLabel = Color(uiColor: .black)
    static let gain = Color(uiColor: .systemGreen)
    static let loss = Color(uiColor: .systemRed)
    static let settingsIconBlue = Color(uiColor: .systemBlue)
    static let settingsIconGreen = Color(uiColor: .systemGreen)
    static let settingsIconIndigo = Color(uiColor: .systemIndigo)
    static let settingsIconOrange = Color(uiColor: .systemOrange)
    static let settingsIconPink = Color(uiColor: .systemPink)
    static let settingsIconRed = Color(uiColor: .systemRed)
    static let settingsIconGray = Color(uiColor: .systemGray)
    static let settingsIconForeground = Color.white

}

enum WalletAppearancePreference:
    String,
    CaseIterable,
    Identifiable,
    Sendable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .system:
            "settings.appearance.system"
        case .dark:
            "settings.appearance.dark"
        case .light:
            "settings.appearance.light"
        }
    }

    var footerKey: LocalizedStringKey {
        switch self {
        case .system:
            "settings.appearance.footer"
        case .dark:
            "settings.appearance.dark.footer"
        case .light:
            "settings.appearance.light.footer"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .dark:
            .dark
        case .light:
            .light
        }
    }
}

enum WalletAppLanguage {
    static let defaultIdentifier = "en"
    static let supportedIdentifiers = [
        "en", "zh-Hans", "hi", "es", "fr", "ar", "bn", "pt-BR", "pt-PT", "ru",
        "ur", "id", "ms", "de", "ja", "sw", "mr", "te", "tr", "ta", "zh-Hant",
        "vi", "ko", "fa", "ha", "th", "gu", "pa", "fil", "it", "pl", "uk",
        "ml", "kn", "or", "my", "nl", "ro", "am", "uz", "sd", "yo", "ne",
        "si", "km", "cs", "sk", "sl", "hr", "ka", "el", "sv", "hu", "he", "da", "fi", "nb"
    ]
    private static let localizedBundles: [String: Bundle] = {
        var bundles: [String: Bundle] = [:]

        for identifier in supportedIdentifiers {
            let language = normalized(identifier)
            let candidates = [
                language,
                language.replacingOccurrences(
                    of: "-",
                    with: "_"
                )
            ]
            for candidate in candidates {
                guard
                    let path = Bundle.main.path(
                        forResource: candidate,
                        ofType: "lproj"
                    ),
                    let bundle = Bundle(path: path)
                else {
                    continue
                }
                bundles[identifier] = bundle
                break
            }
        }
        return bundles
    }()

    static var selectedIdentifier: String {
        let stored = WalletRuntimePreferences.shared.languageIdentifier
        return supportedIdentifiers.contains(stored)
            ? stored
            : defaultIdentifier
    }

    static func locale(for identifier: String) -> Locale {
        // Keep the selected language and its native layout direction while
        // requiring Latin decimal digits in Foundation and native controls.
        Locale(identifier: normalized(identifier) + "@numbers=latn")
    }

    static func layoutDirection(for identifier: String) -> LayoutDirection {
        locale(for: identifier).language.characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
    }

    static func localizedBundle(for identifier: String) -> Bundle {
        let language = normalized(identifier)
        return localizedBundles[language]
            ?? localizedBundles[defaultIdentifier]
            ?? .main
    }

    static func nativeName(for identifier: String) -> String {
        locale(for: identifier).localizedString(forIdentifier: identifier)
            ?? identifier
    }

    private static func normalized(_ identifier: String) -> String {
        supportedIdentifiers.contains(identifier)
            ? identifier
            : defaultIdentifier
    }
}

enum WalletLocalization {
    static func string(_ key: String) -> String {
        let selectedValue = WalletAppLanguage.localizedBundle(
            for: WalletAppLanguage.selectedIdentifier
        ).localizedString(forKey: key, value: key, table: nil)
        guard selectedValue == key else { return selectedValue }

        return WalletAppLanguage.localizedBundle(
            for: WalletAppLanguage.defaultIdentifier
        ).localizedString(forKey: key, value: key, table: nil)
    }
}

extension View {
    func walletPrivacySensitive(
        _ containsSensitiveContent: Bool = true
    ) -> some View {
        modifier(
            WalletPrivacySensitiveModifier(
                containsSensitiveContent: containsSensitiveContent
            )
        )
    }
}

private struct WalletPrivacySensitiveModifier: ViewModifier {
    let containsSensitiveContent: Bool

    @Environment(\.walletPrivacyShieldEnabled)
    private var isPrivacyShieldEnabled

    func body(content: Content) -> some View {
        content.privacySensitive(
            isPrivacyShieldEnabled && containsSensitiveContent
        )
    }
}

struct WalletPrivacyReplacement<Content: View>: View {
    let isHidden: Bool
    let alignment: Alignment
    private let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        isHidden: Bool,
        alignment: Alignment = .center,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isHidden = isHidden
        self.alignment = alignment
        self.content = content
    }

    var body: some View {
        ZStack(alignment: alignment) {
            content()
                .redacted(reason: isHidden ? .placeholder : [])
                .walletPrivacySensitive()
                .accessibilityHidden(isHidden)
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.24),
            value: isHidden
        )
    }
}

private struct WalletNativeSheetSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

private struct WalletRootBackgroundKey: EnvironmentKey {
    static let defaultValue = WalletTheme.background
}

extension EnvironmentValues {
    var walletNativeSheetSurface: Bool {
        get { self[WalletNativeSheetSurfaceKey.self] }
        set { self[WalletNativeSheetSurfaceKey.self] = newValue }
    }

    var walletRootBackground: Color {
        get { self[WalletRootBackgroundKey.self] }
        set { self[WalletRootBackgroundKey.self] = newValue }
    }
}

/// Reapplies the app-selected locale at native presentation boundaries.
///
/// SwiftUI propagates environment values through ordinary navigation, while
/// an already-presented sheet or full-screen cover can retain the locale and
/// layout direction captured by its hosting controller. Reading the shared
/// settings store here keeps every presentation synchronized without
/// hard-coding a direction in any individual screen.
private struct WalletLocalePresentationModifier: ViewModifier {
    @Environment(WalletSettingsStore.self)
    private var applicationSettings

    func body(content: Content) -> some View {
        let identifier = applicationSettings.languageIdentifier

        content
            .environment(
                \.locale,
                WalletAppLanguage.locale(for: identifier)
            )
            .environment(
                \.layoutDirection,
                WalletAppLanguage.layoutDirection(for: identifier)
            )
            .multilineTextAlignment(WalletTextInputLayout.alignment)
    }
}

private struct WalletSheetBackgroundModifier: ViewModifier {
    var nativeGlass = true

    func body(content: Content) -> some View {
        surface(for: content
            .modifier(WalletLocalePresentationModifier())
            .environment(\.walletRootBackground, WalletTheme.groupedBackground))
    }

    @ViewBuilder
    private func surface<V: View>(for content: V) -> some View {
        if #available(iOS 26.0, *), nativeGlass {
            // Let iOS own the surface: Liquid Glass at partial height, adapting
            // to opaque at full height and to Reduce Transparency automatically.
            // Lists must not paint an opaque scroll background over the glass.
            content
                .environment(\.walletNativeSheetSurface, true)
                .scrollContentBackground(.hidden)
        } else {
            // Full-height flows need a grouped canvas behind their white cards.
            // Reset inherited sheet styling when presented from a glass sheet.
            content
                .environment(\.walletNativeSheetSurface, false)
                .scrollContentBackground(.hidden)
                .background(WalletTheme.groupedBackground)
                .presentationBackground(WalletTheme.groupedBackground)
        }
    }
}

/// Keeps grouped cards distinct from their canvas in both appearances. Native
/// row layout, selection, swipe actions, and reordering stay owned by List.
private struct WalletListAppearanceModifier: ViewModifier {
    @Environment(\.walletNativeSheetSurface) private var nativeSheet

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background {
                if !nativeSheet {
                    // Paint at the List itself: NavigationStack can otherwise
                    // cover a presentation-level background with plain white.
                    WalletTheme.groupedBackground.ignoresSafeArea()
                }
            }
    }
}

private struct WalletListRowSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        // Keep a concrete adaptive fill installed across appearance changes,
        // including when native List cells are off-screen or reused after a pop.
        // Explicit clear hero rows can still override this inherited surface.
        content
            .listRowBackground(WalletTheme.groupedSurface)
            .listRowSeparatorTint(WalletTheme.separator)
    }
}

extension View {
    func walletListAppearance() -> some View {
        modifier(WalletListAppearanceModifier())
    }

    func walletListRowSurface() -> some View {
        modifier(WalletListRowSurfaceModifier())
    }
}

extension View {
    /// Styling only: safe to reuse on a pushed screen or inside a sheet.
    /// A background must not install another presentation's call-warning banner.
    func walletSheetBackground(nativeGlass: Bool = true) -> some View {
        modifier(WalletSheetBackgroundModifier(nativeGlass: nativeGlass))
    }

    /// Apply once to the root of a sheet, outside its NavigationStack. Each new
    /// presentation owns its warning; destinations inside it only style their
    /// background. An inherited environment flag would incorrectly hide the
    /// warning in a second sheet presented above the first.
    func walletSheetPresentation(nativeGlass: Bool = true) -> some View {
        walletCallSafetyBanner()
            .walletSheetBackground(nativeGlass: nativeGlass)
    }

    func walletLocalePresentation() -> some View {
        modifier(WalletLocalePresentationModifier())
    }
}

struct WalletBackground: View {
    @Environment(\.walletRootBackground)
    private var background

    var body: some View {
        background
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

struct PrimaryWalletButton: View {
    let title: LocalizedStringKey
    var hapticPolicy: UniHapticControlPolicy = .automatic
    let action: () -> Void

    var body: some View {
        Button(action: UniHaptic.action(hapticPolicy.resolved(automatic: .commit), perform: action)) {
            WalletActionButtonLabel(title: title)
        }
        .walletPrimaryActionButtonStyle()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .walletFlexibleButtonSizing()
        .walletAutomaticActionMargins()
    }
}

struct SecondaryWalletButton: View {
    let title: LocalizedStringKey
    var hapticPolicy: UniHapticControlPolicy = .automatic
    let action: () -> Void

    var body: some View {
        Button(action: UniHaptic.action(hapticPolicy.resolved(automatic: .selection), perform: action)) {
            WalletActionButtonLabel(title: title)
        }
        .walletSecondaryActionButtonStyle()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .walletFlexibleButtonSizing()
        .walletAutomaticActionMargins()
    }
}

private struct WalletActionButtonLabel: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.headline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

enum MutedWalletActionProminence {
    case primary
    case secondary
}

struct MutedWalletActionButton: View {
    let title: LocalizedStringKey
    let prominence: MutedWalletActionProminence
    var systemImage: String? = nil
    var hapticPolicy: UniHapticControlPolicy = .automatic
    let action: () -> Void

    private var hapticEvent: UniHaptic? {
        hapticPolicy.resolved(
            automatic: prominence == .primary ? .commit : .selection
        )
    }

    var body: some View {
        styledActionButton
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .walletFlexibleButtonSizing()
            .walletAutomaticActionMargins()
    }

    @ViewBuilder
    private var styledActionButton: some View {
        switch prominence {
        case .primary:
            actionButton.walletPrimaryActionButtonStyle()
        case .secondary:
            actionButton.walletSecondaryActionButtonStyle()
        }
    }

    private var actionButton: some View {
        Button(action: UniHaptic.action(hapticEvent, perform: action)) {
            Group {
                if let systemImage {
                    Label {
                        Text(title)
                    } icon: {
                        Image(systemName: systemImage)
                            .fontWeight(WalletSFSymbol.weight)
                    }
                } else {
                    Text(title)
                }
            }
            .font(.headline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
        }
    }

}
