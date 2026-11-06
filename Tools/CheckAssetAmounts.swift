import Foundation
import AppKit
import CoreText

@main struct CheckAssetAmounts {
    // Mac-host check; no simulator or device:
    // swiftc -swift-version 6 -parse-as-library OathAtmosphere/Home/OathAssetAmountFormat.swift \
    //   Tools/CheckAssetAmounts.swift -o /tmp/oath-amounts && /tmp/oath-amounts Design/Localization/languages.json
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ reason: String) {
            precondition(condition(), reason)
            checks += 1
        }
        func decimal(_ value: String) -> Decimal { Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))! }
        func withoutIsolates(_ value: String) -> String {
            String(String.UnicodeScalarView(value.unicodeScalars.filter { !(0x2066...0x2069).contains($0.value) }))
        }
        let us = OathAssetAmountFormat(locale: Locale(identifier: "en_US"))
        check(us.native(0, ticker: "BTC") == "0 BTC", "Confirmed zero uses native units")
        check(us.native(nil, ticker: "BTC") == "0 BTC", "Missing native amounts display zero")
        check(us.native(.nan, ticker: "BTC") == "0 BTC", "Invalid native amounts display zero")
        check(us.native(decimal("0.00000001"), ticker: "BTC") == "0.00000001 BTC", "One satoshi survives formatting")
        check(withoutIsolates(us.native(decimal("0.000000000000000001"), ticker: "ETH")) == "< 0.00000001 ETH", "One wei survives formatting")
        check(withoutIsolates(us.native(decimal("0.000000000000000000000001"), ticker: "NEAR")) == "< 0.00000001 NEAR", "One yoctoNEAR survives formatting")
        check(us.native(decimal("123456789.123456789"), ticker: "SOL") == "123456789.12345678 SOL", "Decimal precision is not converted to floating point")
        check(us.nativeSummary(decimal("0.578460528618856998992951"), ticker: "NEAR") == "0.57846052 NEAR", "NEAR's 24 decimals must not expand a list row")
        check(us.nativeSummary(decimal("0.00047087"), ticker: "BTC") == "0.00047087 BTC", "List presentation retains satoshi precision")
        check(us.nativeSummary(decimal("110.1499085"), ticker: "DOGE") == "110.1499085 DOGE", "Native balance belongs beneath the asset name")
        check(withoutIsolates(us.nativeSummary(decimal("0.000000000000000001"), ticker: "ETH")) == "< 0.00000001 ETH", "Small positive balances never become zero")
        check(withoutIsolates(us.nativeSummary(decimal("-0.000000000000000001"), ticker: "ETH")) == "> -0.00000001 ETH", "Small negative quantities preserve their sign")
        check(us.nativeSummary(decimal("0.999999999999"), ticker: "NEAR") == "0.99999999 NEAR", "List rounding must not overstate a balance")
        check(us.nativeSummary(nil, ticker: "NEAR") == "0 NEAR", "Unknown native values follow the app's zero display policy")
        check(String(us.fiat(.unavailable).characters) == "$0.00", "Missing fiat quotes display a formatted zero")
        check(String(us.fiat(.init(native: 1, fiat: 12, currencyCode: "EUR")).characters) == "$0.00", "A stale currency quote displays zero instead of relabeling the old amount")
        check(String(us.fiat(.init(native: 0, fiat: 0, currencyCode: "USD")).characters) == "$0.00", "Confirmed fiat zero stays formatted")
        check(String(us.fiat(.init(native: 1, fiat: decimal("12.34"), currencyCode: "USD")).characters) == "$12.34", "Available fiat balances retain their actual value")
        check(String(us.fiat(.init(native: nil, fiat: .nan, currencyCode: "USD")).characters) == "$0.00", "Invalid fiat amounts display a formatted zero")
        check(OathAssetAmounts.unavailable.native == nil && OathAssetAmounts.unavailable.fiat == nil,
              "Display defaults do not turn missing balances into fetched values")

        for (identifier, code) in [("en_US", "USD"), ("de_DE", "EUR"),
                                   ("ar_SA", "SAR"), ("ja_JP", "JPY"),
                                   ("ar_KW", "KWD"), ("en_IL", "ILS"),
                                   ("en_JO", "JOD"), ("ar_JO", "JOD")] {
            let format = OathAssetAmountFormat(locale: Locale(identifier: identifier))
            check(format.currencyCode == code, "Currency comes from the device region")
            let value = format.fiat(.init(native: 1, fiat: decimal("1234.56"), currencyCode: code))
            let symbols = value.runs.filter { $0.numberSymbol == .currency }
            check(symbols.count == 1, "One localized currency label receives currency styling")
            let fractions = value.runs.filter { $0.numberPart == .fraction }
            let count = fractions.reduce(0) { $0 + value[$1.range].characters.count }
            let minorUnits = 2
            check(count == minorUnits, "Every display currency uses two fractional digits")
            check(value.runs.contains { $0.numberPart == .integer }, "Integer digits keep the primary color")
            let zero = format.fiat(.init(native: 0, fiat: 0, currencyCode: code))
            check(zero.runs.filter { $0.numberPart == .fraction }
                .reduce(0) { $0 + zero[$1.range].characters.count } == minorUnits,
                  "Confirmed zero uses the currency's correct precision")
            for amounts in [OathAssetAmounts.unavailable,
                            .init(native: nil, fiat: nil, currencyCode: code),
                            .init(native: nil, fiat: .nan, currencyCode: code),
                            .init(native: nil, fiat: 12, currencyCode: "NOT-THIS-CURRENCY")] {
                let fallback = format.fiat(amounts)
                check(fallback == zero, "Every missing/invalid quote uses the confirmed zero's localized value and semantic styling")
                check(!String(fallback.characters).contains("—"), "Balance displays never use a dash placeholder")
            }
        }
        let selected = OathAssetAmountFormat(locale: Locale(identifier: "en_US"), selectedCurrencyCode: "JOD")
        check(selected.currencyCode == "JOD", "Explicit currency overrides the device region")
        check(String(selected.fiat(.init(native: 1, fiat: decimal("18.168125"), currencyCode: "JOD")).characters).contains("18.17"),
              "Rounding happens only at presentation, after exact USD conversion")
        // Selected-currency and missing-rate cases use this same formatter in
        // the large total, the scrolling toolbar, and every asset row.
        for identifier in ["en_US", "ar_JO"] {
            for code in ["USD", "JOD", "ARS", "JPY"] {
                let format = OathAssetAmountFormat(locale: Locale(identifier: identifier), selectedCurrencyCode: code)
                let zero = format.fiat(.init(native: 0, fiat: 0, currencyCode: code))
                for amounts in [OathAssetAmounts.unavailable,
                                .init(native: 10, fiat: nil, currencyCode: code),
                                .init(native: 10, fiat: .nan, currencyCode: code),
                                .init(native: 10, fiat: 123, currencyCode: "STALE-CURRENCY")] {
                    check(format.fiat(amounts) == zero, "Selected currency always formats unavailable balances as zero, including while exchange rates load")
                }
            }
        }

        let feeFormat = OathAssetAmountFormat(locale: Locale(identifier: "en_US"), selectedCurrencyCode: "USD")
        check(feeFormat.fee(nil) == nil && feeFormat.fee(.nan) == nil, "Missing fee pricing stays unknown")
        check(feeFormat.fee(0) == "$0.00", "A real zero fee is displayed")
        check(feeFormat.fee(decimal("0.000031")).map(withoutIsolates) == "< $0.01", "A paid sub-cent fee is not rounded to zero")
        check(feeFormat.fee(decimal("0.0000000001")).map(withoutIsolates) == "< $0.01", "Tiny paid fees retain a nonzero upper bound")
        for code in ["JPY", "JOD", "USD"] {
            let formatter = OathAssetAmountFormat(locale: Locale(identifier: "en_US"), selectedCurrencyCode: code)
            let fee = decimal("12.3456")
            check(formatter.fee(fee) == fee.formatted(.currency(code: code).precision(.fractionLength(2)).locale(Locale(identifier: "en_US"))), "Fees use two display decimals")
        }

        for input in ["0.000000001", "0.009", "0.00999999"] {
            check(withoutIsolates(us.money(decimal(input))) == "< $0.01", "Nonzero sub-cent amounts use a cent bound")
            check(withoutIsolates(us.money(-decimal(input))) == "> -$0.01", "Negative sub-cent amount remains negative")
        }
        check(us.money(decimal("0.01")) == "$0.01", "One cent is exact")
        check(us.money(decimal("123.456789")) == "$123.46", "Local amounts never exceed two decimals")
        check(withoutIsolates(us.money(decimal("0.001"), signed: true)) == "< +$0.01", "Incoming dust retains direction")
        for (input, expected) in [("98.864689267516090857", "98.86468926"),
            ("123456789123456789123456789123456789.123456789", "123456789123456789123456789123456789.12345678"),
            ("0.000000000001", "< 0.00000001"), ("-0.000000000001", "> -0.00000001"),
            ("100.000000000", "100"), ("1.23456789", "1.23456789")] {
            check(withoutIsolates(OathAssetAmountFormat.boundedUnits(input)) == expected, "Exact string display cap: \(input)")
        }

        // The reported double label: a localized US$ must never gain a USD prefix.
        for identifier in ["ar_JO", "ar_JO@numbers=latn", "en_IL", "he_IL", "fr_FR"] {
            let formatter = OathAssetAmountFormat(locale: Locale(identifier: identifier), selectedCurrencyCode: "USD")
            let value = formatter.fiat(.unavailable)
            check(!String(value.characters).contains("USD"), "USD must not be added beside the locale's currency symbol")
            let labels = value.runs.filter { $0.numberSymbol == .currency }.map { String(value[$0.range].characters) }
            check(labels.count == 1, "USD has exactly one currency label in \(identifier)")
            if identifier.hasPrefix("ar_JO") || identifier == "en_IL" {
                check(labels == ["US$"], "Preserve the disambiguated US$ symbol")
            }
        }

        // Use the app's reviewed registry so newly supported languages join the
        // regression automatically. Cover both app locales and regional formats.
        struct Language: Decodable { let locale: String; let region: String }
        let registry = CommandLine.arguments.dropFirst().first ?? "Design/Localization/languages.json"
        let languages = try JSONDecoder().decode([Language].self, from: Data(contentsOf: URL(fileURLWithPath: registry)))
        check(!languages.isEmpty, "Supported language coverage must not be empty")
        var shapingChecks = 0
        // Check the actual glyph selected by the platform's bidi shaper. Merely
        // checking String.contains("<") cannot detect a visually reversed sign.
        for language in languages {
            for code in ["USD", "EUR", "SAR", "ILS", "JOD", "JPY"] {
                let locale = Locale(identifier: language.locale)
                let formatter = OathAssetAmountFormat(locale: locale, selectedCurrencyCode: code)
                for negative in [false, true] {
                    for signed in [false, true] {
                        let amount = decimal(negative ? "-0.001" : "0.001")
                        let symbol = negative ? ">" : "<"
                        let value = formatter.fiatValue(amount, signed: signed)
                        let text = String(value.characters)
                        let bound = decimal(negative ? "-0.01" : "0.01")
                        let style = Decimal.FormatStyle.Currency(code: code).locale(locale).precision(.fractionLength(2))
                        let operand = signed ? bound.formatted(style.sign(strategy: .always(showZero: false)).attributed) : bound.formatted(style.attributed)
                        check(withoutIsolates(text) == symbol + " " + String(operand.characters), "Bounded value preserves localized currency and sign")
                        let operandRange = value.range(of: String(operand.characters))!
                        check(AttributedString(value[operandRange]) == operand, "Directional isolation preserves all operand attributes")
                        check(formatter.money(amount, signed: signed) == text, "String callers preserve display direction")
                        for direction: NSWritingDirection in [.leftToRight, .rightToLeft] {
                            check(shapesComparison(text, as: symbol, direction: direction), "Incorrect shaped comparison: \(locale.identifier)/\(code)/\(negative)/\(signed)/\(direction.rawValue)")
                            shapingChecks += 1
                        }
                    }
                }
            }
        }
        // Negative controls establish that this check detects the original bug.
        check(!shapesComparison("< $0.01", as: "<", direction: .rightToLeft), "Unisolated less-than sign must expose RTL mirroring")
        check(!shapesComparison("> -$0.01", as: ">", direction: .rightToLeft), "Unisolated greater-than sign must expose RTL mirroring")
        for language in languages {
            var regional = Locale.Components(identifier: language.locale)
            regional.region = Locale.Region(language.region)
            for locale in [Locale(identifier: language.locale), Locale(components: regional)] {
                for code in Locale.commonISOCurrencyCodes {
                    let formatter = OathAssetAmountFormat(locale: locale, selectedCurrencyCode: code)
                    for amount in [Decimal.zero, decimal("1234.56"), decimal("-1234.56")] {
                        let value = formatter.fiat(.init(native: nil, fiat: amount, currencyCode: code))
                        let native = amount.formatted(.currency(code: code).precision(.fractionLength(2)).locale(locale).attributed)
                        check(value == native, "Preserve native currency placement, digits, precision and bidi marks: \(locale.identifier)/\(code)")
                        check(value.runs.filter { $0.numberSymbol == .currency }.count == 1,
                              "No duplicate currency labels: \(locale.identifier)/\(code)")
                        check(value.runs.contains { $0.numberPart == .integer }, "Digits retain their semantic styling")
                    }
                }
            }
        }
        print("Passed \(checks) asset amount, currency-region, precision, and semantic styling checks across \(languages.count) supported languages; \(shapingChecks) CoreText directional glyph checks.")
    }

    private static func shapesComparison(_ text: String, as symbol: String, direction: NSWritingDirection) -> Bool {
        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = direction
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 32), .paragraphStyle: paragraph
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let offset = (text as NSString).range(of: symbol).location
        guard offset != NSNotFound else { return false }
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var indices = [CFIndex](repeating: 0, count: count)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            if let index = indices.firstIndex(of: offset) {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let font = attributes[kCTFontAttributeName] else { return false }
                var character = symbol.utf16.first!
                var expected: CGGlyph = 0
                return CTFontGetGlyphsForCharacters(font as! CTFont, &character, &expected, 1)
                    && glyphs[index] == expected
            }
        }
        return false
    }
}
