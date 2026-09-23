import Foundation

struct SendCustomNetworkFeeEntryFeedback: Equatable, Sendable {
    static let highFeeMultiple = Decimal(3)

    let localAmount: Decimal
    let balancePercentage: Decimal?
    let fastestMultiple: Decimal?
    let exceedsAvailableBalance: Bool
    let exceedsHighFeeThreshold: Bool

    init?(
        input: String,
        availableLocalBalance: Decimal?,
        fastestLocalAmount: Decimal?
    ) {
        guard let parsed = try? SendDecimalAmount.parseUserUnits(
            SendAmountKeypadInput.submittableInput(input),
            maximumFractionDigits:
                SendNetworkFeeCustomLocalConverter.maximumFractionDigits
        ), let amount = Decimal(
            string: parsed.canonical,
            locale: Locale(identifier: "en_US_POSIX")
        ), amount >= 0 else {
            return nil
        }

        localAmount = amount
        if let availableLocalBalance, availableLocalBalance > 0 {
            balancePercentage = amount / availableLocalBalance * 100
            exceedsAvailableBalance = amount > availableLocalBalance
        } else {
            balancePercentage = nil
            exceedsAvailableBalance = availableLocalBalance == 0
                && amount > 0
        }

        if let fastestLocalAmount, fastestLocalAmount > 0 {
            let multiple = amount / fastestLocalAmount
            fastestMultiple = multiple
            exceedsHighFeeThreshold = multiple
                > Self.highFeeMultiple
        } else {
            fastestMultiple = nil
            exceedsHighFeeThreshold = false
        }
    }
}

enum SendNetworkFeeCustomLocalConverter {
    static let maximumFractionDigits = 8

    static func targetAtomicAmount(
        from input: String,
        nativeDecimals: Int,
        nativeUnitUSDPrice: Decimal,
        currency: WalletCurrencyContext
    ) throws -> String {
        guard nativeDecimals >= 0,
              nativeDecimals <= 38,
              nativeUnitUSDPrice > 0,
              currency.ratePerUSD > 0 else {
            throw SendNetworkFeeInputError.invalid
        }
        let parsed: SendDecimalAmount.Parsed
        do {
            parsed = try SendDecimalAmount.parseUserUnits(
                SendAmountKeypadInput.submittableInput(input),
                maximumFractionDigits: maximumFractionDigits
            )
        } catch {
            throw SendNetworkFeeInputError.invalid
        }
        guard !parsed.isZero else {
            throw SendNetworkFeeInputError.zero
        }
        guard let localValue = Decimal(
            string: parsed.canonical,
            locale: Locale(identifier: "en_US_POSIX")
        ) else {
            throw SendNetworkFeeInputError.invalid
        }

        var scale: Decimal = 1
        for _ in 0..<nativeDecimals { scale *= 10 }
        var atomic = localValue
            / currency.ratePerUSD
            / nativeUnitUSDPrice
            * scale
        var rounded = Decimal()
        // A custom fee is a hard user budget. Never turn a fiat amount into
        // more native atomic units than the user entered through rounding.
        NSDecimalRound(&rounded, &atomic, 0, .down)
        let result = NSDecimalNumber(decimal: rounded).stringValue
        guard SendAtomicAmount.isCanonical(result), result != "0" else {
            throw SendNetworkFeeInputError.tooLarge
        }
        return result
    }

    static func editableLocalValue(
        estimate: SendNetworkFeeEstimate,
        nativeUnitUSDPrice: Decimal,
        currency: WalletCurrencyContext
    ) -> String? {
        guard let usd = estimate.usdValue(
            unitUSDPrice: nativeUnitUSDPrice
        ), usd > 0, currency.ratePerUSD > 0 else {
            return nil
        }
        var local = usd * currency.ratePerUSD
        var rounded = Decimal()
        NSDecimalRound(
            &rounded,
            &local,
            maximumFractionDigits,
            .down
        )
        let value = SendDecimalAmount.decimalStorageText(rounded)
        guard let parsed = try? SendDecimalAmount.parseUserUnits(
            value,
            maximumFractionDigits: maximumFractionDigits
        ), !parsed.isZero else {
            return nil
        }
        return parsed.canonical
    }

