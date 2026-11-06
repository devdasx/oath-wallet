import Foundation
import CoreText

/// Host-only shaping regression. A string can contain '<' while the bidi
/// engine actually draws '>'; inspect the laid-out glyph, not just the text.
/// Compile with OathAssetAmountFormat.swift and OathSendAmount.swift.
@main struct CheckAssetAmountDirection {
    static func main() {
        var checks = 0
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition {
                failures += 1
                if failures <= 8 { print("FAIL: \(message)") }
            }
        }
        let small = Decimal(string: "0.001")!
        let cent = Decimal(string: "0.01")!
        for identifier in ["en_US", "ar_JO@numbers=latn", "ar_SA", "he_IL", "fa_IR", "ur_PK", "ps_AF"] {
            let locale = Locale(identifier: identifier)
            let nativeFormatter = OathAssetAmountFormat(locale: locale)
            for negative in [false, true] {
                let tiny = Decimal(string: "0.000000000001")! * (negative ? -1 : 1)
                let native = nativeFormatter.nativeSummary(tiny, ticker: "ETH")
                let canonical = OathAssetAmountFormat.boundedUnits(negative ? "-0.000000000001" : "0.000000000001")
                let signed = OathAssetAmountFormat.boundedUnits("0.000000000001", sign: negative ? "−" : "+")
                for direction in [CTWritingDirection.leftToRight, .rightToLeft] {
                    for text in [native, canonical + " ETH", signed + " ETH"] {
                        for context in [text, "Balance: \(text) today", "الرصيد: \(text) اليوم", "\u{2066}\(text)\u{2069}"] {
                            check(drawsUnmirroredOperator(context, symbol: negative ? ">" : "<", direction: direction),
                                  "Native bound keeps its meaning: \(identifier), negative=\(negative), paragraph=\(direction.rawValue)")
                        }
                    }
                }
            }
            for currency in ["USD", "EUR", "ILS", "SAR", "JOD", "KWD", "JPY"] {
                let sendFormat = OathSendAmountFormat(locale: locale, currency: currency)
                let sendBound = sendFormat.amount("", fiat: true, symbol: "ETH", decimals: 18, belowFiatMinimum: true)
                let parts = sendFormat.amountParts("", fiat: true, symbol: "ETH", decimals: 18, belowFiatMinimum: true)
                check(parts.prefix + parts.number + parts.suffix == sendBound, "Styled send amount preserves the same isolation")
                check(OathSendAmount.normalized(sendBound, locale: locale) == nil, "Presentation controls never become send input")
                for direction in [CTWritingDirection.leftToRight, .rightToLeft] {
                    check(drawsUnmirroredOperator(sendBound, symbol: "<", direction: direction),
                          "Send maximum below a cent keeps '<': \(identifier)/\(currency)")
                }
                let formatter = OathAssetAmountFormat(locale: locale, selectedCurrencyCode: currency)
                for value in [small, -small] {
                    let symbol = value > 0 ? "<" : ">"
                    let bound = value > 0 ? cent : -cent
                    for signed in [false, true] {
                        let formatted = formatter.fiatValue(value, signed: signed)
                        let text = String(formatted.characters)
                        let style = Decimal.FormatStyle.Currency(code: currency).locale(locale)
                            .precision(.fractionLength(2))
                        let native = signed
                            ? bound.formatted(style.sign(strategy: .always(showZero: false)).attributed)
                            : bound.formatted(style.attributed)
                        if let range = formatted.range(of: String(native.characters)) {
                            check(AttributedString(formatted[range]) == native,
                                  "Currency digits, signs, placement marks and attributes remain native: \(identifier)/\(currency)")
                        } else {
                            check(false, "Missing localized bound: \(identifier)/\(currency)")
                        }
                        for direction in [CTWritingDirection.leftToRight, .rightToLeft] {
                            for context in [text, "Balance: \(text) today", "الرصيد: \(text) اليوم", "\u{2066}\(text)\u{2069}"] {
                                check(drawsUnmirroredOperator(context, symbol: symbol, direction: direction),
                                      "\(symbol) glyph keeps its mathematical meaning: \(identifier)/\(currency), signed=\(signed), paragraph=\(direction.rawValue)")
                            }
                        }
                        check(formatter.money(value, signed: signed) == text, "Plain-string consumers retain direction isolation")
                        if value > 0 && !signed {
                            check(formatter.fee(value) == text, "Small fees share the same bounded-amount policy")
                        }
                    }
                }
            }
        }
        print("\(checks - failures)/\(checks) amount-direction, glyph and currency-preservation checks passed on the host.")
        if failures > 0 { exit(1) }
    }

    private static func drawsUnmirroredOperator(_ text: String, symbol: String,
                                               direction: CTWritingDirection) -> Bool {
        let index = (text as NSString).range(of: symbol).location
        guard index != NSNotFound,
              let font = CTFontCreateUIFontForLanguage(.system, 17, nil) else { return false }
        var direction = direction
        let paragraph = withUnsafePointer(to: &direction) { pointer in
            var setting = CTParagraphStyleSetting(spec: .baseWritingDirection,
                valueSize: MemoryLayout<CTWritingDirection>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var indices = [CFIndex](repeating: 0, count: count)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            guard let position = indices.firstIndex(of: index) else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            var character = symbol.utf16.first!
            var expected: CGGlyph = 0
            return CTFontGetGlyphsForCharacters(runFont, &character, &expected, 1)
                && expected != 0 && glyphs[position] == expected
        }
        return false
    }
}
