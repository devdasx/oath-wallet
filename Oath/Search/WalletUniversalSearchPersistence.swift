import Foundation
import GRDB

struct WalletUniversalSearchDatabaseDependencies:
    Hashable,
    Sendable
{
    let wallets: [ManagedWallet]
    let unitUSDPricesByAssetID: [String: Decimal]

    static let empty = WalletUniversalSearchDatabaseDependencies(
        wallets: [],
        unitUSDPricesByAssetID: [:]
    )

    static func == (
        lhs: WalletUniversalSearchDatabaseDependencies,
        rhs: WalletUniversalSearchDatabaseDependencies
    ) -> Bool {
        lhs.wallets == rhs.wallets
            && lhs.unitUSDPricesByAssetID
                == rhs.unitUSDPricesByAssetID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(wallets)
        for assetID in unitUSDPricesByAssetID.keys.sorted() {
            hasher.combine(assetID)
            hasher.combine(unitUSDPricesByAssetID[assetID])
        }
    }
}

extension WalletDatabase {
    func universalSearchDatabaseDependencies(
        assetIDs: [String]
    ) -> AsyncValueObservation<
        WalletUniversalSearchDatabaseDependencies
    > {
        let observedAssetIDs = Array(Set(assetIDs)).sorted()
        let observation = ValueObservation.tracking { database in
            WalletUniversalSearchDatabaseDependencies(
                wallets: try Self.managedWallets(
                    database: database
                ),
                unitUSDPricesByAssetID:
                    try Self.latestUniversalSearchUSDPrices(
                        assetIDs: observedAssetIDs,
                        database: database
                    )
            )
        }
        return observation.values(
            in: pool,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    func universalSearchTransactions(
        matching rawQuery: String,
        resultLimit: Int = 100
    ) async throws -> [WalletTransaction] {
        guard
            let matchQuery = Self.universalSearchFTSQuery(rawQuery),
            resultLimit > 0
        else {
            return []
        }

        return try await pool.read { database in
            let accountIDs = try String.fetchAll(
                database,
                sql: """
                SELECT walletAccounts.id
                FROM walletAccounts
                JOIN wallets
                    ON wallets.id = walletAccounts.walletID
                WHERE wallets.profileID = ?
                  AND wallets.isSelected = 1
                  AND wallets.archivedAt IS NULL
                  AND walletAccounts.isEnabled = 1
                """,
                arguments: [Self.defaultProfileID]
            )
            guard !accountIDs.isEmpty else { return [] }

            let candidateLimit = min(max(resultLimit * 5, 100), 1_000)
            let placeholders = Array(
                repeating: "?",
                count: accountIDs.count
            )
            .joined(separator: ", ")
            var arguments = StatementArguments()
            arguments += [matchQuery]
            arguments += StatementArguments(accountIDs)
            arguments += [candidateLimit]

            let transactionIDs = try String.fetchAll(
                database,
                sql: """
                SELECT transactionID
                FROM transactionSearchIndex
                WHERE transactionSearchIndex MATCH ?
                  AND accountID IN (\(placeholders))
                ORDER BY rank
                LIMIT ?
                """,
                arguments: arguments
            )
            guard !transactionIDs.isEmpty else { return [] }

            let records = try DBTransactionRecord
                .filter(transactionIDs.contains(Column("id")))
                .fetchAll(database)
            let recordByID = Dictionary(
                uniqueKeysWithValues: records.map { ($0.id, $0) }
            )
            let orderedRecords = transactionIDs.compactMap {
                recordByID[$0]
            }

            let assetIDs = Array(
                Set(orderedRecords.compactMap(\.assetID))
            )
            let assets = assetIDs.isEmpty
                ? []
                : try DBAssetRecord
                    .filter(assetIDs.contains(Column("id")))
                    .fetchAll(database)
            let assetsByID = Dictionary(
                uniqueKeysWithValues: assets.map { ($0.id, $0) }
            )

            let networkIDs = Array(
                Set(orderedRecords.map(\.networkID))
            )
            let networks = try DBNetworkRecord
                .filter(networkIDs.contains(Column("id")))
                .fetchAll(database)
            let networksByID = Dictionary(
                uniqueKeysWithValues: networks.map { ($0.id, $0) }
            )

            let notes = try DBTransactionNoteRecord
                .filter(
                    transactionIDs.contains(Column("transactionID"))
                )
                .fetchAll(database)
            let notesByTransactionID = Dictionary(
                uniqueKeysWithValues: notes.map {
                    ($0.transactionID, $0.note)
                }
            )

            let transfers = try DBTransactionTransferRecord
                .filter(
                    transactionIDs.contains(Column("transactionID"))
                )
                .fetchAll(database)
            let primaryTransferByTransactionID = Dictionary(
                uniqueKeysWithValues: transfers.compactMap {
                    transfer
                        -> (String, DBTransactionTransferRecord)? in
                    guard
                        transfer.id
                            == "\(transfer.transactionID)|primary"
                    else {
                        return nil
                    }
                    return (transfer.transactionID, transfer)
                }
            )

            let unitPricesByAssetID = try Self
                .latestUniversalSearchUSDPrices(
                    assetIDs: assetIDs,
                    database: database
                )

            var results: [WalletTransaction] = []
            results.reserveCapacity(
                min(resultLimit, orderedRecords.count)
            )
            for storedRecord in orderedRecords {
                let record = Self.transactionByApplyingCachedUSDPrice(
                    storedRecord,
                    unitUSDPricesByAssetID: unitPricesByAssetID
                )
                guard
                    Self.isDisplayEligibleTransaction(
                        record,
                        assetsByID: assetsByID
                    ),
                    let transaction = Self.walletTransaction(
                        record,
                        assetsByID: assetsByID,
                        networkByID: networksByID,
                        localNote: notesByTransactionID[record.id],
                        primaryTransfer:
                            primaryTransferByTransactionID[record.id]
                    ),
                    WalletTransactionVisibilityPolicy.includes(
                        transaction
                    )
                else {
                    continue
                }
                results.append(transaction)
                if results.count == resultLimit {
                    break
                }
            }
            return results
        }
    }

    nonisolated static func universalSearchFTSQuery(
        _ rawQuery: String
    ) -> String? {
        let normalized = rawQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
        let terms = normalized.split {
            !$0.isLetter && !$0.isNumber
        }
        .prefix(12)
        .map(String.init)
        .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }

        return terms.map { term in
            let escaped = term.replacingOccurrences(
                of: "\"",
                with: "\"\""
            )
            return "\"\(escaped)\"*"
        }
        .joined(separator: " AND ")
    }

    private static func latestUniversalSearchUSDPrices(
        assetIDs: [String],
        database: Database
    ) throws -> [String: Decimal] {
        guard !assetIDs.isEmpty else { return [:] }
        let priceRecords = try DBAssetPriceRecord
            .filter(assetIDs.contains(Column("assetID")))
            .filter(Column("quoteCurrency") == "USD")
            .order(Column("observedAt").desc)
            .fetchAll(database)
        let assetsByID = Dictionary(
            uniqueKeysWithValues: try DBAssetRecord
                .filter(assetIDs.contains(Column("id")))
                .fetchAll(database)
                .map { ($0.id, $0) }
        )

        var prices: [String: Decimal] = [:]
        prices.reserveCapacity(assetIDs.count)
        for record in priceRecords where prices[record.assetID] == nil {
            guard
                let asset = assetsByID[record.assetID],
                AssetPriceClient.cachedPriceIsReusable(record, for: asset),
                let price = decimal(record.price),
                price > 0
            else {
                continue
            }
            prices[record.assetID] = price
        }
        return prices
    }
}
