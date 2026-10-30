import Foundation
import Observation
import OathDatabase
import OathDiagnostics

/// Only visible data invalidates Home's presentation. Provider checkpoints and
/// observation timestamps still reach the session and detail/history screens.
struct OathHomePortfolioInput: Equatable, Sendable {
    let walletID: String?
    let holdings: [Holding]
    let currency: String
    let total: Decimal
    let filter: PortfolioFilter
    let query: String
    let formattingLocale: String
    let sortingLocale: String
    var hiddenAssetIDs: Set<String> = []

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.walletID == rhs.walletID && lhs.currency == rhs.currency && lhs.total == rhs.total &&
        lhs.filter == rhs.filter && lhs.query == rhs.query && lhs.hiddenAssetIDs == rhs.hiddenAssetIDs &&
        lhs.formattingLocale == rhs.formattingLocale && lhs.sortingLocale == rhs.sortingLocale &&
        lhs.holdings.count == rhs.holdings.count &&
        zip(lhs.holdings, rhs.holdings).allSatisfy { $0.hasSameHomeContent(as: $1) }
    }
}

extension Holding {
    fileprivate func hasSameHomeContent(as other: Self) -> Bool {
        accountID == other.accountID && assetID == other.assetID && networkID == other.networkID &&
        address == other.address && reference == other.reference && name == other.name &&
        symbol == other.symbol && decimals == other.decimals && logo == other.logo &&
        amountAtomic == other.amountAtomic && usdPrice == other.usdPrice &&
        exchangeRate == other.exchangeRate && transactionCount == other.transactionCount &&
        pendingTransactionCount == other.pendingTransactionCount
    }
}

struct OathHomeAssetPresentation: Equatable, Identifiable, Sendable {
    let holding: Holding
    let nativeSummary: String
    let nativeFull: String
    let fiat: String
    var id: String { holding.id }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.holding.hasSameHomeContent(as: rhs.holding) && lhs.nativeSummary == rhs.nativeSummary &&
        lhs.nativeFull == rhs.nativeFull && lhs.fiat == rhs.fiat
    }
}

/// Display-only tree, built from already filtered rows. A missing/hidden native
/// asset gets a network heading, never an invented balance or a restored asset.
struct OathHomeAssetTreeEntry: Equatable, Identifiable, Sendable {
    let id: String
    let networkID: String
    let presentation: OathHomeAssetPresentation?
    let isChild: Bool
    let hasChildren: Bool
    let continues: Bool

    static func build(_ rows: [OathHomeAssetPresentation]) -> [Self] {
        struct Group: Hashable { let network: String; let account: String }
        var order: [Group] = []
        var groups: [Group: [OathHomeAssetPresentation]] = [:]
        for row in rows {
            let key = Group(network: row.holding.networkID, account: row.holding.accountID)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(row)
        }
        return order.flatMap { key -> [Self] in
            let values = groups[key] ?? []
            let parents = values.filter { $0.holding.reference == "native" }
            let children = values.filter { $0.holding.reference != "native" }
            var result = parents.map {
                Self(id: $0.id, networkID: key.network, presentation: $0,
                     isChild: false, hasChildren: !children.isEmpty, continues: false)
            }
            if parents.isEmpty, !children.isEmpty {
                result.append(Self(id: "chain-header:" + children[0].id, networkID: key.network,
                                   presentation: nil, isChild: false, hasChildren: true, continues: false))
            }
            result += children.enumerated().map { index, row in
                Self(id: row.id, networkID: key.network, presentation: row,
                     isChild: true, hasChildren: false, continues: index < children.count - 1)
            }
            return result
        }
    }
}

/// This actor performs filtering, Decimal conversion and Foundation formatting
/// away from MainActor. Cache only the current portfolio; never accumulate history.
actor OathHomePortfolioBuilder {
    struct Result: Sendable {
        let rows: [OathHomeAssetPresentation]
        let treeRows: [OathHomeAssetTreeEntry]
        let searchRows: [OathHomeAssetPresentation]
        let total: String
        let formattedRowCount: Int
    }
    private var cache: [String: OathHomeAssetPresentation] = [:]
    private var walletID: String?
    private var currency: String?
    private var locale: String?

    func build(_ input: OathHomePortfolioInput) throws -> Result {
        try Task.checkCancellation()
        let reusable = walletID == input.walletID && currency == input.currency && locale == input.formattingLocale
        let format = OathAssetAmountFormat(locale: Locale(identifier: input.formattingLocale), selectedCurrencyCode: input.currency)
        var next: [String: OathHomeAssetPresentation] = [:]
        next.reserveCapacity(input.holdings.count)
        var formatted = 0
        for holding in input.holdings {
            try Task.checkCancellation()
            if reusable, let previous = cache[holding.id], previous.holding.hasSameHomeContent(as: holding) {
                next[holding.id] = previous
            } else {
                let amounts = OathAssetAmounts(native: holding.nativeDisplayValue, fiat: holding.fiatDisplayValue,
                                               currencyCode: input.currency)
                next[holding.id] = OathHomeAssetPresentation(holding: holding,
                    nativeSummary: format.nativeSummary(amounts.native, ticker: holding.symbol),
                    nativeFull: format.native(amounts.native, ticker: holding.symbol),
                    fiat: String(format.fiat(amounts).characters))
                formatted += 1
            }
        }
        let visibleHoldings = input.holdings.filter { !input.hiddenAssetIDs.contains($0.assetID) }
        let rows = input.filter.applying(to: visibleHoldings, currency: input.currency,
            locale: Locale(identifier: input.sortingLocale), preservingRecommendedOrder: true)
        let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerQuery = query.lowercased()
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let search = query.isEmpty ? input.holdings : input.holdings.filter {
            let text = $0.name + " " + $0.symbol + " " + $0.networkID
            return words.allSatisfy { text.localizedStandardContains($0) } ||
            ($0.networkID == "arc" && $0.reference == "native" && lowerQuery == "0x3600000000000000000000000000000000000000") ||
            ($0.reference != "native" && ($0.reference == query ||
                (OathImportChain(rawValue: $0.networkID)?.isEVM == true && $0.reference.lowercased() == lowerQuery)))
        }
        try Task.checkCancellation()
        cache = next; walletID = input.walletID; currency = input.currency; locale = input.formattingLocale
        let presented = rows.compactMap { next[$0.id] }
        return Result(rows: presented,
            treeRows: input.filter.groupsTokensByChain ? OathHomeAssetTreeEntry.build(presented) : [],
            searchRows: search.compactMap { next[$0.id] },
            total: String(format.fiat(.init(native: nil, fiat: input.total, currencyCode: input.currency)).characters),
            formattedRowCount: formatted)
    }
}

