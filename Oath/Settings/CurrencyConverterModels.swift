import Foundation

enum CurrencyConverterUnitKind: Int, CaseIterable, Sendable {
    case fiat
    case metal
    case crypto
}

struct CurrencyConverterUnit: Identifiable, Hashable, Sendable {
    let id: String
    let code: String
    let englishName: String
    let symbol: String
    let kind: CurrencyConverterUnitKind
    let usdPricePerUnit: Decimal?
    let flag: String
    let network: WalletBlockchain?
    let walletAssetID: String?
    let logoSource: AssetLogoSource?
    let sortOrder: Int

    var hasUsableRate: Bool {
        guard let usdPricePerUnit else { return false }
        return usdPricePerUnit > 0
    }

    func localizedName(locale: Locale) -> String {
        switch kind {
        case .fiat:
            locale.localizedString(forCurrencyCode: code)
                ?? englishName
        case .metal:
            WalletLocalization.string(
                code == "XAU"
                    ? "settings.converter.gold"
                    : "settings.converter.silver"
            )
        case .crypto:
            englishName
        }
    }

    func localizedDetail(locale: Locale) -> String {
        if kind == .crypto,
           let network,
           let networkName = ReceiveNetworkCatalog.catalogNetwork(
               for: network
           )?.localizedName,
           networkName.caseInsensitiveCompare(englishName) != .orderedSame {
            return "\(code) · \(networkName)"
        }

        if kind == .fiat {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .currency
            formatter.currencyCode = code
            let localizedSymbol = formatter.currencySymbol ?? symbol
            if localizedSymbol.caseInsensitiveCompare(code) != .orderedSame {
                return "\(localizedSymbol) · \(code)"
            }
        }

        return code
    }

    func matches(_ rawQuery: String, locale: Locale) -> Bool {
        let query = rawQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return true }

        return code.localizedStandardContains(query)
            || englishName.localizedStandardContains(query)
            || localizedName(locale: locale)
                .localizedStandardContains(query)
            || localizedDetail(locale: locale)
                .localizedStandardContains(query)
    }
}

struct CurrencyConverterSelection: Equatable, Sendable {
    let unitIDs: [String]
    let lastUsedUnitID: String

    init(unitIDs: [String], lastUsedUnitID: String? = nil) {
        var seen = Set<String>()
        let uniqueIDs = unitIDs.filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
        self.unitIDs = uniqueIDs
        self.lastUsedUnitID = lastUsedUnitID.flatMap {
            uniqueIDs.contains($0) ? $0 : nil
        } ?? uniqueIDs.first ?? ""
    }

    init(sourceID: String, targetID: String) {
        self.init(unitIDs: [sourceID, targetID])
    }

    var sourceID: String {
        unitIDs.first ?? ""
    }

    var targetID: String {
        unitIDs.dropFirst().first ?? ""
    }
}

struct CurrencyConverterDataset: Sendable {
    let units: [CurrencyConverterUnit]
    let fetchedAt: Date
}

enum CurrencyConverterSelectionResolver {
    static func resolve(
        stored: CurrencyConverterSelection?,
        localCurrencyCode: String,
        units: [CurrencyConverterUnit]
    ) -> CurrencyConverterSelection? {
        let usable = units.filter(\.hasUsableRate)
        guard usable.count >= 2 else { return nil }

        let usableIDs = Set(usable.map(\.id))
        if let stored {
            let retainedIDs = stored.unitIDs.filter(usableIDs.contains)
            if retainedIDs.count >= 2 {
                return CurrencyConverterSelection(
                    unitIDs: retainedIDs,
                    lastUsedUnitID: stored.lastUsedUnitID
                )
            }
        }

        let normalizedLocalCode = localCurrencyCode.uppercased()
        let preferredSourceID = "fiat:\(normalizedLocalCode)"
        let sourceID = if usableIDs.contains(preferredSourceID) {
            preferredSourceID
        } else if usableIDs.contains("fiat:USD") {
            "fiat:USD"
        } else {
            usable[0].id
        }

        let preferredTargetID = sourceID == "fiat:USD"
            ? "fiat:EUR"
            : "fiat:USD"
        let targetID = if usableIDs.contains(preferredTargetID) {
            preferredTargetID
        } else if let stored,
                  stored.targetID != sourceID,
                  usableIDs.contains(stored.targetID) {
            stored.targetID
        } else {
            usable.first(where: { $0.id != sourceID })!.id
        }

        return CurrencyConverterSelection(
            unitIDs: [sourceID, targetID],
            lastUsedUnitID: stored?.lastUsedUnitID
        )
    }
}

