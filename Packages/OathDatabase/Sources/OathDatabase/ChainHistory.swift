import Foundation
import GRDB

/// Historical assets remain readable even when they have no current balance.
public struct ChainHistoryItem: Sendable, Equatable, Identifiable {
    public let entry: HistoryEntry
    public let holding: Holding
    public var id: String { entry.id }

    public init(entry: HistoryEntry, holding: Holding) {
        self.entry = entry
        self.holding = holding
    }
}

extension OathDatabase {
    public func chainHistory(walletID: String, networkID: String? = nil,
                             accountID: String? = nil, assetID: String? = nil, currency: String,
                             before: HistoryCursor? = nil, limit: Int = 50, search: String = "", filter: HistoryFilter = .init(),
                             localeIdentifier: String = Locale.autoupdatingCurrent.identifier) async throws -> [ChainHistoryItem] {
        try await pool.read {
            try Self.readChainHistory($0, walletID: walletID, networkID: networkID, accountID: accountID, assetID: assetID, currency: currency,
                                      before: before, limit: Self.pageSize(limit), search: search, filter: filter, localeIdentifier: localeIdentifier)
        }
    }

    /// Grow the visible window without losing live updates to earlier pages.
    public func observeChainHistory(walletID: String, networkID: String? = nil,
                                    accountID: String? = nil, assetID: String? = nil, currency: String,
                                    limit: Int = 51, search: String = "", filter: HistoryFilter = .init(),
                                    localeIdentifier: String = Locale.autoupdatingCurrent.identifier) -> AsyncThrowingStream<[ChainHistoryItem], Error> {
        stream {
            try Self.readChainHistory($0, walletID: walletID, networkID: networkID, accountID: accountID, assetID: assetID, currency: currency,
                                      before: nil, limit: max(1, limit), search: search, filter: filter, localeIdentifier: localeIdentifier)
        }
    }

    private static func readChainHistory(_ db: Database, walletID: String, networkID: String?,
                                         accountID: String?, assetID: String?, currency: String,
                                         before: HistoryCursor?, limit: Int, search: String, filter: HistoryFilter,
                                         localeIdentifier: String) throws -> [ChainHistoryItem] {
        guard filter.isValid else { throw StoreError.invalidValue("history filter") }
        var sql = """
            SELECT a.id,a.accountID,a.networkID,a.transactionID,a.assetID,a.direction,
                   a.amountAtomic,a.counterparty,a.sortTimestamp AS timestamp,
                   COALESCE(e.outcome,t.state) AS state,t.hash,
                   s.reference,s.name,s.symbol,s.decimals,
                   CASE WHEN s.reference='native' THEN COALESCE(s.logo,n.logo) ELSE s.logo END AS logo,owner.address,
                   p.value AS usdPrice,p.observedAt AS priceObservedAt,p.source AS priceSource
            FROM visibleActivity a JOIN transactions t ON t.id=a.transactionID
            JOIN accounts owner ON owner.id=a.accountID
            JOIN assets s ON s.id=a.assetID
            JOIN networks n ON n.id=a.networkID
            LEFT JOIN transactionEvidence e ON e.accountID=a.accountID AND e.transactionID=a.transactionID
            LEFT JOIN prices p ON p.assetID=a.assetID AND p.currency='USD'
                AND p.observedAt=(SELECT MAX(observedAt) FROM prices WHERE assetID=a.assetID AND currency='USD')
            WHERE a.walletID=? AND owner.walletID=?
            AND (a.networkID<>'solana' OR EXISTS (SELECT 1 FROM solanaActivity sa WHERE sa.activityID=a.id
                AND sa.owner=COALESCE((SELECT address FROM solanaReceiveAddresses WHERE accountID=a.accountID AND isSelected=1),owner.address)))
            """
        var args: StatementArguments = [walletID, walletID]
        let rate = try Self.exchangeRates(db)?.rate(for: currency) ?? (currency == "USD" ? 1 : nil)
        if let networkID {
            sql += " AND a.networkID=?"
            args += [networkID]
        }
        // Asset View All keeps exactly the preview's account and asset scope,
        // including when searching, paging, and observing background updates.
        if let accountID {
            sql += " AND a.accountID=?"
            args += [accountID]
        }
        if let assetID {
            sql += " AND a.assetID=?"
            args += [assetID]
        }
        func selected(_ values: [String], column: String) {
            guard !values.isEmpty else { return }
            sql += " AND \(column) IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))"
            args += StatementArguments(values.sorted())
        }
        selected(Array(filter.networkIDs), column: "a.networkID")
        selected(Array(filter.assetIDs), column: "a.assetID")
        selected(filter.directions.map(\.rawValue), column: "a.direction")
        selected(filter.statuses.map(\.rawValue), column: "COALESCE(e.outcome,t.state)")
        if let start = filter.startDate {
            sql += " AND a.sortTimestamp>=?"
            args += [start.timeIntervalSince1970]
        }
        if let end = filter.endDate {
            sql += " AND a.sortTimestamp<? AND a.sortTimestamp>0"
            args += [end.timeIntervalSince1970]
        }
        if filter.minimumAmount != nil || filter.maximumAmount != nil {
            sql += " AND oath_history_amount_in_range(a.amountAtomic,s.decimals,?,?)"
            args += [filter.minimumAmount, filter.maximumAmount]
        }
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Search the entire wallet/chain BEFORE LIMIT. Transfers include all
            // senders/recipients, not only the representative counterparty.
            sql += "\n" + """
                AND oath_history_matches(
                    s.name || ' ' || s.symbol || ' ' || s.reference || ' ' || n.name || ' ' || a.networkID || ' ' ||
                    t.hash || ' ' || a.direction || ' ' || COALESCE(e.outcome,t.state) || ' ' ||
                    COALESCE(a.counterparty,'') || ' ' || owner.address || ' ' ||
                    COALESCE((SELECT group_concat(fromAddress || ' ' || toAddress,' ') FROM transfers tr
                              WHERE tr.transactionID=a.transactionID AND tr.assetID=a.assetID),'') || ' ' ||
                    COALESCE((SELECT group_concat(address,' ') FROM transactionParticipants tp
                              WHERE tp.accountID=a.accountID AND tp.transactionID=a.transactionID),''),
                    a.amountAtomic,s.decimals,p.value,?,?,?,?)
                """
            args += [rate.map { NSDecimalNumber(decimal: $0).stringValue }, currency, localeIdentifier, search]
        }
        if let before {
            sql += " AND (a.sortTimestamp,a.id) < (?,?)"
            args += [before.timestamp, before.id]
        }
        sql += " ORDER BY a.sortTimestamp DESC,a.id DESC LIMIT ?"
        args += [limit]
        return try Row.fetchAll(db, sql: sql, arguments: args).map { row in
            let entry = try HistoryEntry(row: row)
            let holding = Holding(accountID: entry.accountID, networkID: entry.networkID, address: row["address"],
                assetID: entry.assetID, reference: row["reference"], name: row["name"], symbol: row["symbol"],
                decimals: row["decimals"], logo: row["logo"], amountAtomic: nil, balanceObservedAt: nil,
                usdPrice: row["usdPrice"], exchangeRate: rate.map { NSDecimalNumber(decimal: $0).stringValue },
                priceObservedAt: row["priceObservedAt"], priceSource: row["priceSource"], transactionCount: 0)
            return ChainHistoryItem(entry: entry, holding: holding)
        }
    }
}
