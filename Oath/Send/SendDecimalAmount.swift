import Foundation

enum SendDecimalAmount {
    private static let maximumInputLength = 200
    private static let maximumUInt256 =
        "115792089237316195423570985008687907853269984665640564039457584007913129639935"

    struct Parsed: Hashable, Sendable {
        let canonical: String
        let fractionDigits: Int

        var isZero: Bool {
            canonical == "0"
        }
    }

    static func parseUserUnits(
        _ value: String,
        maximumFractionDigits: Int? = nil
    ) throws -> Parsed {
        guard
            !value.isEmpty,
            value.utf8.count <= maximumInputLength,
            value.allSatisfy({ character in
                character == "."
                    || (character >= "0" && character <= "9")
            })
        else {
            throw SendPaymentRequestError.invalidAmount
        }

        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard
            components.count <= 2,
            let integerPart = components.first,
            !integerPart.isEmpty,
            components.count == 1 || !components[1].isEmpty
        else {
            throw SendPaymentRequestError.invalidAmount
        }

        let fraction = components.count == 2
            ? String(components[1])
            : ""
        if let maximumFractionDigits,
           fraction.count > maximumFractionDigits {
            throw SendPaymentRequestError.invalidAmount
        }

        let normalizedInteger = stripLeadingZeros(
            String(integerPart)
        )
        let normalizedFraction = stripTrailingZeros(fraction)
        let canonical = normalizedFraction.isEmpty
            ? normalizedInteger
            : "\(normalizedInteger).\(normalizedFraction)"
        return Parsed(
            canonical: canonical,
            fractionDigits: fraction.count
        )
    }

    static func parseUInt256Expression(
        _ value: String
    ) throws -> String {
        guard
            !value.isEmpty,
            value.utf8.count <= maximumInputLength
        else {
            throw SendPaymentRequestError.invalidAmount
        }

        let exponentIndexes = value.indices.filter {
            value[$0] == "e" || value[$0] == "E"
        }
        guard exponentIndexes.count <= 1 else {
            throw SendPaymentRequestError.invalidAmount
        }

        var mantissa: String
        let rawExponent: String?
        if let exponentIndex = exponentIndexes.first {
            mantissa = String(value[..<exponentIndex])
            rawExponent = String(
                value[value.index(after: exponentIndex)...]
            )
        } else {
            mantissa = value
            rawExponent = nil
        }
        if mantissa.first == "+" {
            mantissa.removeFirst()
        } else if mantissa.first == "-" {
            throw SendPaymentRequestError.invalidAmount
        }
        let parsedMantissa = try parseUserUnits(mantissa)
        let exponent: Int
        if var rawExponent {
            guard
                !rawExponent.isEmpty
            else {
                throw SendPaymentRequestError.invalidAmount
            }
            var multiplier = 1
            if rawExponent.first == "-" {
                multiplier = -1
                rawExponent.removeFirst()
            } else if rawExponent.first == "+" {
                rawExponent.removeFirst()
            }
            guard
                !rawExponent.isEmpty,
                rawExponent.allSatisfy({
                    $0 >= "0" && $0 <= "9"
                }),
                let parsedExponent = Int(rawExponent),
                parsedExponent <= 255
            else {
                throw SendPaymentRequestError.invalidAmount
            }
            exponent = parsedExponent * multiplier
        } else {
            exponent = 0
        }

        let split = parsedMantissa.canonical.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        let integer = String(split[0])
        let fraction = split.count == 2 ? String(split[1]) : ""
        let digits = stripLeadingZeros(integer + fraction)
        let shift = exponent - fraction.count
        guard shift >= 0 else {
            throw SendPaymentRequestError.invalidAmount
        }
        let expanded = digits + String(
            repeating: "0",
            count: shift
        )

        let normalized = stripLeadingZeros(
            expanded.isEmpty ? "0" : expanded
        )
        guard compareInteger(normalized, maximumUInt256) != .orderedDescending
        else {
            throw SendPaymentRequestError.amountTooLarge
        }
        return normalized
    }

    static func userUnits(
        fromAtomicUnits atomicUnits: String,
        decimals: Int
    ) -> String {
        let digits = stripLeadingZeros(atomicUnits)
        guard decimals > 0 else { return digits }

        let padded: String
        if digits.count <= decimals {
            padded = String(
                repeating: "0",
                count: decimals - digits.count + 1
            ) + digits
        } else {
            padded = digits
        }
        let splitIndex = padded.index(
            padded.endIndex,
            offsetBy: -decimals
        )
        let integer = String(padded[..<splitIndex])
        let fraction = stripTrailingZeros(
            String(padded[splitIndex...])
        )
        return fraction.isEmpty
            ? stripLeadingZeros(integer)
            : "\(stripLeadingZeros(integer)).\(fraction)"
    }

