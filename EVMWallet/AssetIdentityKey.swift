import Foundation

enum AssetIdentityKey {
    static func make(
        networkID: String,
        contractAddress: String?
    ) -> String {
        let normalizedNetworkID = networkID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let contractAddress else {
            return "\(normalizedNetworkID):native"
        }
        let trimmedContract = contractAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let canonicalContract = normalizedContract(
            trimmedContract,
            networkID: normalizedNetworkID
        )
        return "\(normalizedNetworkID):\(canonicalContract)"
    }

    static func canonical(_ assetIdentity: String) -> String {
        let trimmed = assetIdentity.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let separator = trimmed.firstIndex(of: ":") else {
            return trimmed.lowercased()
        }
        let networkID = String(trimmed[..<separator])
        let contract = String(
            trimmed[trimmed.index(after: separator)...]
        )
        if contract.caseInsensitiveCompare("native") == .orderedSame {
            return make(networkID: networkID, contractAddress: nil)
        }
        return make(
            networkID: networkID,
            contractAddress: contract
        )
    }

    static func contractAddress(
        from assetIdentity: String
    ) -> String? {
        let trimmed = assetIdentity.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            let separator = trimmed.firstIndex(of: ":"),
            separator < trimmed.index(before: trimmed.endIndex)
        else {
            return nil
        }
        let contract = String(
            trimmed[trimmed.index(after: separator)...]
        )
        guard
            !contract.isEmpty,
            contract.caseInsensitiveCompare("native") != .orderedSame
        else {
            return nil
        }
        return contract
    }

    private static func normalizedContract(
        _ contract: String,
        networkID: String
    ) -> String {
        switch networkID {
        case SolanaConstants.networkID, "tron":
            contract
        case StellarConstants.networkID:
            StellarAssetIdentity.validated(contractAddress: contract)?
                .contractAddress ?? contract
        case SuiConstants.networkID:
            SuiCoinType.canonical(contract) ?? contract
        case AptosConstants.networkID:
            AptosAssetType.canonical(contract) ?? contract
        case XRPConstants.networkID:
            XRPTokenCatalog.canonicalIdentity(contract) ?? contract
        default:
            contract.lowercased()
        }
    }
}
