import Foundation

/// One ordering policy for holdings and asset choices. USD values are comparable
/// across coins and do not change order when the display currency or FX cache
/// changes. Unknown valuations have no monetary rank; token units are never
/// compared across different assets.
public struct AssetSortKey: Sendable, Equatable, Comparable {
    private let value: Decimal
    private let transactions: Int
    private let name: String
    private let identity: String

    public init(balanceUSD: Decimal? = nil, transactionCount: Int = 0, name: String, identity: String) {
        value = balanceUSD.map { !$0.isNaN && $0 > 0 ? $0 : 0 } ?? 0
        transactions = max(0, transactionCount)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        self.identity = identity
    }

    /// Less-than means earlier in the list: value/count descending, name/ID ascending.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        if lhs.transactions != rhs.transactions { return lhs.transactions > rhs.transactions }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.identity < rhs.identity
    }

    func named(_ name: String, identity: String) -> Self {
        Self(balanceUSD: value, transactionCount: transactions, name: name, identity: identity)
    }
}

public enum AssetOrdering {
    /// Compute prices and normalized names once per item, not per comparison.
    public static func sorted<Element>(_ values: [Element], by key: (Element) -> AssetSortKey) -> [Element] {
        let keyed: [(offset: Int, value: Element, key: AssetSortKey)] = values.enumerated().map { entry in
            (offset: entry.offset, value: entry.element, key: key(entry.element))
        }
        let ordered = keyed.sorted { lhs, rhs in
            lhs.key == rhs.key ? lhs.offset < rhs.offset : lhs.key < rhs.key
        }
        return ordered.map { $0.value }
    }
}

/// Reuses the wallet's ranks in receive, contract lookup and other asset
/// choices. Account-specific choices use that account; network-wide choices
/// use its highest-ranked holding. Absent assets use the same name/ID fallback.
public struct PortfolioAssetOrder: Sendable {
    private var byAsset: [String: AssetSortKey] = [:]
    private var byAccount: [String: AssetSortKey] = [:]

    public init(_ holdings: [Holding]) {
        for holding in holdings {
            let asset = holding.networkID + ":" + holding.reference
            let key = holding.sortKey
            if byAsset[asset].map({ key < $0 }) ?? true { byAsset[asset] = key }
            byAccount[holding.accountID + ":" + asset] = key
        }
    }

    public func key(networkID: String, reference: String = "native", accountID: String? = nil, name: String) -> AssetSortKey {
        let asset = networkID + ":" + reference
        let key: AssetSortKey?
        if let accountID { key = byAccount[accountID + ":" + asset] }
        else { key = byAsset[asset] }
        let identity = asset + ":" + (accountID ?? "")
        return key?.named(name, identity: identity) ?? AssetSortKey(name: name, identity: identity)
    }
}