    static func compare(
        _ lhs: String,
        _ rhs: String
    ) -> ComparisonResult? {
        guard
            let left = try? parseUserUnits(lhs),
            let right = try? parseUserUnits(rhs)
        else {
            return nil
        }
        let leftParts = parts(left.canonical)
        let rightParts = parts(right.canonical)
        let integerComparison = compareInteger(
            leftParts.integer,
            rightParts.integer
        )
        guard integerComparison == .orderedSame else {
            return integerComparison
        }

        let width = max(
            leftParts.fraction.count,
            rightParts.fraction.count
        )
        let leftFraction = leftParts.fraction.padding(
            toLength: width,
            withPad: "0",
            startingAt: 0
        )
        let rightFraction = rightParts.fraction.padding(
            toLength: width,
            withPad: "0",
            startingAt: 0
        )
        if leftFraction == rightFraction {
            return .orderedSame
        }
        return leftFraction < rightFraction
            ? .orderedAscending
            : .orderedDescending
    }

    static func acceptsEditableInput(
        _ value: String,
        maximumFractionDigits: Int
    ) -> Bool {
        guard value.utf8.count <= maximumInputLength else {
            return false
        }
        if value.isEmpty {
            return true
        }
        guard value.allSatisfy({
            $0 == "." || ($0 >= "0" && $0 <= "9")
        }) else {
            return false
        }
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count <= 2 else { return false }
        if components.count == 2 {
            return components[1].count <= maximumFractionDigits
        }
        return true
    }

    static func normalizedDecimalKeyboardInput(
        _ value: String,
        decimalSeparator: String = Locale.current.decimalSeparator ?? "."
    ) -> String {
        guard
            decimalSeparator != ".",
            !decimalSeparator.isEmpty
        else {
            return value
        }
        return value.replacingOccurrences(
            of: decimalSeparator,
            with: "."
        )
    }

    static func decimalStorageText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private static func parts(
        _ value: String
    ) -> (integer: String, fraction: String) {
        let values = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return (
            String(values[0]),
            values.count == 2 ? String(values[1]) : ""
        )
    }

    private static func compareInteger(
        _ lhs: String,
        _ rhs: String
    ) -> ComparisonResult {
        let left = stripLeadingZeros(lhs)
        let right = stripLeadingZeros(rhs)
        if left.count != right.count {
            return left.count < right.count
                ? .orderedAscending
                : .orderedDescending
        }
        if left == right {
            return .orderedSame
        }
        return left < right ? .orderedAscending : .orderedDescending
    }

    private static func stripLeadingZeros(_ value: String) -> String {
        let stripped = value.drop(while: { $0 == "0" })
        return stripped.isEmpty ? "0" : String(stripped)
    }

    private static func stripTrailingZeros(_ value: String) -> String {
        String(value.reversed().drop(while: { $0 == "0" }).reversed())
    }
}

enum SendAmountEntryMode: String, Hashable, Sendable {
    case asset
    case localCurrency
}

enum SendAmountPresentation {
    /// Presentation only: never reduce the precision of the authorized transfer.
    static func activityAmount(
        amount: String?,
        asset: SendAssetChoice,
        currency: WalletCurrencyContext,
        nativeUnitUSDPrice: Decimal? = nil,
        cachedAssetUnitUSDPrice: Decimal? = nil
    ) -> String? {
        guard let amount, let parsed = try? SendDecimalAmount.parseUserUnits(amount),
              !parsed.isZero else { return nil }

        if currency.ratePerUSD > 0,
           let quantity = Decimal(string: parsed.canonical, locale: Locale(identifier: "en_US_POSIX")),
           let price = unitUSDPrice(for: asset, nativeUnitUSDPrice: nativeUnitUSDPrice,
                                    cachedAssetUnitUSDPrice: cachedAssetUnitUSDPrice),
           let usdValue = product(quantity, price), usdValue > 0,
           let localValue = product(usdValue, currency.ratePerUSD), localValue > 0 {
            return EnglishNumbers.unitPrice(usdValue, using: currency)
        }

        // Truncate the canonical decimal string, preserving even amounts larger
        // than Decimal's precision. Never round an unpriced transfer upward.
        let parts = parsed.canonical.split(separator: ".", maxSplits: 1)
        var displayed = String(parts[0])
        if parts.count == 2 {
            let fraction = parts[1].prefix(8)
            let trimmed = String(fraction.reversed().drop(while: { $0 == "0" }).reversed())
            if !trimmed.isEmpty {
                displayed += "." + trimmed
            } else if displayed == "0" {
                displayed += ".00000000"
            }
        }
        return EnglishNumbers.localized("wallet.format.asset_amount", displayed, asset.symbol)
    }

