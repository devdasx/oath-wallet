import Foundation

struct HistoryPage<Item: Sendable, Cursor: Hashable & Sendable>: Sendable {
    let items: [Item]
    let nextCursor: Cursor?
    let reportedItemCount: Int

    init(
        items: [Item],
        nextCursor: Cursor?,
        reportedItemCount: Int? = nil
    ) {
        self.items = items
        self.nextCursor = nextCursor
        self.reportedItemCount = reportedItemCount ?? items.count
    }
}

struct HistoryPaginationResult<Item: Sendable>: Sendable {
    let items: [Item]
    let pageCount: Int
    let reportedItemCount: Int
}

enum HistoryPaginationError: Error, Equatable, Sendable {
    case invalidPageLimit
    case invalidItemLimit
    case invalidReportedItemLimit
    case repeatedCursor
    case pageLimitExceeded(Int)

    var diagnosticDescription: String {
        switch self {
        case .invalidPageLimit:
            "invalid_page_limit"
        case .invalidItemLimit:
            "invalid_item_limit"
        case .invalidReportedItemLimit:
            "invalid_reported_item_limit"
        case .repeatedCursor:
            "repeated_cursor"
        case let .pageLimitExceeded(limit):
            "page_limit_exceeded limit=\(limit)"
        }
    }
}

enum HistoryPaginator {
    /// Collects provider pages, optionally stopping at a bounded item count,
    /// or throws without returning partial data.
    ///
    /// Cursors are intentionally opaque. Diagnostics expose only counts and
    /// page numbers so wallet addresses, transaction identifiers, and provider
    /// cursors never enter logs.
    static func collect<Item, Cursor>(
        service: String,
        stream: String,
        initialCursor: Cursor? = nil,
        maximumPages: Int = 10_000,
        maximumItems: Int? = nil,
        maximumReportedItems: Int? = nil,
        fetchPage: @escaping @Sendable (Cursor?) async throws
            -> HistoryPage<Item, Cursor>
    ) async throws -> HistoryPaginationResult<Item>
    where Item: Sendable, Cursor: Hashable & Sendable {
        guard maximumPages > 0 else {
            throw HistoryPaginationError.invalidPageLimit
        }
        if let maximumItems, maximumItems <= 0 {
            throw HistoryPaginationError.invalidItemLimit
        }
        if let maximumReportedItems, maximumReportedItems <= 0 {
            throw HistoryPaginationError.invalidReportedItemLimit
        }

        var cursor = initialCursor
        var seenCursors = Set<Cursor>()
        if let initialCursor {
            seenCursors.insert(initialCursor)
        }
        var accumulatedItems: [Item] = []
        var accumulatedReportedItemCount = 0
        var pageNumber = 0

        while true {
            try Task.checkCancellation()
            guard pageNumber < maximumPages else {
                throw HistoryPaginationError.pageLimitExceeded(maximumPages)
            }

            let page = try await fetchPage(cursor)
            try Task.checkCancellation()
            pageNumber += 1
            accumulatedItems.append(contentsOf: page.items)
            accumulatedReportedItemCount += page.reportedItemCount

            if let maximumItems,
               accumulatedItems.count >= maximumItems {
                return HistoryPaginationResult(
                    items: Array(accumulatedItems.prefix(maximumItems)),
                    pageCount: pageNumber,
                    reportedItemCount: min(
                        accumulatedReportedItemCount,
                        maximumItems
                    )
                )
            }

            // Some providers return one decoded dashboard per page while the
            // dashboard itself contains many transactions. In that case the
            // decoded item count cannot bound network pagination. Respect the
            // provider-reported count without truncating an indivisible page.
            if let maximumReportedItems,
               accumulatedReportedItemCount >= maximumReportedItems {
                return HistoryPaginationResult(
                    items: accumulatedItems,
                    pageCount: pageNumber,
                    reportedItemCount: min(
                        accumulatedReportedItemCount,
                        maximumReportedItems
                    )
                )
            }

            guard let nextCursor = page.nextCursor else {
                return HistoryPaginationResult(
                    items: accumulatedItems,
                    pageCount: pageNumber,
                    reportedItemCount: accumulatedReportedItemCount
                )
            }
            guard seenCursors.insert(nextCursor).inserted else {
                throw HistoryPaginationError.repeatedCursor
            }
            cursor = nextCursor
        }
    }
}
