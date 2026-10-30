import Foundation

@main struct CheckSendAmount {
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); count += 1
        }
        func rejects(_ input: String, decimals: Int, _ expected: OathSendAmount.Failure) {
            do { _ = try OathSendAmount.atomic(input, decimals: decimals, locale: Locale(identifier: "en_US")); preconditionFailure("Accepted invalid amount: \(input.debugDescription)") }
            catch { check(error as? OathSendAmount.Failure == expected, "Wrong rejection: \(input)") }
        }
        let en = Locale(identifier: "en_US")
        let vectors: [(String, Int, String)] = [
            ("0.00000001", 8, "1"), (".000000000000000001", 18, "1"),
            ("0.000000000000000000000001", 24, "1"), ("1.000001", 6, "1000001"),
            ("0001.2300", 2, "123"), ("001", 0, "1"),
            ("123456789123456789123456789123456789.000000000000000001", 18,
             "123456789123456789123456789123456789000000000000000001")
        ]
        for (input, decimals, expected) in vectors {
            let raw = try OathSendAmount.atomic(input, decimals: decimals, locale: en)
            check(raw == expected, "Exact atomic conversion")
            let units = OathSendAmount.units(raw, decimals: decimals)!
            let roundTrip = try OathSendAmount.atomic(units, decimals: decimals, locale: en)
            check(roundTrip == expected, "Full precision round trip")
        }
        let arabic = try OathSendAmount.atomic("١٢٫٣٤٥", decimals: 6, locale: Locale(identifier: "ar"))
        let persian = try OathSendAmount.atomic("۱۲٫۳۴۵", decimals: 6, locale: Locale(identifier: "fa"))
        let german = try OathSendAmount.atomic("12,345", decimals: 6, locale: Locale(identifier: "de_DE"))
        check(arabic == "12345000" && persian == arabic && german == arabic, "Localized input")
        for input in ["", ".", "-1", "+1", "1e3", "NaN", "1,000", "1 000", "1..0", "1%", "²", "1\u{200B}"] { rejects(input, decimals: 6, .invalid) }
        rejects("0", decimals: 18, .zero)
        rejects("0.000000001", decimals: 8, .precision)
        rejects("1.1", decimals: 0, .precision)
        rejects("1", decimals: -1, .invalid)
        rejects(String(repeating: "9", count: 194), decimals: 0, .invalid)
        check(OathSendAmount.validate("1", balance: nil) == .balanceUnknown, "Unknown isn't zero")
        check(OathSendAmount.validate("1", balance: "invalid") == .balanceUnknown, "Invalid isn't zero")
        check(OathSendAmount.validate("1", balance: "0") == .insufficient, "Real zero")
        check(OathSendAmount.validate("100", balance: "99") == .insufficient, "Digit lengths")
        check(OathSendAmount.validate("999", balance: "1000") == nil, "Lexical comparison only at same length")
        check(OathSendAmount.validate("123456789123456789123456789123456788", balance: "123456789123456789123456789123456787") == .insufficient, "No Double precision loss")
        check(OathSendAmount.validate("10", balance: "00010") == nil, "Equality and normalization")
        let fiat = try OathSendAmount.fromFiat("1", price: 3, decimals: 6, locale: en)
        check(fiat == "333333", "Fiat conversion rounds down to an atomic unit")
        let issuedFiat = try OathSendAmount.fromFiat("2.50", price: 2, decimals: 96, locale: en)
        check(issuedFiat == "125"+String(repeating:"0",count:94), "Issued-token internal scale supports priced fiat entry")
        check(OathSendUnitPreference.allowsFiat(price:2,decimals:96), "Issued scale does not hide a valid price")
        check(OathSendAmount.displayUnits("2.50",fiat:true,price:2,decimals:96,locale:en) == "1.25", "Issued conversion display uses actual units")
        let oneSatoshi = try OathSendAmount.fromFiat("0.001", price: 100000, decimals: 8, locale: en)
        check(oneSatoshi == "1", "Fiat value of one satoshi")
        // Max starts in native units; an explicit unit switch may change its
        // label. Fiat rounding in either direction must not change the send.
        let maximumVectors: [(String, String, String, String)] = [
            ("44837", "100000", "44.83", "0.00044837"), // BTC: fiat capped at cents
            ("3408914", "250", "8.52", "0.03408914"), // BCH: fiat capped at cents
            ("7610462", "60", "4.56", "0.07610462"), // LTC
            ("10992052524", "0.1", "10.99", "109.92052524") // DOGE
        ]
        for (balance, price, fiat, native) in maximumVectors {
            let maximum = OathSendMaximumAmount(balance: balance, decimals: 8)!
            let quote = Decimal(string: price, locale: en)!
            check(maximum.input(fiat: true, price: quote, currency: "USD") == fiat, "Max displays the local currency value")
            check(maximum.input(fiat: false, price: quote, currency: "USD") == native, "Switching Max to native retains every atomic digit")
            check(maximum.input(fiat: true, price: quote, currency: "USD") == fiat && maximum.atomic == balance, "Switching back to fiat never round-trips the send amount")
            check(OathSendAmount.validate(maximum.atomic, balance: balance) == nil, "Fiat Max cannot overspend due to rounded-up display")
            let delete = maximum.edited(by: .delete, preferredFiat: true, price: quote, currency: "USD", decimals: 8, locale: en)!
            check(delete.fiat && delete.amount == String(fiat.dropLast()), "First delete restores fiat and edits the converted value on every Bitcoin-family chain")
            check(delete.amount != String(native.dropLast()), "Native digits must never simply be relabeled as fiat")
            let editedAtomic = try OathSendAmount.fromFiat(delete.amount, price: quote, decimals: 8, locale: en)
            check(editedAtomic != maximum.atomic && OathSendAmount.validate(editedAtomic, balance: balance) == nil, "Deleting Max creates a smaller manual amount")
            let nativeDelete = maximum.edited(by: .delete, preferredFiat: false, price: quote, currency: "USD", decimals: 8, locale: en)!
            check(!nativeDelete.fiat && nativeDelete.amount == String(native.dropLast()), "Native preference remains native after deleting Max")
            for preferredFiat in [false, true] {
                let clear = maximum.edited(by: .clear, preferredFiat: preferredFiat, price: quote, currency: "USD", decimals: 8, locale: en)!
                check(clear.fiat == preferredFiat && clear.amount.isEmpty, "Long-press clear restores the preference and removes the full amount")
            }
            check(maximum.edited(by: .digit(7), preferredFiat: true, price: quote, currency: "USD", decimals: 8, locale: en) == nil, "A third fiat decimal is a no-op and keeps the exact Max override")
            check(maximum.edited(by: .decimal, preferredFiat: true, price: quote, currency: "USD", decimals: 8, locale: en) == nil, "No-op decimal keeps Max selected")
            check(maximum.edited(by: .digit(10), preferredFiat: true, price: quote, currency: "USD", decimals: 8, locale: en) == nil, "Invalid keypad input keeps Max selected")
        }
        let maximum = OathSendMaximumAmount(balance: "00044837", decimals: 8)!
        check(maximum.atomic == "44837", "Max normalizes atomic leading zeroes")
        check(maximum.input(fiat: true, price: 110000, currency: "USD") == "49.32" && maximum.atomic == "44837", "Price changes update only the Max display")
        check(OathSendAmount.validate(maximum.atomic, balance: "44836") == .insufficient, "A balance decrease invalidates the selected Max")
        check(OathSendAmount.validate(maximum.atomic, balance: "50000") == nil && maximum.atomic == "44837", "New deposits cannot silently increase selected Max")
        check(maximum.input(fiat: true, price: 100000, currency: "JPY") == "44.83", "JPY also uses at most two editable decimals")
        check(maximum.input(fiat: true, price: 100000, currency: "KWD") == "44.83", "KWD also caps fiat at two decimals")
        for price: Decimal? in [nil, 0, -1, .nan] {
            check(maximum.input(fiat: true, price: price, currency: "USD") == nil, "Unavailable prices cannot manufacture fiat Max")
            check(maximum.input(fiat: false, price: price, currency: "USD") == "0.00044837", "Native Max needs no price")
            let deleted = maximum.edited(by: .delete, preferredFiat: true, price: price, currency: "USD", decimals: 8, locale: en)!
            check(!deleted.fiat && deleted.amount == "0.0004483", "Missing price prevents fiat restoration without blocking deletion")
            let cleared = maximum.edited(by: .clear, preferredFiat: true, price: price, currency: "USD", decimals: 8, locale: en)!
            check(!cleared.fiat && cleared.amount.isEmpty, "Clearing Max works without a price")
        }
        for locale in [en, Locale(identifier: "ar"), Locale(identifier: "de_DE")] {
            let deleted = maximum.edited(by: .delete, preferredFiat: true, price: 100000, currency: "USD", decimals: 8, locale: locale)!
            check(deleted.fiat && deleted.amount == "44.8", "Restored input remains canonical across locales")
        }
        let yenEdit = maximum.edited(by: .delete, preferredFiat: true, price: 100000, currency: "JPY", decimals: 8, locale: en)!
        check(yenEdit.fiat && yenEdit.amount == "44.8", "Restoration edits the two-decimal fiat input")
        let dinarEdit = maximum.edited(by: .delete, preferredFiat: true, price: 100000, currency: "KWD", decimals: 8, locale: en)!
        check(dinarEdit.fiat && dinarEdit.amount == "44.8", "Restoration caps three-decimal currencies at two")
        let tinyMaximum = OathSendMaximumAmount(balance: "1", decimals: 8)!
        check(tinyMaximum.input(fiat: true, price: 100000, currency: "USD") == "0" && tinyMaximum.atomic == "1", "Sub-cent Max keeps its exact atomic quantity separate from its edit label")
        let zeroMaximum = OathSendMaximumAmount(balance: "0", decimals: 8)!
        check(zeroMaximum.input(fiat: true, price: 100000, currency: "USD") == "0" && zeroMaximum.atomic == "0", "Real zero balance remains zero")
        for balance: String? in [nil, "", "-1", "1.5", "invalid"] {
            check(OathSendMaximumAmount(balance: balance, decimals: 8) == nil, "Unknown or malformed Max is not zero")
        }
        for decimals in [0, 6, 8, 18, 24, 38, 255] {
            let maximum = OathSendMaximumAmount(balance: "123456789123456789123456789123456789123456789", decimals: decimals)!
            check(try! OathSendAmount.atomic(maximum.input(fiat: false, price: nil, currency: "USD")!, decimals: decimals, locale: en) == maximum.atomic, "Native Max retains balances beyond Decimal precision")
        }
        // Regression: the price exists even before the first digit is typed.
        for input in ["", "0", "0.", "0.000"] {
            for fiat in [false, true] {
                check(OathSendAmount.displayUnits(input, fiat: fiat, price: 100000, decimals: 8, locale: en) == "0", "Empty/zero display must not report a missing price")
            }
        }
        check(OathSendAmount.displayUnits("1", fiat: true, price: 100000, decimals: 8, locale: en) == "0.00001", "Fiat display uses portfolio unit price")
        check(OathSendAmount.displayUnits("0.0001", fiat: true, price: 100000, decimals: 8, locale: en) == "0", "Sub-satoshi equivalent is zero, never a missing price")
        check(OathSendAmount.displayUnits("1", fiat: true, price: nil, decimals: 8, locale: en) == nil, "A genuinely missing price stays unavailable")
        check(OathSendAmount.displayUnits("1", fiat: true, price: 0, decimals: 8, locale: en) == nil, "Zero price cannot convert")
        check(OathSendAmount.displayUnits("invalid", fiat: false, price: 1, decimals: 8, locale: en) == nil, "Invalid text cannot become a display value")

        func edit(_ value: String, _ key: OathSendKeypadInput.Key, fiat: Bool = false, decimals: Int = 8, locale: Locale = Locale(identifier: "en_US")) -> String {
            OathSendKeypadInput.applying(key, to: value, fiat: fiat, decimals: decimals, locale: locale)
        }
        var entry = ""
        for key: OathSendKeypadInput.Key in [.decimal, .digit(0), .digit(0), .digit(1), .digit(0)] { entry = edit(entry, key) }
        check(entry == "0.0010", "Keypad retains decimal and trailing zeroes")
        check(edit(entry, .decimal) == entry, "One decimal separator only")
        check(edit(entry, .delete) == "0.001", "Delete removes exactly one digit")
        check(edit("0.", .delete) == "0" && edit("0", .delete) == "", "Delete returns to placeholder")
        check(edit("", .delete) == "", "Empty delete is safe")
        for input in ["12345.67", "0.00044837", "٠٫١٢٣", String(repeating: "9", count: 450), ""] {
            for fiat in [false, true] {
                check(edit(input, .clear, fiat: fiat) == "", "Long-press clear removes the whole amount in either entry mode")
                check(edit(edit(input, .clear, fiat: fiat), .delete, fiat: fiat) == "", "Releasing backspace after clear leaves the amount empty")
            }
        }
        check(edit("0", .digit(2)) == "2" && edit("0", .digit(0)) == "0", "No redundant leading zeroes")
        check(edit("1.12345678", .digit(9)) == "1.12345678", "Native precision limit")
        check(edit("1.12", .digit(9), fiat: true) == "1.12", "Fiat rejects a third decimal")
        check(edit("1", .decimal, decimals: 0) == "1", "Integer asset cannot enter fractions")
        check(edit("1", .decimal, fiat: true, decimals: 0) == "1.", "Integer asset can still have a fiat price")
        check(edit("١٢٫٣", .digit(4), locale: Locale(identifier: "ar")) == "12.34", "Arabic keypad input remains canonical")
        check(edit("12,3", .digit(4), locale: Locale(identifier: "de_DE")) == "12.34", "Comma input remains canonical")
        check(edit(String(repeating: "9", count: 38), .digit(9), fiat: true).count == 38, "Fiat Decimal precision bounded")
        check(edit(String(repeating: "9", count: 450), .digit(9)).count == 450, "Native input bounded")
        check(edit("1", .digit(10)) == "1", "Invalid key ignored")
        for decimals in [0, 6, 8, 18, 24, 38, 255] {
            let smallest = "0." + String(repeating: "0", count: max(0, decimals - 1)) + "1"
            let text = decimals == 0 ? "1" : smallest
            let canonical = text.reduce("") { partial, character in
                edit(partial, character == "." ? .decimal : .digit(character.wholeNumberValue!), decimals: decimals)
            }
            check(try! OathSendAmount.atomic(canonical, decimals: decimals, locale: en) == "1", "Keypad preserves one atomic unit at every supported precision")
        }
        for locale in [en, Locale(identifier: "ar"), Locale(identifier: "de_DE")] {
            check(edit("12.3", .digit(4), fiat: true, locale: locale) == "12.34", "Fiat accepts second decimal in every locale")
            check(edit("12.34", .digit(5), fiat: true, locale: locale) == "12.34", "Fiat rejects third decimal in every locale")
        }
        check(OathSendAmount.fiatInput(Decimal(string: "12.999")!) == "12.99", "Unit switch cannot round the editable amount up")
        check(OathSendAmount.fiatInput(.nan) == nil, "Invalid conversion stays unavailable")
        check(OathSendAmount.fiatInput(-1) == nil, "Negative conversion stays unavailable")
        for currency in ["USD", "JPY", "KWD", "JOD"] {
            let money = OathAssetAmountFormat(locale: en, selectedCurrencyCode: currency)
            check(money.money(Decimal(string: "12.3456")!).hasSuffix("12.35"), "Send review follows shared two-decimal policy for every currency")
            check(money.money(Decimal(string: "0.001")!).hasPrefix("< ") && money.money(Decimal(string: "0.001")!).hasSuffix("0.01"), "Sub-cent send values use the lower bound")
        }
        let usd = OathSendAmountFormat(locale: en, currency: "USD")
        check(usd.amount("0", fiat: true, symbol: "BTC", decimals: 8, belowFiatMinimum: true) == "< $0.01", "Positive sub-cent Max displays a bound, not zero")
        check(usd.amount("", fiat: true, symbol: "BTC", decimals: 8) == "$0", "Fiat placeholder retains symbol")
        check(usd.amount("12.00", fiat: true, symbol: "BTC", decimals: 8) == "$12.00", "Typing retains dollar and trailing zeroes")
        check(usd.amount("", fiat: false, symbol: "BTC", decimals: 8) == "0.000 BTC", "Native placeholder includes ticker")
        check(usd.amount("1.", fiat: false, symbol: "BTC", decimals: 8) == "1. BTC", "Native ticker remains while typing")
        let euro = OathSendAmountFormat(locale: Locale(identifier: "de_DE"), currency: "EUR")
        check(euro.amount("1.20", fiat: true, symbol: "BTC", decimals: 8).hasPrefix("1,20"), "Localized decimal placement")
        check(euro.amount("1", fiat: true, symbol: "BTC", decimals: 8).hasSuffix("€"), "Currency suffix retained")
        let ar = OathSendAmountFormat(locale: Locale(identifier: "ar"), currency: "USD")
        check(OathSendAmount.normalized(ar.number("12.30"), locale: Locale(identifier: "ar")) == "12.30", "Localized digits round trip exactly")

        let suite = "OathSendUnitTests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        check(OathSendUnitPreference.isFiat(in: preferences), "New installs default to local currency")
        OathSendUnitPreference.save(fiat: false, in: preferences)
        check(!OathSendUnitPreference.isFiat(in: UserDefaults(suiteName: suite)!), "Native choice survives a new preferences instance")
        OathSendUnitPreference.save(fiat: true, in: preferences)
        check(OathSendUnitPreference.isFiat(in: UserDefaults(suiteName: suite)!), "Fiat choice survives a new preferences instance")
        for price: Decimal? in [nil, 0, -1, .nan] {
            check(!OathSendUnitPreference.allowsFiat(price: price, decimals: 8), "Unusable prices hide fiat entry and its switch")
            let initial = OathSendUnitPreference.availableEntry(fiat: true, amount: "", price: price, decimals: 8)
            check(!initial.fiat && initial.amount.isEmpty, "Unpriced assets start in native units despite saved fiat preference")
            let interrupted = OathSendUnitPreference.availableEntry(fiat: true, amount: "100", price: price, decimals: 8)
            check(!interrupted.fiat && interrupted.amount.isEmpty, "A lost price never turns 100 dollars into 100 coins")
            let native = OathSendUnitPreference.availableEntry(fiat: false, amount: "0.12345678", price: price, decimals: 8)
            check(!native.fiat && native.amount == "0.12345678", "Price loss preserves exact native entry")
        }
        check(OathSendUnitPreference.isFiat(in: preferences), "Temporary missing prices preserve saved fiat choice")
        check(OathSendUnitPreference.allowsFiat(price: 100000, decimals: 8), "Priced assets allow switching units")
        let priced = OathSendUnitPreference.availableEntry(fiat: OathSendUnitPreference.isFiat(in: preferences), amount: "100", price: 100000, decimals: 8)
        check(priced.fiat && priced.amount == "100", "Next priced asset respects saved fiat preference")
        let returnedPrice = OathSendUnitPreference.availableEntry(fiat: false, amount: "0.12345678", price: 100000, decimals: 8)
        check(!returnedPrice.fiat && returnedPrice.amount == "0.12345678", "Returning prices do not relabel an in-progress native amount")
        check(!OathSendUnitPreference.allowsFiat(price: 1, decimals: 39), "Unsupported fiat precision stays native")
        check(OathSendRecipientRules.validMemo("4294967295", networkID: "xrpl"), "Max XRP tag")
        check(!OathSendRecipientRules.validMemo("4294967296", networkID: "xrpl"), "Overflow tag")
        check(!OathSendRecipientRules.validMemo("1.5", networkID: "xrpl"), "Integer tag")
        check(OathSendRecipientRules.validMemo("0", networkID: "xrpl"), "Zero is a valid tag")
        check(OathSendRecipientRules.validMemo("", networkID: "xrpl"), "Optional tag")
        check(!OathSendRecipientRules.validMemo(String(repeating: "ع", count: 15), networkID: "stellar"), "Stellar memo measures bytes")
        check(OathSendRecipientRules.validMemo(String(repeating: "a", count: 28), networkID: "stellar"), "Stellar exact byte limit")
        check(!OathSendRecipientRules.validMemo("memo\n", networkID: "ton"), "No hidden control characters")
        check(!OathSendRecipientRules.validMemo("arbitrary", networkID: "ethereum"), "Don't silently ignore an unsupported memo")
        print("Passed \(count) send amount and recipient checks (Mac host).")
    }
}