    static func unitUSDPrice(
        for asset: SendAssetChoice,
        nativeUnitUSDPrice: Decimal? = nil,
        cachedAssetUnitUSDPrice: Decimal? = nil
    ) -> Decimal? {
        if let pricing = SendAmountEntryConverter.pricing(
            asset: asset,
            currency: WalletCurrencyContext(
                code: WalletCurrencyPreference.defaultCode,
                ratePerUSD: 1
            )
        ) {
            return pricing.unitPrice
        }
        if asset.isNative,
           let nativeUnitUSDPrice,
           nativeUnitUSDPrice > 0 {
            return nativeUnitUSDPrice
        }
        if let cachedAssetUnitUSDPrice,
           cachedAssetUnitUSDPrice > 0 {
            return cachedAssetUnitUSDPrice
        }
        return nil
    }

    static func unitUSDPrice(
        for asset: SendAssetChoice,
        nativeUnitUSDPrice: Decimal?,
        database: WalletDatabase,
        fetchQuote: (@Sendable (WalletAsset) async throws -> AssetUSDPrice)? = nil
    ) async -> Decimal? {
        if let price = unitUSDPrice(for: asset, nativeUnitUSDPrice: nativeUnitUSDPrice) {
            return price
        }
        let quote = try? await database.cachedAssetUSDPrice(
            assetID: AssetIdentityKey.canonical(asset.id)
        )
        if let quote { return quote.price }
        guard !Task.isCancelled else { return nil }
        let marketAsset = WalletAsset(
            id: AssetIdentityKey.canonical(asset.id), name: asset.name,
            symbol: asset.symbol, logoSource: asset.logoSource,
            network: asset.blockchain, balance: asset.balance,
            fiatValue: asset.fiatValue, decimals: asset.decimals,
            isVerified: asset.isVerified
        )
        let fetched: AssetUSDPrice?
        if let fetchQuote {
            fetched = try? await fetchQuote(marketAsset)
        } else {
            fetched = try? await AssetPriceClient(database: database).usdPrice(for: marketAsset)
        }
        guard let fetched, fetched.price > 0,
              AssetIdentityKey.canonical(fetched.assetID) == marketAsset.id else { return nil }
        return fetched.price
    }

    static func formatted(
        amount: String,
        asset: SendAssetChoice,
        currency: WalletCurrencyContext,
        nativeUnitUSDPrice: Decimal? = nil,
        cachedAssetUnitUSDPrice: Decimal? = nil
    ) -> String {
        let assetAmount = EnglishNumbers.localized(
            "wallet.format.asset_amount",
            amount,
            asset.symbol
        )
        guard
            currency.ratePerUSD > 0,
            let parsed = try? SendDecimalAmount.parseUserUnits(amount),
            let amountValue = Decimal(
                string: parsed.canonical,
                locale: Locale(identifier: "en_US_POSIX")
            ),
            let unitUSDPrice = unitUSDPrice(
                for: asset,
                nativeUnitUSDPrice: nativeUnitUSDPrice,
                cachedAssetUnitUSDPrice: cachedAssetUnitUSDPrice
            ),
            let usdValue = product(amountValue, unitUSDPrice)
        else {
            return assetAmount
        }
        return EnglishNumbers.currency(
            usdValue,
            using: currency
        )
    }

    private static func product(
        _ lhs: Decimal,
        _ rhs: Decimal
    ) -> Decimal? {
        var left = lhs
        var right = rhs
        var result = Decimal()
        let error = NSDecimalMultiply(
            &result,
            &left,
            &right,
            .plain
        )
        switch error {
        case .noError, .lossOfPrecision, .underflow:
            guard !NSDecimalIsNotANumber(&result), result >= 0 else {
                return nil
            }
            return result
        case .overflow, .divideByZero:
            return nil
        @unknown default:
            return nil
        }
    }
}

enum SendMaximumBalanceIntent {
    static func exactBalanceUserUnits(
        for asset: SendAssetChoice
    ) -> String {
        if let balanceAtomic = asset.balanceAtomic,
           SendAtomicAmount.isCanonical(balanceAtomic),
           (0...255).contains(asset.decimals) {
            return SendDecimalAmount.userUnits(
                fromAtomicUnits: balanceAtomic,
                decimals: asset.decimals
            )
        }
        return SendDecimalAmount.decimalStorageText(
            max(asset.balance, 0)
        )
    }
}

struct SendLocalCurrencyPricing: Hashable, Sendable {
    let currencyCode: String
    let unitPrice: Decimal
    let balanceValue: Decimal
}

enum SendAmountEntryConversionError: Error, Hashable, Sendable {
    case invalidInput
    case pricingUnavailable
}

enum SendAmountEntryConverter {
    static let maximumLocalFractionDigits = 8

