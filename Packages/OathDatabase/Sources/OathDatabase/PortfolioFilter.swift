import Foundation
import GRDB

/// Per-wallet visibility and presentation preferences. OR within the network
/// selection, AND between categories. Sort/range/category filters only project
/// rows; token verification visibility also controls discovery and the snapshot.
/// These preferences never grant contract approval or token verification.
/// Empty results and form validation are expected
/// UI states, not diagnostics failures; the snapshot owner reports read errors.
public struct PortfolioFilter: Codable, Equatable, Sendable {
    public enum Sort: String, Codable, CaseIterable, Sendable {
        case recommended, highestValue, lowestValue, nameAscending, nameDescending, mostActive
    }
    public enum Kind: String, Codable, CaseIterable, Sendable { case all, coins, tokens }

    public var sort: Sort = .recommended
    public var kind: Kind = .all
    /// Empty means every network, including networks discovered on refresh.
    public var networkIDs: Set<String> = []
    public var hidesZeroBalances = false
    /// Inventory visibility is enforced by the database and provider sync.
    /// Turning this off does not mark any token as verified.
    public var hidesUnverifiedTokens = true
    public var onlyWithActivity = false
    public var groupsTokensByChain = false
    public var minimumValue: Decimal?
    public var maximumValue: Decimal?
    public var rangeCurrency: String?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case sort, kind, networkIDs, hidesZeroBalances, hidesUnverifiedTokens, onlyWithActivity
        case groupsTokensByChain, minimumValue, maximumValue, rangeCurrency
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sort = try values.decode(Sort.self, forKey: .sort)
        kind = try values.decode(Kind.self, forKey: .kind)
        networkIDs = try values.decode(Set<String>.self, forKey: .networkIDs)
        hidesZeroBalances = try values.decode(Bool.self, forKey: .hidesZeroBalances)
        hidesUnverifiedTokens = try values.decode(Bool.self, forKey: .hidesUnverifiedTokens)
        onlyWithActivity = try values.decode(Bool.self, forKey: .onlyWithActivity)
        // Existing saved filters retain their flat presentation after upgrading.
        groupsTokensByChain = try values.decodeIfPresent(Bool.self, forKey: .groupsTokensByChain) ?? false
        minimumValue = try values.decodeIfPresent(Decimal.self, forKey: .minimumValue)
        maximumValue = try values.decodeIfPresent(Decimal.self, forKey: .maximumValue)
        rangeCurrency = try values.decodeIfPresent(String.self, forKey: .rangeCurrency)
    }

    public var activeCount: Int {
        [sort != .recommended, kind != .all, !networkIDs.isEmpty,
         hidesZeroBalances, !hidesUnverifiedTokens, onlyWithActivity, minimumValue != nil || maximumValue != nil]
            .filter { $0 }.count
    }

    public var isValid: Bool {
        for value in [minimumValue, maximumValue].compactMap({ $0 }) {
            guard !value.isNaN, value >= 0 else { return false }
        }
        if let minimumValue, let maximumValue, minimumValue > maximumValue { return false }
        return (minimumValue == nil && maximumValue == nil) || rangeCurrency?.isEmpty == false
    }

    /// A limit in USD must never silently become the same numeric limit in JPY.
    public func adjusted(for currency: String) -> Self {
        var result = self
        if rangeCurrency != currency {
            result.minimumValue = nil; result.maximumValue = nil; result.rangeCurrency = nil
        }
        return result
    }

    public static func value(_ text: String, locale: Locale) -> Decimal? {
        guard let canonical = HistoryFilter.canonicalAmount(text, locale: locale),
              canonical.filter(\.isNumber).count <= 38,
              let value = Decimal(string: canonical, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN, value >= 0 else { return nil }
        return value
    }

    public func applying(to holdings: [Holding], currency: String, locale: Locale = .current,
                         preservingRecommendedOrder: Bool = false) -> [Holding] {
        let selection = adjusted(for: currency)
        guard selection.isValid else { return [] }
        let visible = holdings.filter { holding in
            guard selection.networkIDs.isEmpty || selection.networkIDs.contains(holding.networkID),
                  selection.kind == .all || (holding.reference == "native" ? selection.kind == .coins : selection.kind == .tokens),
                  !selection.onlyWithActivity || holding.transactionCount > 0 else { return false }
            // Check exact atomic zero: a tiny positive holding must not disappear
            // because display rounding says zero. Missing balances remain visible.
            if selection.hidesZeroBalances, let amount = holding.amountAtomic,
               !amount.isEmpty, amount.allSatisfy({ $0 == "0" }) { return false }
            if selection.minimumValue != nil || selection.maximumValue != nil {
                guard let value = holding.fiatDisplayValue, !value.isNaN, value >= 0 else { return false }
                if let minimum = selection.minimumValue, value < minimum { return false }
                if let maximum = selection.maximumValue, value > maximum { return false }
            }
            return true
        }
        // WalletSnapshot is already ranked on the database reader queue. Its
        // consumers can filter that order without repeating all price parsing.
        if selection.sort == .recommended {
            return preservingRecommendedOrder ? visible : AssetOrdering.sorted(visible, by: \.sortKey)
        }
        // Decorate once. Decimal conversion and localized comparisons must not
        // recreate formatters or query the database for every row/comparison.
        let rows = visible.map { holding in
            (holding: holding,
             value: holding.usdDisplayValue.flatMap { !$0.isNaN && $0 >= 0 ? $0 : nil },
             name: holding.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale))
        }
        return rows.sorted { lhs, rhs in
            switch selection.sort {
            case .highestValue, .lowestValue:
                // Unknown valuations are last in either direction, never zero.
                if lhs.value != rhs.value {
                    guard let left = lhs.value else { return false }
                    guard let right = rhs.value else { return true }
                    return selection.sort == .highestValue ? left > right : left < right
                }
            case .mostActive:
                if lhs.holding.transactionCount != rhs.holding.transactionCount {
                    return lhs.holding.transactionCount > rhs.holding.transactionCount
                }
            default: break
            }
            let nameOrder = lhs.name.compare(rhs.name, options: .numeric, locale: locale)
            if nameOrder != .orderedSame {
                return selection.sort == .nameDescending ? nameOrder == .orderedDescending : nameOrder == .orderedAscending
            }
            return lhs.holding.id < rhs.holding.id
        }.map(\.holding)
    }
}

