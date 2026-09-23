import Foundation

enum XRPAmount {
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func userUnitsFromDrops(_ drops: String) throws -> String {
        guard let value = ExactDecimalText.canonicalUnsignedInteger(drops)
        else {
            throw XRPProviderError.invalidResponse("drops")
        }
        return insertDecimal(value, decimals: XRPConstants.decimals)
    }

    static func canonicalIssued(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.count <= 96,
              let decimal = Decimal(string: value, locale: locale)
        else {
            throw XRPProviderError.invalidResponse("issued_amount")
        }
        let text = NSDecimalNumber(decimal: decimal).stringValue
        guard text != "NaN" else {
            throw XRPProviderError.invalidResponse("issued_amount")
        }
        return text
    }

    static func canonicalIssuedPayment(_ value: String) throws -> String {
        let parsed: SendDecimalAmount.Parsed
        do {
            parsed = try SendDecimalAmount.parseUserUnits(value)
        } catch {
            throw XRPProviderError.invalidResponse("issued_payment")
        }
        guard !parsed.isZero else {
            throw XRPProviderError.invalidResponse("issued_payment")
        }
        let pieces = parsed.canonical.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        let integer = String(pieces[0])
        let fraction = pieces.count == 2 ? String(pieces[1]) : ""
        let combined = integer + fraction
        let significant = combined.drop(while: { $0 == "0" })
        guard !significant.isEmpty, significant.count <= 16 else {
            throw XRPProviderError.invalidResponse("issued_precision")
        }

        let exponent: Int
        if integer != "0" {
            exponent = integer.count - 1
        } else {
            let leadingFractionZeros = fraction.prefix {
                $0 == "0"
            }.count
            exponent = -(leadingFractionZeros + 1)
        }
        guard (-96...80).contains(exponent) else {
            throw XRPProviderError.invalidResponse("issued_exponent")
        }
        return parsed.canonical
    }

    static func signed(_ value: String, outgoing: Bool) -> String {
        guard value != "0" else { return "0" }
        if outgoing {
            return value.hasPrefix("-") ? value : "-\(value)"
        }
        return value.hasPrefix("-") ? String(value.dropFirst()) : value
    }

    static func absolute(_ value: String) -> String {
        value.hasPrefix("-") ? String(value.dropFirst()) : value
    }

    static func isPositive(_ value: String) -> Bool {
        guard let decimal = Decimal(string: value, locale: locale) else {
            return false
        }
        return decimal > 0
    }

    static func isNonNegative(_ value: String) -> Bool {
        guard let decimal = Decimal(string: value, locale: locale) else {
            return false
        }
        return decimal >= 0
    }

    static func canIncrease(
        balance: String,
        by amount: String,
        through limit: String
    ) -> Bool {
        guard var parsedBalance = Decimal(
            string: balance,
            locale: locale
        ),
              var parsedAmount = Decimal(string: amount, locale: locale),
              let parsedLimit = Decimal(string: limit, locale: locale),
              parsedAmount > 0,
              parsedLimit >= 0
        else {
            return false
        }
        var result = Decimal()
        let calculation = NSDecimalAdd(
            &result,
            &parsedBalance,
            &parsedAmount,
            .plain
        )
        return calculation == .noError && result <= parsedLimit
    }

    static func decodedCurrency(_ currency: String) -> String {
        let upper = currency.uppercased()
        guard upper.count == 40,
              upper.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789ABCDEF")
                      .contains($0)
              })
        else {
            return upper
        }
        var bytes: [UInt8] = []
        var index = upper.startIndex
        while index < upper.endIndex {
            let next = upper.index(index, offsetBy: 2)
            guard let byte = UInt8(upper[index..<next], radix: 16) else {
                return upper
            }
            if byte != 0 { bytes.append(byte) }
            index = next
        }
        guard let decoded = String(bytes: bytes, encoding: .ascii),
              !decoded.isEmpty,
              decoded.unicodeScalars.allSatisfy({
                  $0.value >= 0x21 && $0.value <= 0x7E
              })
        else {
            return upper
        }
        return decoded.uppercased()
    }

    private static func insertDecimal(
        _ atomic: String,
        decimals: Int
    ) -> String {
        guard atomic != "0", decimals > 0 else { return atomic }
        let whole: String
        let fraction: String
        if atomic.count > decimals {
            let split = atomic.index(atomic.endIndex, offsetBy: -decimals)
            whole = String(atomic[..<split])
            fraction = String(atomic[split...])
        } else {
            whole = "0"
            fraction = String(repeating: "0", count: decimals - atomic.count)
                + atomic
        }
        let trimmed = fraction.replacingOccurrences(
            of: "0+$",
            with: "",
            options: .regularExpression
        )
        return trimmed.isEmpty ? whole : "\(whole).\(trimmed)"
    }
}
