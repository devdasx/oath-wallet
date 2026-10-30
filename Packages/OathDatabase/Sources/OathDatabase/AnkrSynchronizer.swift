import OathDiagnostics
import Foundation
import OathAnkr

public struct AnkrSyncOutcome: Sendable {
    public let accountID: String
    public let stream: String
    public let success: Bool
    /// Preserve the original failure across the nonthrowing concurrent fan-out.
    /// A generic wallet error would bypass provider availability exclusions and
    /// discard the information needed to diagnose a genuine failure.
    public let failure: (any Error)?
    public init(accountID: String, stream: String, success: Bool, failure: (any Error)? = nil) {
        self.accountID = accountID; self.stream = stream; self.success = success
        self.failure = failure
    }
}

/// A shared four-request permit pool covers every chain, stream and refresh.
/// History pages remain sequential within a cursor; independent chains,
/// balances and both activity streams overlap. Writers commit each page once.
public actor AnkrSynchronizer {
    private let database: OathDatabase
    private let client: AnkrClient
    private var flights: [String: (UUID, Task<AnkrSyncOutcome, Never>)] = [:]
    private var epoch = UUID()
    private var catalogFlights: [AnkrChain: (UUID, Task<Void, Never>)] = [:]
    private var catalogAttempts: [AnkrChain: Date] = [:]
    private let catalogTransport: any AnkrTransport
    public init(database: OathDatabase, apiKey: String) throws {
        self.database = database; client = try AnkrClient(apiKey: apiKey)
        catalogTransport = AnkrHTTPTransport()
    }
    public init(database: OathDatabase, client: AnkrClient, catalogTransport: any AnkrTransport = AnkrHTTPTransport()) {
        self.database = database; self.client = client; self.catalogTransport = catalogTransport
    }
    public static func supports(networkID: String) -> Bool { AnkrChain(networkID: networkID) != nil }
    public static var supportedNetworkIDs: [String] { AnkrChain.allCases.map(\.networkID) }

    public func refresh(walletID: String) async throws -> [AnkrSyncOutcome] {
        try Task.checkCancellation()
        let generation = epoch
        let accounts = try await database.accounts(walletID: walletID).filter { Self.supports(networkID: $0.networkID) }
        guard generation == epoch, !Task.isCancelled else { throw CancellationError() }
        async let balances = refresh(accounts: accounts, stream: "balances", generation: generation)
        async let transactions = refresh(accounts: accounts, stream: "transactions", generation: generation)
        async let transfers = refresh(accounts: accounts, stream: "transfers", generation: generation)
        let outcomes = await balances + transactions + transfers
        // Shared flights return failed outcomes when canceled. Preserve that
        // cancellation at the throwing wallet boundary instead of making the
        // caller mistake normal wallet/lock teardown for a provider outage.
        guard generation == epoch, !Task.isCancelled else { throw CancellationError() }
        return outcomes
    }
    private func refresh(accounts: [AccountRecord], stream: String, generation: UUID) async -> [AnkrSyncOutcome] {
        await withTaskGroup(of: AnkrSyncOutcome.self) { group in
            var next = 0
            func enqueue() {
                guard next < accounts.count, !Task.isCancelled else { return }
                let account = accounts[next]; next += 1
                group.addTask { await self.run(account: account, stream: stream, generation: generation) }
            }
            for _ in 0..<min(4, accounts.count) { enqueue() }
            var result: [AnkrSyncOutcome] = []
            for await value in group { result.append(value); enqueue() }
            return result
        }
    }
    public func refresh(account: AccountRecord) async -> [AnkrSyncOutcome] {
        let generation = epoch
        return await withTaskGroup(of: AnkrSyncOutcome.self) { group in
            for stream in ["balances","transactions","transfers"] {
                group.addTask { await self.run(account: account, stream: stream, generation: generation) }
            }
            var results: [AnkrSyncOutcome] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    /// A changed visibility preference must not join an older filtered scan
    /// and stop there. Finish any prior balance flights, then read the saved
    /// preference again. History and other wallets are not canceled.
    public func refreshBalances(walletID: String) async throws -> [AnkrSyncOutcome] {
        try Task.checkCancellation()
        let generation = epoch
        let accounts = try await database.accounts(walletID: walletID).filter { Self.supports(networkID: $0.networkID) }
        let pending = accounts.compactMap { account -> (String, UUID, Task<AnkrSyncOutcome, Never>)? in
            let key = account.id + ":balances"
            guard let flight = flights[key] else { return nil }
            return (key, flight.0, flight.1)
        }
        for (key, id, task) in pending {
            _ = await task.value
            // Either waiter may resume first. Retire the completed old flight
            // here too, without removing a newer refresh started meanwhile.
            if flights[key]?.0 == id { flights[key] = nil }
        }
        guard generation == epoch, !Task.isCancelled else { throw CancellationError() }
        let outcomes = await refresh(accounts: accounts, stream: "balances", generation: generation)
        guard generation == epoch, !Task.isCancelled else { throw CancellationError() }
        return outcomes
    }
    private func run(account: AccountRecord, stream: String, generation: UUID) async -> AnkrSyncOutcome {
        await OathDiagnostics.$chain.withValue(account.networkID) {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                await runWithDiagnostics(account: account, stream: stream, generation: generation)
            }
        }
    }
    private func runWithDiagnostics(account: AccountRecord, stream: String, generation: UUID) async -> AnkrSyncOutcome {
        guard generation == epoch, !Task.isCancelled else { return AnkrSyncOutcome(accountID: account.id, stream: stream, success: false) }
        let key = account.id + ":" + stream
        if let flight = flights[key] { return await flight.1.value }
        let id = UUID()
        let task = Task { [database,client] in
            var ticket: AnkrSyncTicket?
            do {
                try Task.checkCancellation()
                guard let chain = AnkrChain(networkID: account.networkID) else { throw AnkrError.wrongChain }
                // Ankr's history endpoints do not document onlyWhitelisted.
                // Resolve exact contracts independently, including sold tokens.
                if stream == "transfers" { await self.refreshCatalog(chain) }
                try Task.checkCancellation()
                var start = try await database.beginAnkrSync(accountID: account.id, stream: stream)
                ticket = start
                let onlyWhitelisted = stream == "balances"
                    ? try await database.portfolioFilter(walletID: account.walletID).hidesUnverifiedTokens : true
                // Independent inventories share the client's bounded permit pool.
                async let verificationPages = onlyWhitelisted ? [] : Self.whitelistInventory(client: client, chain: chain, address: account.address)
                var cursor = start.state.cursor
                var restarted = false
                var seen: Set<String> = []
                var pages: [AnkrPage<AnkrBalanceResult>] = []
                while true {
                    try Task.checkCancellation()
                    if let cursor, !seen.insert(cursor).inserted { throw AnkrError.paginationLoop }
                    do {
                    if stream == "balances" {
                        let page = try await client.balances(chain: chain, address: account.address, cursor: cursor,
                                                             onlyWhitelisted: onlyWhitelisted)
                        pages.append(page); cursor = page.value.nextPageToken
                    } else if stream == "transactions" {
                        let page = try await client.transactions(chain: chain, address: account.address, cursor: cursor,
                            fromTimestamp: start.state.windowStart, toTimestamp: start.state.windowEnd)
                        try Task.checkCancellation()
                        try await database.commitAnkrTransactions(page, ticket: start, cursor: cursor)
                        cursor = page.value.nextPageToken
                    } else {
                        let page = try await client.transfers(chain: chain, address: account.address, cursor: cursor,
                            fromTimestamp: start.state.windowStart, toTimestamp: start.state.windowEnd)
                        try Task.checkCancellation()
                        try await database.commitAnkrTransfers(page, ticket: start, cursor: cursor)
                        cursor = page.value.nextPageToken
                    }
                    } catch StoreError.staleSync {
                        throw StoreError.staleSync
                    } catch { OathDiagnostics.record(error, component: "sync", operation: stream, context: ["chain": account.networkID, "stage": stream]);
                        let rejected: Bool
                        switch error {
                        case AnkrError.rpc(-32602), AnkrError.http(400): rejected = true
                        default: rejected = false
                        }
                        if rejected && cursor != nil && !restarted {
                            start = try await database.restartAnkrWindow(start); ticket = start
                            cursor = nil; seen.removeAll(); pages.removeAll(); restarted = true
                            continue
                        }
                        throw error
                    }
                    if cursor?.isEmpty == true { cursor = nil }
                    // Explicit failure retains a resumable history cursor; it
                    // cannot be mistaken for a complete empty wallet.
                    guard seen.count < 100_000, pages.reduce(0, { $0 + $1.raw.count }) <= 128 * 1024 * 1024 else {
                        throw AnkrError.responseTooLarge
                    }
                    if cursor == nil { break }
                }
                try Task.checkCancellation()
                if stream == "balances" {
                    try await database.commitAnkrBalances(pages, ticket: start, onlyWhitelisted: onlyWhitelisted,
                                                          verificationPages: verificationPages)
                }
                return AnkrSyncOutcome(accountID: account.id, stream: stream, success: true)
            } catch is CancellationError {
                // Reset/lock teardown owns cleanup; do not try to record a failure in the wallet DB.
                return AnkrSyncOutcome(accountID: account.id, stream: stream, success: false)
            } catch StoreError.staleSync {
                // A replaced/deleted account or newer sync owns this state now.
                return AnkrSyncOutcome(accountID: account.id, stream: stream, success: false)
            } catch { OathDiagnostics.record(error, component: "sync", operation: stream, context: ["chain": account.networkID, "stage": stream]);
                let code: String
                if error is CancellationError { code = "cancelled" }
                else if let error = error as? AnkrError { code = String(describing: error) }
                else { code = "storage" }
                if let ticket { await OathDiagnostics.attempt("failAnkrSync", body: { try await database.failAnkrSync(ticket, code: code) }) }
                return AnkrSyncOutcome(accountID: account.id, stream: stream, success: false, failure: error)
            }
        }
        flights[key] = (id,task)
        let result = await task.value
        if flights[key]?.0 == id { flights[key] = nil }
        return result
    }

    private static func whitelistInventory(client: AnkrClient, chain: AnkrChain, address: String) async throws -> [AnkrPage<AnkrBalanceResult>] {
        var cursor: String?
        var seen: Set<String> = []
        var pages: [AnkrPage<AnkrBalanceResult>] = []
        var bytes = 0
        var restarted = false
        while true {
            try Task.checkCancellation()
            if let cursor, !seen.insert(cursor).inserted { throw AnkrError.paginationLoop }
            do {
                let page = try await client.balances(chain: chain, address: address, cursor: cursor, onlyWhitelisted: true)
                pages.append(page); bytes += page.raw.count
                guard seen.count < 100_000, bytes <= 128 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
                cursor = page.value.nextPageToken
                if cursor?.isEmpty != false { return pages }
            } catch {
                OathDiagnostics.record(error, component: "sync", operation: "balance_verification", context: ["chain": chain.networkID])
                switch error {
                case AnkrError.rpc(-32602), AnkrError.http(400):
                    guard cursor != nil, !restarted else { throw error }
                    cursor = nil; seen.removeAll(); pages.removeAll(); bytes = 0; restarted = true
                default: throw error
                }
            }
        }
    }
    public func cancel() async {
        epoch = UUID()
        let catalogs = catalogFlights.values.map(\.1)
        catalogFlights.removeAll()
        catalogAttempts.removeAll()
        for task in catalogs { task.cancel() }
        let tasks = flights.values.map(\.1)
        // A refresh started after cancellation must not join the old, already
        // cancelled flight while its original waiter is still unwinding.
        flights.removeAll()
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
        for task in catalogs { await task.value }
    }

    private func refreshCatalog(_ chain: AnkrChain) async {
        if let flight = catalogFlights[chain] { await flight.1.value; return }
        if let attempt = catalogAttempts[chain], Date().timeIntervalSince(attempt) < 300 { return }
        catalogAttempts[chain] = .now
        let database = database, transport = catalogTransport
        let id = UUID()
        let task = Task {
            let key = "evm.verified." + chain.networkID
            let cached = await OathDiagnostics.attemptOptional("marketCache", body: { try await database.marketCache(key: key) })
            if let cached, Date().timeIntervalSince1970 - cached.fetchedAt < (cached.source == "CoinGecko" ? 86_400 : 300) { return }
            do {
                var catalog = try await VerifiedEVMTokenCatalog.fetch(chain: chain, transport: transport)
                // A narrower issuer/offline fallback must not remove previously
                // verified identities. Optional corrupt cache is a cache miss.
                let previous = cached.flatMap { try? JSONDecoder().decode(VerifiedEVMTokenCatalog.self, from: $0.payload) }
                catalog = try catalog.retainingVerifiedEntries(from: previous)
                try Task.checkCancellation()
                try await database.saveMarketCache(.init(key: key, source: catalog.source ?? "CoinGecko", payload: try JSONEncoder().encode(catalog), fetchedAt: Date().timeIntervalSince1970))
            } catch { OathDiagnostics.record(error); /* Keep cached verification; never trust tokens on lookup failure. */ }
        }
        catalogFlights[chain] = (id, task)
        await task.value
        if catalogFlights[chain]?.0 == id { catalogFlights[chain] = nil }
    }
}
