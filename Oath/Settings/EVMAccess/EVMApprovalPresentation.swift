import Foundation

extension EVMOnChainApproval {
    private static let maximumUInt256 =
        "115792089237316195423570985008687907853269984665640564039457584007913129639935"

    var displayName: String {
        let trimmedName = tokenName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }
        let trimmedSymbol = tokenSymbol?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedSymbol, !trimmedSymbol.isEmpty {
            return trimmedSymbol
        }
        return EVMApprovalPresentation.shortAddress(contractAddress)
    }

    var networkName: String {
        ReceiveNetworkCatalog.network(for: networkID)?.localizedName
            ?? networkID.uppercased()
    }

    var logoSource: AssetLogoSource {
        ReceiveAssetCatalog.variant(
            networkID: networkID,
            contractAddress: contractAddress
        )?.logoSource ?? .unavailable
    }

    var kindLocalizationKey: String {
        switch kind {
        case .tokenAllowance:
            "evm_access.permission.allowance"
        case .nftToken:
            "evm_access.permission.nft"
        case .operatorAccess:
            "evm_access.permission.operator"
        }
    }

    var valueText: String? {
        switch kind {
        case .tokenAllowance:
            guard let amountAtomic else { return nil }
            if amountAtomic == Self.maximumUInt256 {
                return WalletLocalization.string(
                    "evm_access.permission.unlimited"
                )
            }
            let units = SendDecimalAmount.userUnits(
                fromAtomicUnits: amountAtomic,
                decimals: decimals ?? 0
            )
            guard let decimal = Decimal(
                string: units,
                locale: Locale(identifier: "en_US_POSIX")
            ) else {
                return units
            }
            let formatted = EnglishNumbers.decimal(
                decimal,
                maximumFractionDigits: min(max(decimals ?? 0, 0), 18)
            )
            if let symbol = tokenSymbol, !symbol.isEmpty {
                return "\(formatted) \(symbol)"
            }
            return formatted
        case .nftToken:
            guard let tokenID else { return nil }
            return EnglishNumbers.localized(
                "evm_access.permission.token_id_value",
                tokenID as NSString
            )
        case .operatorAccess:
            return nil
        }
    }
}

enum EVMApprovalPresentation {
    static func shortAddress(_ address: String) -> String {
        guard address.count > 14 else { return address }
        return "\(address.prefix(8))…\(address.suffix(6))"
    }
}