extension OathDatabase {
    public func portfolioFilter(walletID: String) async throws -> PortfolioFilter {
        try await pool.read { try Self.portfolioFilter($0, walletID: walletID) }
    }

    static func portfolioFilter(_ db: Database, walletID: String) throws -> PortfolioFilter {
        guard let data = try Data.fetchOne(db, sql: "SELECT selection FROM walletPortfolioFilters WHERE walletID=?",
                                          arguments: [walletID]) else { return .init() }
        let value = try JSONDecoder().decode(PortfolioFilter.self, from: data)
        guard value.isValid else { throw StoreError.invalidValue("portfolio filter") }
        return value
    }

    public func savePortfolioFilter(_ selection: PortfolioFilter, walletID: String) async throws {
        guard selection.isValid, selection.networkIDs.count <= 256,
              selection.networkIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            throw StoreError.invalidValue("portfolio filter")
        }
        let data = try JSONEncoder().encode(selection)
        try await pool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM wallets WHERE id=? AND deletedAt IS NULL)",
                                    arguments: [walletID]) == true,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')") == false else {
                throw StoreError.missingRecord
            }
            try db.execute(sql: """
                INSERT INTO walletPortfolioFilters(walletID,selection,hidesUnverifiedTokens) VALUES(?,?,?)
                ON CONFLICT(walletID) DO UPDATE SET selection=excluded.selection,hidesUnverifiedTokens=excluded.hidesUnverifiedTokens
                """, arguments: [walletID, data, selection.hidesUnverifiedTokens])
        }
    }
}
