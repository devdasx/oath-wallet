import Foundation

enum SendAtomicAmount {
    static func fromUserUnits(
        _ input: String,
        decimals: Int
    ) throws -> String {
        guard decimals >= 0, decimals <= 255 else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        do {
            return try SendNetworkFeeBaseUnitConverter.baseUnits(
                from: input,
                decimals: decimals,
                permitsZero: false
            )
        } catch {
            throw SendTransactionSubmissionError.invalidAmount
        }
    }

    static func uint64(_ value: String) throws -> UInt64 {
        guard isCanonical(value), let result = UInt64(value) else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return result
    }

    static func int64(_ value: String) throws -> Int64 {
        guard isCanonical(value), let result = Int64(value) else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return result
    }

    static func compare(
        _ lhs: String,
        _ rhs: String
    ) -> ComparisonResult {
        let left = canonical(lhs)
        let right = canonical(rhs)
        if left.count != right.count {
            return left.count < right.count
                ? .orderedAscending
                : .orderedDescending
        }
        if left == right { return .orderedSame }
        return left.lexicographicallyPrecedes(right)
            ? .orderedAscending
            : .orderedDescending
    }

    static func add(_ lhs: String, _ rhs: String) -> String {
        let left = Array(canonical(lhs).utf8.reversed())
        let right = Array(canonical(rhs).utf8.reversed())
        let count = max(left.count, right.count)
        var output: [UInt8] = []
        output.reserveCapacity(count + 1)
        var carry = 0
        for index in 0..<count {
            let leftDigit = index < left.count
                ? Int(left[index] - 48)
                : 0
            let rightDigit = index < right.count
                ? Int(right[index] - 48)
                : 0
            let total = leftDigit + rightDigit + carry
            output.append(UInt8(total % 10) + 48)
            carry = total / 10
        }
        if carry > 0 {
            output.append(UInt8(carry) + 48)
        }
        return String(decoding: output.reversed(), as: UTF8.self)
    }

    static func subtract(
        _ lhs: String,
        _ rhs: String
    ) throws -> String {
        guard compare(lhs, rhs) != .orderedAscending else {
            throw SendTransactionSubmissionError
                .insufficientAssetBalance
        }
        let left = Array(canonical(lhs).utf8.reversed())
        let right = Array(canonical(rhs).utf8.reversed())
        var output: [UInt8] = []
        output.reserveCapacity(left.count)
        var borrow = 0
        for index in 0..<left.count {
            var digit = Int(left[index] - 48) - borrow
            let rightDigit = index < right.count
                ? Int(right[index] - 48)
                : 0
            if digit < rightDigit {
                digit += 10
                borrow = 1
            } else {
                borrow = 0
            }
            output.append(UInt8(digit - rightDigit) + 48)
        }
        return canonical(
            String(decoding: output.reversed(), as: UTF8.self)
        )
    }

    static func multiply(
        _ value: String,
        by multiplier: UInt64
    ) throws -> String {
        let multiplierDigitCount = String(multiplier).count
        guard isCanonical(value) else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        guard multiplier > 0 else { return "0" }
        let digits = Array(value.utf8.reversed())
        var output: [UInt8] = []
        output.reserveCapacity(
            min(value.count + multiplierDigitCount, 200)
        )
        var carry: UInt64 = 0
        for byte in digits {
            let product = UInt64(byte - 48)
                .multipliedReportingOverflow(by: multiplier)
            guard !product.overflow else {
                throw SendTransactionSubmissionError.amountOutOfRange
            }
            let total = product.partialValue
                .addingReportingOverflow(carry)
            guard !total.overflow else {
                throw SendTransactionSubmissionError.amountOutOfRange
            }
            output.append(UInt8(total.partialValue % 10) + 48)
            carry = total.partialValue / 10
        }
        while carry > 0 {
            output.append(UInt8(carry % 10) + 48)
            carry /= 10
        }
        let result = canonical(
            String(decoding: output.reversed(), as: UTF8.self)
        )
        guard isCanonical(result) else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return result
    }

    static func bigEndianData(_ value: String) throws -> Data {
        guard isCanonical(value) else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        if value == "0" { return Data() }
        var decimal = value
        var bytes: [UInt8] = []
        while decimal != "0" {
            let result = divide(decimal, by: 256)
            bytes.append(UInt8(result.remainder))
            decimal = result.quotient
        }
        return Data(bytes.reversed())
    }

    static func decimalFromHexQuantity(
        _ quantity: String
    ) throws -> String {
        guard quantity.hasPrefix("0x") else {
            throw SendTransactionSubmissionError
                .provider(
                    networkID: "evm",
                    code: "invalid_hex_quantity",
                    message: quantity
                )
        }
        let digits = quantity.dropFirst(2)
        guard !digits.isEmpty,
              digits.count <= 128,
              digits.allSatisfy(\.isHexDigit)
        else {
            throw SendTransactionSubmissionError
                .provider(
                    networkID: "evm",
                    code: "invalid_hex_quantity",
                    message: quantity
                )
        }
        var result = "0"
        for character in digits {
            guard let nibble = character.hexDigitValue else {
                throw SendTransactionSubmissionError.invalidAmount
            }
            result = add(
                try multiply(result, by: 16),
                String(nibble)
            )
        }
        return result
    }