/// A bounded first page from the native SQL index, ready before Home is revealed.
/// It contains display metadata only, never credentials or signing material.
struct OathHomeHistorySnapshot {
    let walletID: String
    let currency: String
    let localeIdentifier: String
    let items: [ChainHistoryItem]
}

@MainActor @Observable
final class OathHomePortfolioModel {
    struct Prepared: Sendable {
        fileprivate let epoch: UUID
        fileprivate let input: OathHomePortfolioInput
        fileprivate let result: OathHomePortfolioBuilder.Result
    }
    private(set) var walletID: String?
    private(set) var rows: [OathHomeAssetPresentation] = []
    private(set) var treeRows: [OathHomeAssetTreeEntry] = []
    private(set) var searchRows: [OathHomeAssetPresentation] = []
    private(set) var total = ""
    private(set) var currency = "USD"
    private(set) var filter = PortfolioFilter()
    private(set) var holdingCount = 0
    private(set) var hasPrepared = false
    @ObservationIgnored private let builder = OathHomePortfolioBuilder()
    @ObservationIgnored private var requested: OathHomePortfolioInput?
    @ObservationIgnored private var pending: OathHomePortfolioInput?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var epoch = UUID()

    func update(_ input: OathHomePortfolioInput) {
        guard requested != input else { return }
        requested = input; pending = input
        updateContext(input)
        if walletID != input.walletID {
            walletID = input.walletID; rows = []; treeRows = []; searchRows = []; total = ""; hasPrepared = false
        }
        guard work == nil else { return }
        let epoch = epoch, builder = builder
        // One worker and one latest pending value. Bursts cannot create an
        // unbounded task queue or publish an older wallet/currency/filter result.
        work = Task(priority: .utility) { [weak self] in
            await OathDiagnostics.$operationID.withValue(UUID()) {
                while let input = self?.pending, !Task.isCancelled {
                    self?.pending = nil
                    do {
                        let result = try await builder.build(input)
                        guard let self, self.epoch == epoch, !Task.isCancelled else { return }
                        guard self.pending == nil else { continue }
                        if self.rows != result.rows { self.rows = result.rows }
                        if self.treeRows != result.treeRows { self.treeRows = result.treeRows }
                        if self.searchRows != result.searchRows { self.searchRows = result.searchRows }
                        if self.total != result.total { self.total = result.total }
                        self.hasPrepared = true
                    } catch is CancellationError { return } // Expected view/session teardown.
                    catch {
                        OathDiagnostics.record(error, component: "home", operation: "prepare_portfolio")
                    }
                }
            }
            if self?.epoch == epoch { self?.work = nil }
        }
    }

    /// Startup/unlock waits for local presentation, not a network refresh.
    /// The session owns this model so view/lock recreation cannot empty it.
    func prepare(_ input: OathHomePortfolioInput) async throws -> Prepared {
        cancel()
        requested = input
        let epoch = epoch
        let result = try await builder.build(input)
        guard self.epoch == epoch, !Task.isCancelled else { throw CancellationError() }
        return Prepared(epoch: epoch, input: input, result: result)
    }

    /// Commit alongside the session's wallet/history snapshot, after all local
    /// reads finish. A cancelled or superseded preparation cannot publish.
    func publish(_ prepared: Prepared) throws {
        guard epoch == prepared.epoch, requested == prepared.input,
              pending == nil, work == nil, !Task.isCancelled else { throw CancellationError() }
        let input = prepared.input, result = prepared.result
        updateContext(input)
        walletID = input.walletID; rows = result.rows; treeRows = result.treeRows; searchRows = result.searchRows
        total = result.total; requested = input; hasPrepared = true
    }

    func reset() {
        cancel()
        walletID = nil; rows = []; treeRows = []; searchRows = []; total = ""; hasPrepared = false
        currency = "USD"; filter = .init(); holdingCount = 0
    }

    private func updateContext(_ input: OathHomePortfolioInput) {
        if currency != input.currency { currency = input.currency }
        if filter != input.filter { filter = input.filter }
        if holdingCount != input.holdings.count { holdingCount = input.holdings.count }
    }

    func cancel() {
        epoch = UUID(); work?.cancel(); work = nil; requested = nil; pending = nil
    }
}
