import Foundation

enum AptosAssetType {
    static func canonical(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let address = AptosAddress.canonical(trimmed) {
            return compactAddress(address)
        }
        let parts = trimmed.split(
            separator: "::",
            omittingEmptySubsequences: false
        )
        guard parts.count == 3,
              let address = AptosAddress.canonical(String(parts[0])),
              validIdentifier(String(parts[1])),
              validIdentifier(String(parts[2]))
        else { return nil }
        return "\(compactAddress(address))::\(parts[1])::\(parts[2])"
    }

    static func assetID(_ assetType: String) -> String? {
        guard let canonical = canonical(assetType) else { return nil }
        return canonical == AptosConstants.nativeCoinType
            || canonical == AptosConstants.nativeMetadataAddress
            ? AptosConstants.nativeAssetID
            : "aptos:\(canonical)"
    }

    static func compactAddress(_ address: String) -> String {
        var value = String(address.dropFirst(2)).drop { $0 == "0" }
        if value.isEmpty { value = "0" }
        return "0x\(value)"
    }

    private static func validIdentifier(_ value: String) -> Bool {
        guard let first = value.first,
              first == "_" || first.isASCII && first.isLetter
        else { return false }
        return value.allSatisfy {
            $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber))
        }
    }
}