    /// Decodes the leading `uint256` word returned by an EVM `eth_call`.
    ///
    /// Most ERC-20 contracts return exactly one 32-byte word for
    /// `balanceOf`. A small set of deployed proxy tokens, including legacy
    /// Venus vTokens, return the requested balance as the first word with
    /// additional ABI words appended. Those bytes are valid call output, but
    /// they are not a JSON-RPC quantity and must not be sent through the
    /// stricter quantity decoder above.
    static func decimalFromABIUnsignedInteger(
        _ value: String
    ) throws -> String {
        guard value.hasPrefix("0x") else {
            throw SendTransactionSubmissionError.provider(
                networkID: "evm",
                code: "invalid_abi_uint256",
                message: value
            )
        }
        let digits = value.dropFirst(2)
        guard digits.count >= 64,
              digits.count.isMultiple(of: 64),
              digits.count <= 2_048,
              digits.allSatisfy(\.isHexDigit)
        else {
            throw SendTransactionSubmissionError.provider(
                networkID: "evm",
                code: "invalid_abi_uint256",
                message: value
            )
        }
        return try decimalFromHexQuantity(
            "0x" + String(digits.prefix(64))
        )
    }

    static func hexQuantity(_ value: String) throws -> String {
        let data = try bigEndianData(value)
        if data.isEmpty { return "0x0" }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let trimmed = hex.drop(while: { $0 == "0" })
        return "0x" + (trimmed.isEmpty ? "0" : String(trimmed))
    }

    static func fixedWidthData(
        _ value: String,
        byteCount: Int
    ) throws -> Data {
        let data = try bigEndianData(value)
        guard data.count <= byteCount else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return Data(repeating: 0, count: byteCount - data.count) + data
    }

    static func isCanonical(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 200
            && value.allSatisfy { $0 >= "0" && $0 <= "9" }
            && (value == "0" || value.first != "0")
    }

    private static func canonical(_ value: String) -> String {
        let trimmed = value.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private static func divide(
        _ value: String,
        by divisor: Int
    ) -> (quotient: String, remainder: Int) {
        var quotient: [UInt8] = []
        var remainder = 0
        for byte in value.utf8 {
            let combined = remainder * 10 + Int(byte - 48)
            let digit = combined / divisor
            remainder = combined % divisor
            if !quotient.isEmpty || digit > 0 {
                quotient.append(UInt8(digit) + 48)
            }
        }
        return (
            quotient.isEmpty
                ? "0"
                : String(decoding: quotient, as: UTF8.self),
            remainder
        )
    }
}

/// Resolves the exact native-coin amount that can leave an account after all
/// chain-required fees, reserves, liabilities, and storage deposits are kept.
/// Values remain base-10 integer text so 128- and 256-bit chains never pass
/// through binary floating point.
enum SendNativeTransferAmountResolver {
    static func resolve(
        requestedAtomic: String,
        balanceAtomic: String,
        unavailableAtomic: String,
        usesMaximumBalance: Bool
    ) throws -> String {
        guard SendAtomicAmount.isCanonical(requestedAtomic),
              SendAtomicAmount.isCanonical(balanceAtomic),
              SendAtomicAmount.isCanonical(unavailableAtomic)
        else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        guard SendAtomicAmount.compare(
            balanceAtomic,
            unavailableAtomic
        ) == .orderedDescending else {
            throw SendTransactionSubmissionError
                .insufficientNetworkFeeBalance
        }
        let available = try SendAtomicAmount.subtract(
            balanceAtomic,
            unavailableAtomic
        )
        // Native fees are paid from the wallet's total balance. Preserve the
        // requested amount when it fits; otherwise deduct only the shortfall.
        let amount = usesMaximumBalance
            || SendAtomicAmount.compare(requestedAtomic, available) == .orderedDescending
            ? available : requestedAtomic
        guard amount != "0" else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        guard SendAtomicAmount.compare(
            amount,
            available
        ) != .orderedDescending else {
            throw SendTransactionSubmissionError
                .insufficientAssetBalance
        }
        return amount
    }

    static func uint64(
        requestedAtomic: UInt64,
        balanceAtomic: UInt64,
        unavailableAtomic: UInt64,
        usesMaximumBalance: Bool
    ) throws -> UInt64 {
        try SendAtomicAmount.uint64(
            resolve(
                requestedAtomic: String(requestedAtomic),
                balanceAtomic: String(balanceAtomic),
                unavailableAtomic: String(unavailableAtomic),
                usesMaximumBalance: usesMaximumBalance
            )
        )
    }

    static func int64(
        requestedAtomic: Int64,
        balanceAtomic: Int64,
        unavailableAtomic: Int64,
        usesMaximumBalance: Bool
    ) throws -> Int64 {
        guard requestedAtomic >= 0,
              balanceAtomic >= 0,
              unavailableAtomic >= 0
        else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return try SendAtomicAmount.int64(
            resolve(
                requestedAtomic: String(requestedAtomic),
                balanceAtomic: String(balanceAtomic),
                unavailableAtomic: String(unavailableAtomic),
                usesMaximumBalance: usesMaximumBalance
            )
        )
    }
}