    static func pricing(
        asset: SendAssetChoice,
        currency: WalletCurrencyContext, unitUSDPrice: Decimal? = nil
    ) -> SendLocalCurrencyPricing? {
        guard currency.ratePerUSD > 0 else { return nil }
        // Conversion depends on a unit quote, not on owning a positive balance.
        // Preserve holding-derived pricing when available, otherwise use the
        // selected asset's independent market quote (never a token's gas coin).
        if asset.balance > 0, asset.fiatValue > 0 {
            let balanceValue = asset.fiatValue * currency.ratePerUSD
            let localPrice = balanceValue / asset.balance
            guard balanceValue > 0, localPrice > 0 else { return nil }
            return SendLocalCurrencyPricing(
                currencyCode: currency.code,
                unitPrice: localPrice,
                balanceValue: balanceValue
            )
        }
        guard let unitUSDPrice, unitUSDPrice > 0 else { return nil }
        let localPrice = unitUSDPrice * currency.ratePerUSD
        guard localPrice > 0 else { return nil }
        return SendLocalCurrencyPricing(
            currencyCode: currency.code,
            unitPrice: localPrice,
            balanceValue: max(asset.balance, 0) * localPrice
        )
    }

    static func assetAmount(
        from input: String,
        mode: SendAmountEntryMode,
        usesMaximumBalance: Bool,
        asset: SendAssetChoice,
        currency: WalletCurrencyContext, unitUSDPrice: Decimal? = nil
    ) throws -> String {
        if usesMaximumBalance {
            return try canonicalDecimal(
                SendMaximumBalanceIntent.exactBalanceUserUnits(
                    for: asset
                )
            )
        }

        let parsed = try parseDecimal(input)
        switch mode {
        case .asset:
            return parsed.canonical
        case .localCurrency:
            guard let pricing = pricing(
                asset: asset,
                currency: currency, unitUSDPrice: unitUSDPrice
            ) else {
                throw SendAmountEntryConversionError
                    .pricingUnavailable
            }
            let assetValue = rounded(
                parsed.value / pricing.unitPrice,
                scale: asset.decimals,
                mode: .down
            )
            return try canonicalDecimal(storageString(assetValue))
        }
    }

    static func convertedInput(
        _ input: String,
        from source: SendAmountEntryMode,
        to destination: SendAmountEntryMode,
        asset: SendAssetChoice,
        currency: WalletCurrencyContext, unitUSDPrice: Decimal? = nil
    ) throws -> String {
        guard source != destination else { return input }
        let parsed = try parseDecimal(input)
        guard let pricing = pricing(
            asset: asset,
            currency: currency, unitUSDPrice: unitUSDPrice
        ) else {
            throw SendAmountEntryConversionError.pricingUnavailable
        }

        let converted: Decimal
        let scale: Int
        switch (source, destination) {
        case (.asset, .localCurrency):
            converted = parsed.value * pricing.unitPrice
            scale = maximumLocalFractionDigits
        case (.localCurrency, .asset):
            converted = parsed.value / pricing.unitPrice
            scale = asset.decimals
        default:
            return input
        }
        return try canonicalDecimal(
            storageString(
                rounded(converted, scale: scale, mode: .down)
            )
        )
    }

    static func maximumInput(
        mode: SendAmountEntryMode,
        asset: SendAssetChoice,
        currency: WalletCurrencyContext, unitUSDPrice: Decimal? = nil
    ) throws -> String {
        switch mode {
        case .asset:
            return try canonicalDecimal(
                SendMaximumBalanceIntent.exactBalanceUserUnits(
                    for: asset
                )
            )
        case .localCurrency:
            guard let pricing = pricing(
                asset: asset,
                currency: currency, unitUSDPrice: unitUSDPrice
            ) else {
                throw SendAmountEntryConversionError
                    .pricingUnavailable
            }
            return try canonicalDecimal(
                storageString(
                    rounded(
                        pricing.balanceValue,
                        scale: maximumLocalFractionDigits,
                        mode: .down
                    )
                )
            )
        }
    }

    private static func parseDecimal(
        _ input: String
    ) throws -> (canonical: String, value: Decimal) {
        let canonical = try canonicalDecimal(input)
        guard
            let value = Decimal(
                string: canonical,
                locale: Locale(identifier: "en_US_POSIX")
            )
        else {
            throw SendAmountEntryConversionError.invalidInput
        }
        return (canonical, value)
    }

    private static func canonicalDecimal(
        _ input: String
    ) throws -> String {
        do {
            return try SendDecimalAmount.parseUserUnits(input)
                .canonical
        } catch {
            throw SendAmountEntryConversionError.invalidInput
        }
    }

    private static func rounded(
        _ value: Decimal,
        scale: Int,
        mode: Decimal.RoundingMode
    ) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, scale, mode)
        return result
    }

    private static func storageString(_ value: Decimal) -> String {
        var mutableValue = value
        return NSDecimalString(
            &mutableValue,
            Locale(identifier: "en_US_POSIX") as NSLocale
        )
    }
}
