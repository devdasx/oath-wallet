import Foundation
import WalletCore

enum SuiCoinType {
    private static let zeroAccountAddress =
        "0x" + String(repeating: "0", count: 64)

    static func canonical(_ value: String) -> String? {
        let components = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "::", omittingEmptySubsequences: false)
        guard components.count == 3,
              let address = canonicalAddress(String(components[0])),
              isMoveIdentifier(String(components[1])),
              isMoveIdentifier(String(components[2]))
        else {
            return nil
        }
        return "\(address)::\(components[1])::\(components[2])"
    }

    static func canonicalAddress(_ value: String) -> String? {
        var hexadecimal = value.lowercased()
        if hexadecimal.hasPrefix("0x") {
            hexadecimal.removeFirst(2)
        }
        guard (1...64).contains(hexadecimal.count),
              hexadecimal.allSatisfy(\.isHexDigit)
        else {
            return nil
        }
        hexadecimal = String(hexadecimal.drop { $0 == "0" })
        return "0x" + (hexadecimal.isEmpty ? "0" : hexadecimal)
    }

    static func canonicalAccountAddress(_ value: String) -> String? {
        guard let compact = canonicalAddress(value) else { return nil }
        let hexadecimal = String(compact.dropFirst(2))
        return "0x" + String(repeating: "0", count: 64 - hexadecimal.count)
            + hexadecimal
    }

    static func validatedAccountAddress(_ value: String) -> String? {
        guard let canonical = canonicalAccountAddress(value),
              canonical != zeroAccountAddress,
              CoinType.sui.validate(address: canonical)
        else {
            return nil
        }
        return canonical
    }

    static func assetID(_ coinType: String) -> String? {
        guard let canonical = canonical(coinType) else { return nil }
        return canonical == SuiConstants.nativeCoinType
            ? SuiConstants.nativeAssetID
            : "sui:\(canonical)"
    }

    private static func isMoveIdentifier(_ value: String) -> Bool {
        guard let first = value.first,
              first == "_" || first.isASCII && first.isLetter
        else {
            return false
        }
        return value.allSatisfy {
            $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber))
        }
    }
}
