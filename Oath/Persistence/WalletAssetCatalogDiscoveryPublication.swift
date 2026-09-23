import Foundation
import GRDB

extension WalletAssetCatalogPersistence {
    private struct DiscoveredTokenCandidate: Decodable, FetchableRecord {
        let networkID: String
        let contractAddress: String
        let normalizedContractAddress: String
        let name: String
        let symbol: String
        let decimals: Int?
        let balance: String
        let balanceAtomic: String?
    }

    private static let communityPublicationNetworkIDs: Set<String> = [
        "eth", "bsc", "arbitrum", "base", "polygon", "optimism",
        "avalanche", "gnosis", "linea", "scroll", "taiko", "telos",
        "xlayer", "arc", "solana", "tron", "ton", "sui", "near", "xrp",
        "aptos", "stellar",
    ]

    /// Adds provider-discovered, held tokens to the durable publication
    /// outbox. Existing rows are never rewritten so a provider outage cannot
    /// reset the retry backoff on every wallet refresh.
    static func enqueueDiscoveredHeldTokenPublications(
        in database: Database,
        now: Double = Date().timeIntervalSince1970
    ) throws {
        let knownIdentities = Set(
            try String.fetchAll(
                database,
                sql: "SELECT assetIdentity FROM assetCatalogEntries"
            ).map(AssetIdentityKey.canonical)
        )
        let candidates = try DiscoveredTokenCandidate.fetchAll(
            database,
            sql: """
            SELECT
                asset.networkID,
                asset.contractAddress,
                asset.normalizedContractAddress,
                asset.name,
                asset.symbol,
                asset.decimals,
                holding.balance,
                holding.balanceAtomic
            FROM assets AS asset
            JOIN accountAssets AS holding
              ON holding.assetID = asset.id
            JOIN walletAccounts AS account
              ON account.id = holding.accountID
            JOIN networks AS network
              ON network.id = asset.networkID
            WHERE asset.assetType = ?
              AND asset.isSpam = 0
              AND holding.isEnabled = 1
              AND account.isEnabled = 1
              AND network.isMainnet = 1
              AND network.isEnabled = 1
            ORDER BY asset.networkID, asset.id
            """,
            arguments: [DatabaseAssetType.fungibleToken.rawValue]
        )

        var queuedIdentities = Set<String>()
        for candidate in candidates {
            let networkID = candidate.networkID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let storedContract = candidate.contractAddress
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedContract = candidate.normalizedContractAddress
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let contractAddress = storedContract.isEmpty
                ? normalizedContract
                : storedContract
            let identity = AssetIdentityKey.canonical(
                AssetIdentityKey.make(
                    networkID: networkID,
                    contractAddress: contractAddress
                )
            )
            guard
                communityPublicationNetworkIDs.contains(networkID),
                !contractAddress.isEmpty,
                contractAddress.count <= 600,
                !knownIdentities.contains(identity),
                queuedIdentities.insert(identity).inserted,
                !TokenSafetyPolicy.isHardDenied(
                    networkID: networkID,
                    contractAddress: contractAddress
                ),
                let decimals = candidate.decimals,
                (0...255).contains(decimals),
                AssetCatalogEntryValidation.isValidRemoteText(
                    candidate.name,
                    maximumLength: 160
                ),
                AssetCatalogEntryValidation.isValidRemoteText(
                    candidate.symbol,
                    maximumLength: 48
                ),
                !candidate.symbol.contains(where: { $0.isWhitespace }),
                isStrictlyPositiveBase10(
                    candidate.balanceAtomic ?? candidate.balance
                )
            else {
                continue
            }

            try database.execute(
                sql: """
                INSERT INTO assetCatalogPublicationOutbox (
                    assetIdentity, networkID, contractAddress, name, symbol,
                    decimals, attemptCount, nextAttemptAt, lastErrorCode,
                    createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, 0, ?, NULL, ?, ?)
                ON CONFLICT(assetIdentity) DO NOTHING
                """,
                arguments: [
                    identity,
                    networkID,
                    contractAddress,
                    candidate.name,
                    candidate.symbol,
                    decimals,
                    now,
                    now,
                    now,
                ]
            )
        }
    }

    private static func isStrictlyPositiveBase10(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty, value.count <= 1_024 else { return false }

        var sawDigit = false
        var sawNonzeroDigit = false
        var sawDecimalSeparator = false
        for character in value {
            if character == "." {
                guard !sawDecimalSeparator else { return false }
                sawDecimalSeparator = true
                continue
            }
            guard character.isASCII, character.isNumber else { return false }
            sawDigit = true
            if character != "0" { sawNonzeroDigit = true }
        }
        return sawDigit && sawNonzeroDigit
    }
}