enum CurrencyConverterEngine {
    static let defaultAmountText = "1"
    static let maximumFractionDigits = 18
    static let maximumInputLength = 32

    static func sanitizedAmount(_ input: String) -> String {
        var result = ""
        var hasDecimalPoint = false
        var fractionalDigits = 0

        for character in input {
            if character >= "0", character <= "9" {
                if hasDecimalPoint {
                    guard fractionalDigits < maximumFractionDigits else {
                        continue
                    }
                    fractionalDigits += 1
                }
                if result == "0", !hasDecimalPoint {
                    result = String(character)
                } else {
                    result.append(character)
                }
            } else if isDecimalSeparator(character), !hasDecimalPoint {
                result += result.isEmpty ? "0." : "."
                hasDecimalPoint = true
            }

            if result.count >= maximumInputLength {
                break
            }
        }

        return result
    }

    private static func isDecimalSeparator(_ character: Character) -> Bool {
        character == "." || character == "," || character == "\u{066B}"
    }

    static func amount(from input: String) -> Decimal? {
        let submittable = input.hasSuffix(".")
            ? String(input.dropLast())
            : input
        guard !submittable.isEmpty else { return nil }
        return Decimal(
            string: submittable,
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func rate(
        from source: CurrencyConverterUnit,
        to target: CurrencyConverterUnit
    ) -> Decimal? {
        guard let sourceUSD = source.usdPricePerUnit,
              let targetUSD = target.usdPricePerUnit,
              sourceUSD > 0,
              targetUSD > 0 else {
            return nil
        }
        return sourceUSD / targetUSD
    }

    static func convert(
        amountText: String,
        from source: CurrencyConverterUnit,
        to target: CurrencyConverterUnit
    ) -> Decimal? {
        guard let amount = amount(from: amountText),
              amount >= 0,
              let rate = rate(from: source, to: target) else {
            return nil
        }
        return amount * rate
    }

    static func convertedAmountText(
        amountText: String,
        from source: CurrencyConverterUnit,
        to target: CurrencyConverterUnit
    ) -> String? {
        guard let converted = convert(
            amountText: amountText,
            from: source,
            to: target
        ) else {
            return nil
        }
        return editableFormatted(converted, for: target.kind)
    }

    static func convertedAmountTexts(
        amountText: String,
        from source: CurrencyConverterUnit,
        to targets: [CurrencyConverterUnit]
    ) -> [String: String] {
        targets.reduce(into: [:]) { result, target in
            result[target.id] = convertedAmountText(
                amountText: amountText,
                from: source,
                to: target
            )
        }
    }

    private static func editableFormatted(
        _ value: Decimal,
        for kind: CurrencyConverterUnitKind
    ) -> String {
        formatted(value, for: kind)
            .replacingOccurrences(of: ",", with: "")
    }

    static func formatted(
        _ value: Decimal,
        for kind: CurrencyConverterUnitKind
    ) -> String {
        let maximumDigits: Int = switch kind {
        case .fiat: 6
        case .metal: 8
        case .crypto: value != 0 && abs(value) < 0.00000001 ? 18 : 12
        }
        return EnglishNumbers.decimal(
            value,
            maximumFractionDigits: maximumDigits
        )
    }
}