    static func customValue(
        targetAtomicAmount: String,
        model: SendNetworkFeeCustomModel,
        basis: SendNetworkFeeCostBasis
    ) throws -> SendNetworkFeeCustomValue {
        guard SendAtomicAmount.isCanonical(targetAtomicAmount),
              targetAtomicAmount != "0" else {
            throw SendNetworkFeeInputError.invalid
        }
        switch (model, basis) {
        case let (
            .evmEIP1559,
            .eip1559(units, minimumRate, suggestedPriorityRate, additionalReserve)
        ):
            let rate = try requiredRate(
                total: executionBudget(targetAtomicAmount, reserve: additionalReserve),
                units: units,
                minimumRate: minimumRate
            )
            let priorityRate = SendAtomicAmount.compare(
                suggestedPriorityRate,
                rate
            ) == .orderedDescending ? rate : suggestedPriorityRate
            return SendNetworkFeeCustomValue(
                model: model,
                primaryValue: rate,
                secondaryValue: priorityRate,
                totalBudgetAtomic: targetAtomicAmount
            )
        case let (.evmLegacy, .linear(units, minimumRate, additionalReserve)),
             let (.utxoPerVByte, .linear(units, minimumRate, additionalReserve)):
            return SendNetworkFeeCustomValue(
                model: model,
                primaryValue: try requiredRate(
                    total: executionBudget(targetAtomicAmount, reserve: additionalReserve),
                    units: units,
                    minimumRate: minimumRate
                ),
                secondaryValue: nil,
                totalBudgetAtomic: targetAtomicAmount
            )
        case let (.solanaPriority, .solana(computeUnits, baseAtomic)):
            guard SendAtomicAmount.compare(
                targetAtomicAmount,
                String(baseAtomic)
            ) != .orderedAscending else {
                throw SendNetworkFeeInputError.belowNetworkMinimum
            }
            let priorityAtomic = try SendAtomicAmount.subtract(
                targetAtomicAmount,
                String(baseAtomic)
            )
            let scaled = try SendAtomicAmount.multiply(
                priorityAtomic,
                by: 1_000_000
            )
            return SendNetworkFeeCustomValue(
                model: model,
                primaryValue: try divideFloor(
                    scaled,
                    by: computeUnits
                ),
                secondaryValue: nil,
                totalBudgetAtomic: targetAtomicAmount
            )
        case let (.tronFeeLimit, .direct(minimumAtomic)):
            guard SendAtomicAmount.isCanonical(minimumAtomic),
                  SendAtomicAmount.compare(
                      targetAtomicAmount,
                      minimumAtomic
                  ) != .orderedAscending else {
                throw SendNetworkFeeInputError.belowNetworkMinimum
            }
            return SendNetworkFeeCustomValue(
                model: model,
                primaryValue: targetAtomicAmount,
                secondaryValue: nil,
                totalBudgetAtomic: targetAtomicAmount
            )
        default:
            throw SendNetworkFeeInputError.invalid
        }
    }

    private static func executionBudget(_ total: String, reserve: String) throws -> String {
        guard SendAtomicAmount.isCanonical(reserve),
              SendAtomicAmount.compare(total, reserve) == .orderedDescending else {
            throw SendNetworkFeeInputError.belowNetworkMinimum
        }
        return try SendAtomicAmount.subtract(total, reserve)
    }

    static func divideCeiling(
        _ value: String,
        by divisor: UInt64
    ) throws -> String {
        guard SendAtomicAmount.isCanonical(value),
              divisor > 0,
              divisor <= UInt64.max / 10 else {
            throw SendNetworkFeeInputError.tooLarge
        }
        var quotient: [UInt8] = []
        var remainder: UInt64 = 0
        for byte in value.utf8 {
            let combined = remainder * 10 + UInt64(byte - 48)
            let digit = combined / divisor
            remainder = combined % divisor
            if !quotient.isEmpty || digit > 0 {
                quotient.append(UInt8(digit) + 48)
            }
        }
        let floor = quotient.isEmpty
            ? "0"
            : String(decoding: quotient, as: UTF8.self)
        return remainder == 0 ? floor : SendAtomicAmount.add(floor, "1")
    }

    static func divideFloor(
        _ value: String,
        by divisor: UInt64
    ) throws -> String {
        guard SendAtomicAmount.isCanonical(value), divisor > 0 else {
            throw SendNetworkFeeInputError.tooLarge
        }
        var quotient: [UInt8] = []
        var remainder: UInt64 = 0
        for byte in value.utf8 {
            let combined = remainder * 10 + UInt64(byte - 48)
            let digit = combined / divisor
            remainder = combined % divisor
            if !quotient.isEmpty || digit > 0 {
                quotient.append(UInt8(digit) + 48)
            }
        }
        return quotient.isEmpty
            ? "0"
            : String(decoding: quotient, as: UTF8.self)
    }

    private static func requiredRate(
        total: String,
        units: UInt64,
        minimumRate: UInt64
    ) throws -> String {
        let minimumTotal = try SendAtomicAmount.multiply(
            String(minimumRate),
            by: units
        )
        guard SendAtomicAmount.compare(
            total,
            minimumTotal
        ) != .orderedAscending else {
            throw SendNetworkFeeInputError.belowNetworkMinimum
        }
        // The network accepts an integer rate, so exact division is not always
        // possible. Floor the rate and keep `total` separately as the hard
        // budget; rounding upward is what previously made 0.0010 reappear as
        // a larger fee.
        let rate = try divideFloor(total, by: units)
        guard SendAtomicAmount.compare(
            rate,
            String(minimumRate)
        ) != .orderedAscending else {
            throw SendNetworkFeeInputError.belowNetworkMinimum
        }
        return rate
    }
}
