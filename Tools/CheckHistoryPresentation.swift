import Foundation
import OathDatabase

// Remote swap enrichment is outside this isolated database/presentation check.
actor OathSwapHistoryEnrichment {
    static let shared = OathSwapHistoryEnrichment()
    func observe(walletID: String) async {}
}

// Control database acquisition so assertions inspect the actual model between
// requests. SQLite observations and queries themselves are production code.
actor OathDataEnvironment {
    static let shared = OathDataEnvironment()
    private var store: OathDatabase!
    private var shouldHold = false
    private var waiting: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiting != nil }
    func configure(_ store: OathDatabase) { self.store = store }
    func holdNextRead() { shouldHold = true }
    func releaseRead() { waiting?.resume(); waiting = nil }
    func database() async throws -> OathDatabase {
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation { waiting = $0 }
        }
        return store
    }
}

@main struct CheckHistoryPresentation {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func waitUntil(_ ready: () async -> Bool) async throws {
            for _ in 0..<600 {
                if await ready() { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            preconditionFailure("History observation did not settle")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-presentation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        await OathDataEnvironment.shared.configure(db)
        try await db.seed(networks: ["ethereum", "polygon"].enumerated().map {
            .init(id: $1, name: $1, family: "evm", symbol: "ETH", decimals: 18,
                  derivationPath: "", logo: "", sortOrder: $0)
        }, assets: [
            .init(id: "eth", networkID: "ethereum", reference: "native", name: "Ethereum", symbol: "ETH", decimals: 18),
            .init(id: "pol", networkID: "polygon", reference: "native", name: "Polygon", symbol: "POL", decimals: 18)
        ])
        try await db.importWalletIfNeeded(.init(id: "wallet", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1), accounts: [
            .init(id: "account", walletID: "wallet", networkID: "ethereum", address: "public-fixture", derivationPath: ""),
            .init(id: "polygon", walletID: "wallet", networkID: "polygon", address: "public-fixture", derivationPath: "")])
        try await db.importWalletIfNeeded(.init(id: "other", name: "Other", kind: "hd", vaultReference: "other", createdAt: 1), accounts: [])
        var batch = SyncBatch(cursor: .init(accountID: "account", stream: "fixture", cursor: "1", updatedAt: 100), expectedCursor: nil)
        for index in 0..<65 {
            let id = "tx-\(index)", time = Double(index + 1)
            batch.transactions.append(.init(id: id, networkID: "ethereum", hash: id, state: "confirmed", timestamp: time, updatedAt: time))
            batch.activity.append(.init(id: id, walletID: "wallet", accountID: "account", networkID: "ethereum", transactionID: id,
                assetID: "eth", direction: index.isMultiple(of: 2) ? "incoming" : "outgoing", amountAtomic: "1",
                counterparty: "public-peer", timestamp: time))
        }
        try await db.apply(batch)
        let seed = try await db.chainHistory(walletID: "wallet", currency: "USD", limit: 51)
        let model = OathChainActivityModel(seed: .init(walletID: "wallet", currency: "USD", localeIdentifier: "en", items: seed))
        check(model.items.count == 50 && model.hasMore && !model.loading, "Cold-start seed stays ready")
        var requested = 0, started = 0
        func observe(wallet: String = "wallet", network: String? = nil, account: String? = nil, asset: String? = nil,
                     query: String = "", filter: HistoryFilter = .init(), currency: String = "USD") -> Task<Void, Never> {
            requested += 1
            let request = requested
            return Task {
                started = request
                await model.observe(walletID: wallet, networkID: network, accountID: account, assetID: asset,
                    currency: currency, query: query, filter: filter, localeIdentifier: "en")
            }
        }
        func settle() async throws { try await waitUntil { started == requested && !model.loading } }
        func held() async throws { try await waitUntil { await OathDataEnvironment.shared.isWaiting } }
        var incoming = HistoryFilter(); incoming.directions = [.incoming]
        var outgoing = HistoryFilter(); outgoing.directions = [.outgoing]

        await OathDataEnvironment.shared.holdNextRead()
        let filtered = observe(filter: incoming)
        try await held()
        check(model.items == Array(seed.prefix(50)) && model.loading, "Applying a filter must not clear the old page")
        await OathDataEnvironment.shared.releaseRead(); try await settle()
        check(model.items.count == 33 && model.items.allSatisfy { $0.entry.direction == "incoming" }, "Replacement is a complete filtered page")
        check(!model.hasMore, "Filtered pagination uses its own lookahead")
        filtered.cancel(); await filtered.value

        let filteredIDs = model.items.map(\.id)
        await OathDataEnvironment.shared.holdNextRead()
        let reset = observe()
        try await held()
        check(model.items.map(\.id) == filteredIDs, "Removing a filter preserves rows until replacement")
        await OathDataEnvironment.shared.releaseRead(); try await settle()
        check(model.items.count == 50 && model.hasMore, "Reset restores first page and lookahead")
        reset.cancel(); await reset.value
        model.loadMoreOrRetry()
        let more = observe(); try await settle()
        check(model.items.count == 65 && model.limit == 100 && !model.hasMore, "Load more preserves the full observed window")
        more.cancel(); await more.value

        await OathDataEnvironment.shared.holdNextRead()
        let slow = observe(filter: incoming)
        try await held()
        check(model.items.count == 65 && model.limit == 50, "A changed filter resets pagination without blanking the window")
        let latest = observe(filter: outgoing); try await settle()
        check(model.items.count == 32, "The newer filter can finish first")
        await OathDataEnvironment.shared.releaseRead(); await slow.value
        check(model.items.allSatisfy { $0.entry.direction == "outgoing" }, "Late superseded results cannot replace current results")
        latest.cancel(); await latest.value

        let previous = model.items
        await OathDataEnvironment.shared.holdNextRead()
        let search = observe(query: "tx-1")
        try await held()
        check(model.items == previous, "Search debounce must preserve its previous page")
        search.cancel(); await OathDataEnvironment.shared.releaseRead(); await search.value
        check(model.items == previous && !model.failed, "Canceled search retains rows and is not a failure")

        var invalid = HistoryFilter(); invalid.minimumAmount = "invalid"
        let failure = observe(filter: invalid); await failure.value
        check(model.items == previous && model.failed, "Query failure must preserve displayed transactions and expose retry")
        model.loadMoreOrRetry()
        check(model.attempt == 1 && model.loading, "Retry can restart a failed observation")
        var noMatch = HistoryFilter(); noMatch.assetIDs = ["missing"]
        let empty = observe(filter: noMatch); try await settle()
        check(model.items.isEmpty && !model.failed && !model.hasMore, "A true empty result replaces rows only after the query finishes")
        empty.cancel(); await empty.value
        let restored = observe(); try await settle()
        check(model.items.count == 50, "Clearing a no-match filter restores rows")
        restored.cancel(); await restored.value

        // Each identity change must clear immediately, even if database work is
        // delayed. Preserving rows is only valid inside the same history scope.
        for boundary in 0..<4 {
            let fresh = OathChainActivityModel(seed: .init(walletID: "wallet", currency: "USD", localeIdentifier: "en", items: seed))
            await OathDataEnvironment.shared.holdNextRead()
            let changed = Task {
                await fresh.observe(walletID: boundary == 0 ? "other" : "wallet", networkID: boundary == 1 ? "polygon" : nil,
                    accountID: boundary == 2 ? "polygon" : nil, assetID: boundary == 3 ? "pol" : nil,
                    currency: "USD", query: "", filter: .init(), localeIdentifier: "en")
            }
            try await held()
            check(fresh.items.isEmpty, "A new wallet/network/account/asset must never display the previous scope's rows")
            changed.cancel(); await OathDataEnvironment.shared.releaseRead(); await changed.value
        }
        print("PASS: \(checks) history presentation checks; real SQLite, filtering, paging, stale responses, cancellation, failures and scope isolation. No simulator/device used.")
    }
}
