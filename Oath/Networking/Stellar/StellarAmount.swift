import Foundation

enum StellarAmount {
    static func atomicUnits(
        userUnits: String,
        decimals: Int = StellarConstants.decimals
    ) throws -> String {
        let normalized = userUnits.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty, !normalized.hasPrefix("-"),
              normalized.filter({ $0 == "." }).count <= 1
        else { throw StellarProviderError.invalidResponse("amount") }
        let pieces = normalized.split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard pieces.count <= 2,
              pieces.allSatisfy({ piece in
                  piece.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
              })
        else { throw StellarProviderError.invalidResponse("amount") }
        let whole = pieces.first.map(String.init) ?? "0"
        let fraction = pieces.count == 2 ? String(pieces[1]) : ""
        guard fraction.count <= decimals else {
            throw StellarProviderError.invalidResponse("precision")
        }
        let digits = whole + fraction
            + String(repeating: "0", count: decimals - fraction.count)
        return canonicalInteger(digits)
    }

    static func userUnits(
        atomic: String,
        decimals: Int = StellarConstants.decimals
    ) throws -> String {
        guard let canonical = ExactDecimalText.canonicalUnsignedInteger(
            atomic
        ) else { throw StellarProviderError.invalidResponse("atomic") }
        if decimals == 0 { return canonical }
        let padded = canonical.count <= decimals
            ? String(repeating: "0", count: decimals + 1 - canonical.count)
                + canonical
            : canonical
        let split = padded.index(padded.endIndex, offsetBy: -decimals)
        let whole = String(padded[..<split])
        let fraction = String(padded[split...])
            .replacingOccurrences(
                of: "0+$",
                with: "",
                options: .regularExpression
            )
        return fraction.isEmpty ? whole : "\(whole).\(fraction)"
    }

    static func signedUserUnits(
        amount: String,
        outgoing: Bool
    ) throws -> String {
        let canonical = try userUnits(
            atomic: atomicUnits(userUnits: amount)
        )
        return outgoing && canonical != "0" ? "-\(canonical)" : canonical
    }

    static func canonicalInteger(_ value: String) -> String {
        let trimmed = value.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }
}
