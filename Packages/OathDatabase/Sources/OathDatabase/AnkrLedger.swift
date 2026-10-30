import OathArtworkSource
import Foundation
import CryptoKit
import GRDB
import OathAnkr

public struct AnkrSyncRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ankrSync"
    public var accountID: String
    public var stream: String
    public var runID: String?
    public var scanID: String?
    public var cursor: String?
    public var windowStart: Int
    public var windowEnd: Int
    public var complete: Bool
    public var lastSuccess: Double?
    public var failure: String?
    public var syncStatus: Data?
    public var totalBalanceUsd: String?
    public var totalCount: Int?

    public var isDelayed: Bool {
        guard let syncStatus, let value = try? JSONDecoder().decode(AnkrSyncStatus.self, from: syncStatus) else { return false }
        return value.status != nil && value.status != "synced"
    }
}

public struct AnkrSyncTicket: Sendable {
    public let account: AccountRecord
    public let generation: Int64
    public let state: AnkrSyncRecord
}

public struct AnkrCachedAsset: Sendable {
    public let details: AnkrAsset
    public let fetchedAt: Date
}

public struct AnkrResponsePage: Sendable, FetchableRecord, Decodable {
    public let pageKey: String
    public let fetchedAt: Double
    public let byteCount: Int
}

extension OathDatabase {
    /// New EVM networks reuse the existing Ethereum key/path. This copies only
    /// public metadata after unlock and never invents a different derivation.
    public func enrollAnkrNetworks(walletID: String) async throws {
        try await pool.write { db in
            let existing = try Self.accounts(db, walletID: walletID)
            let additions: Set<String> = ["fantom","flare","somnia","story","robinhood","hyperevm","monad","unichain","celo","chiliz","filecoin", "sei", "zerog", "iotex"]
            // Arc belongs to the app's original full EVM import scope even
            // though it is not indexed by these Advanced account methods.
            let previousEVM = Set(AnkrChain.allCases.map(\.networkID)).subtracting(additions).union(["arc"])
            // A full pre-upgrade EVM wallet can expand. A deliberately narrow
            // private-key/backup scope must remain exactly as imported.
            guard previousEVM.isSubset(of: Set(existing.map(\.networkID))) else { return }
            let sources = existing.filter { AnkrChain(networkID: $0.networkID) != nil }
                .sorted { ($0.networkID == "ethereum" ? 0 : 1, $0.id) < ($1.networkID == "ethereum" ? 0 : 1, $1.id) }
            for network in additions.sorted() {
                guard try NetworkRecord.fetchOne(db, key: network) != nil else { continue }
                var indices: Set<Int> = []
                for source in sources where indices.insert(source.accountIndex).inserted {
                    guard !existing.contains(where: { $0.networkID == network && $0.accountIndex == source.accountIndex }) else { continue }
                    let account = AccountRecord(id: walletID + ":" + network + ":" + String(source.accountIndex), walletID: walletID,
                        networkID: network, address: source.address, derivationPath: source.derivationPath, accountIndex: source.accountIndex)
                    try account.insert(db, onConflict: .ignore)
                }
            }
        }
    }
    public func ankrStatus(accountID: String) async throws -> [AnkrSyncRecord] {
        try await pool.read { try AnkrSyncRecord.fetchAll($0, sql: "SELECT * FROM ankrSync WHERE accountID=? ORDER BY stream", arguments: [accountID]) }
    }
    public func ankrResponse(accountID: String, stream: String, pageKey: String) async throws -> Data? {
        try await pool.read { try Data.fetchOne($0, sql: "SELECT raw FROM ankrResponses WHERE accountID=? AND stream=? AND pageKey=?", arguments: [accountID,stream,pageKey]) }
    }
    /// Read provider units, USD valuation, price and metadata without a network
    /// call. The response archive separately preserves unmodeled properties.
    public func ankrAssetDetails(accountID: String, assetID: String) async throws -> AnkrCachedAsset? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT detail,fetchedAt FROM ankrAssets WHERE accountID=? AND assetID=?",
                arguments: [accountID,assetID]) else { return nil }
            return AnkrCachedAsset(details: try JSONDecoder().decode(AnkrAsset.self, from: row["detail"]),
                fetchedAt: Date(timeIntervalSince1970: row["fetchedAt"]))
        }
    }
    /// Page through archive metadata before loading individual response bodies.
    public func ankrResponsePages(accountID: String, stream: String, limit: Int = 100, offset: Int = 0) async throws -> [AnkrResponsePage] {
        try await pool.read { try AnkrResponsePage.fetchAll($0, sql: """
            SELECT pageKey,fetchedAt,length(raw) AS byteCount FROM ankrResponses
            WHERE accountID=? AND stream=? ORDER BY fetchedAt DESC,pageKey LIMIT ? OFFSET ?
            """, arguments: [accountID,stream,min(500,max(1,limit)),max(0,offset)]) }
    }
    public func beginAnkrSync(accountID: String, stream: String, now: Date = .now) async throws -> AnkrSyncTicket {
        guard ["balances","transactions","transfers"].contains(stream) else { throw StoreError.invalidValue("Ankr stream") }
        return try await pool.write { db in
            try Self.requireAnkrSyncAllowed(db)
            guard let account = try AccountRecord.fetchOne(db, key: accountID),
                  AnkrChain(networkID: account.networkID) != nil else { throw StoreError.missingRecord }
            var record = try AnkrSyncRecord.fetchOne(db, key: ["accountID":accountID, "stream":stream])
                ?? AnkrSyncRecord(accountID: accountID, stream: stream, windowStart: 0, windowEnd: 0, complete: false)
            // Resume an interrupted historical window with its exact opaque
            // token; a new window overlaps one day to reconcile recent reorgs.
            if stream == "balances" || record.complete || record.windowEnd == 0 {
                record.cursor = nil
                record.scanID = UUID().uuidString
                let indexedAt = record.syncStatus.flatMap { try? JSONDecoder().decode(AnkrSyncStatus.self, from: $0).timestamp }
                let highWater = min(record.windowEnd, indexedAt.map { Int($0) } ?? record.windowEnd)
                record.windowStart = stream == "balances" ? 0 : max(0, highWater - 86_400)
                record.windowEnd = Int(now.timeIntervalSince1970)
                record.complete = false
            }
            record.runID = UUID().uuidString; record.failure = nil
            try record.upsert(db)
            return AnkrSyncTicket(account: account, generation: account.syncGeneration, state: record)
        }
    }
    public func failAnkrSync(_ ticket: AnkrSyncTicket, code: String) async throws {
        try await pool.write { db in
            // Reset owns teardown. A late failure must not write through its SQL guard.
            guard try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='walletReset'") == nil else { return }
            try db.execute(sql: "UPDATE ankrSync SET failure=?,runID=NULL WHERE accountID=? AND stream=? AND runID=?",
                arguments: [code,ticket.account.id,ticket.state.stream,ticket.state.runID])
        }
    }
    /// Providers may invalidate an opaque page token between app launches.
    /// Restart the same bounded window once; upserts prevent duplicates and
    /// existing history stays visible until the replacement scan completes.
    public func restartAnkrWindow(_ ticket: AnkrSyncTicket) async throws -> AnkrSyncTicket {
        try await pool.write { db in
            var state = try Self.validateAnkr(ticket, db: db)
            state.cursor = nil; state.scanID = UUID().uuidString; state.failure = nil
            try state.update(db)
            return AnkrSyncTicket(account: ticket.account, generation: ticket.generation, state: state)
        }
    }
    private static func requireAnkrSyncAllowed(_ db: Database) throws {
        // Read inside the same writer transaction as the commit: reset cannot race
        // between this check and the guarded write. SQL triggers remain the backstop.
        guard try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='walletReset'") == nil else {
            throw CancellationError()
        }
    }
    private static func validateAnkr(_ ticket: AnkrSyncTicket, db: Database) throws -> AnkrSyncRecord {
        try requireAnkrSyncAllowed(db)
        guard let account = try AccountRecord.fetchOne(db, key: ticket.account.id),
              account.syncGeneration == ticket.generation, account.address == ticket.account.address,
              let state = try AnkrSyncRecord.fetchOne(db, key: ["accountID":account.id, "stream":ticket.state.stream]),
              state.runID == ticket.state.runID else { throw StoreError.staleSync }
        return state
    }
    private static func saveAnkrResponse(_ raw: Data, ticket: AnkrSyncTicket, key: String, date: Date, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO ankrResponses(accountID,stream,pageKey,raw,fetchedAt) VALUES(?,?,?,?,?)
            ON CONFLICT(accountID,stream,pageKey) DO UPDATE SET raw=excluded.raw,fetchedAt=excluded.fetchedAt
            """, arguments: [ticket.account.id,ticket.state.stream,key,raw,date.timeIntervalSince1970])
    }
    /// Only complete inventories may replace cached balances. An opt-in full
    /// inventory carries a separate whitelist inventory for verification.
    /// Raw pages preserve every provider field independently of projections.
    public func commitAnkrBalances(_ pages: [AnkrPage<AnkrBalanceResult>], ticket: AnkrSyncTicket,
                                   onlyWhitelisted: Bool = true,
                                   verificationPages: [AnkrPage<AnkrBalanceResult>] = []) async throws {
        guard ticket.state.stream == "balances", let last = pages.last, last.value.nextPageToken?.isEmpty != false else {
            throw AnkrError.incompleteInventory
        }
        let values = pages.flatMap(\.value.assets)
        let references = values.map(\.reference)
        guard Set(references).count == references.count,
              last.value.totalCount.map({ $0 == values.count }) ?? true else { throw AnkrError.incompleteInventory }
        for page in pages where !page.value.totalBalanceUsd.isEmpty { try Validation.price(page.value.totalBalanceUsd) }
        let verification = onlyWhitelisted ? pages : verificationPages
        guard let verifiedLast = verification.last, verifiedLast.value.nextPageToken?.isEmpty != false else {
            throw AnkrError.incompleteInventory
        }
        let verifiedValues = verification.flatMap(\.value.assets)
        guard Set(verifiedValues.map(\.reference)).count == verifiedValues.count,
              verifiedLast.value.totalCount.map({ $0 == verifiedValues.count }) ?? true else {
            throw AnkrError.incompleteInventory
        }
        for value in verifiedValues {
            guard value.blockchain == AnkrChain(networkID: ticket.account.networkID)?.rawValue,
                  value.holderAddress.lowercased() == ticket.account.address.lowercased() else {
                throw StoreError.conflictingIdentity
            }
        }
        let verifiedDecimals = Dictionary(uniqueKeysWithValues: verifiedValues.map { ($0.reference, $0.tokenDecimals) })
        let now = last.fetchedAt.timeIntervalSince1970
        try await pool.write { db in
            var state = try Self.validateAnkr(ticket, db: db)
            if let old = state.syncStatus.flatMap({ try? JSONDecoder().decode(AnkrSyncStatus.self, from: $0) }),
               let previous = old.timestamp, let incoming = last.value.syncStatus?.timestamp, incoming < previous {
                throw StoreError.staleSync
            }
            try db.execute(sql: "DELETE FROM ankrResponses WHERE accountID=? AND stream='balances'", arguments: [ticket.account.id])
            for (i, page) in pages.enumerated() { try Self.saveAnkrResponse(page.raw, ticket: ticket, key: String(i), date: page.fetchedAt, db: db) }
            // A filtered-out token may be unlisted rather than unfunded. Retire
            // its old Ankr balance instead of claiming a successful zero. Keep
            // its identity, history, quotes and explicit manual tracking intact.
            // This transaction publishes the replacement inventory atomically.
            try db.execute(sql: """
                DELETE FROM balances WHERE accountID=? AND source='ankr';
                DELETE FROM ankrAssets WHERE accountID=?;
                """, arguments: [ticket.account.id,ticket.account.id])
            let nativeID = try Self.ankrNativeAssetID(networkID: ticket.account.networkID, db: db)
            try BalanceRecord(accountID: ticket.account.id, assetID: nativeID, networkID: ticket.account.networkID,
                amountAtomic: "0", observedAt: now, source: "ankr").upsert(db)
            for value in values {
                guard value.blockchain == AnkrChain(networkID: ticket.account.networkID)?.rawValue,
                      value.holderAddress.lowercased() == ticket.account.address.lowercased() else { throw StoreError.conflictingIdentity }
                let asset = try Self.ankrAsset(networkID: ticket.account.networkID, reference: value.reference,
                    name: value.tokenName, symbol: value.tokenSymbol, decimals: value.tokenDecimals, logo: value.thumbnail, db: db)
                let atomic = try AnkrQuantity.decimal(value.balanceRawInteger)
                try Validation.amount(atomic)
                // Empty strings are Ankr's documented-in-production unknown
                // valuation. Even whitelisted tokens can lack a quote. They are not zero
                // quantities or a reason to discard the rest of the inventory.
                if !value.balanceUsd.isEmpty { try Validation.price(value.balanceUsd) }
                if !value.tokenPrice.isEmpty { try Validation.price(value.tokenPrice) }
                try BalanceRecord(accountID: ticket.account.id, assetID: asset.id, networkID: asset.networkID,
                    amountAtomic: atomic, observedAt: now, blockHeight: last.value.syncStatus?.blockNumber, source: "ankr").upsert(db)
                if !value.tokenPrice.isEmpty {
                    try PriceRecord(assetID: asset.id, currency: "USD", value: value.tokenPrice, observedAt: now, source: "ankr").upsert(db)
                    try db.execute(sql: """
                        DELETE FROM prices WHERE assetID=? AND currency='USD' AND observedAt NOT IN (
                            SELECT observedAt FROM prices WHERE assetID=? AND currency='USD' ORDER BY observedAt DESC LIMIT 256)
                        """, arguments: [asset.id,asset.id])
                }
                let verified = value.reference == "native" || verifiedDecimals[value.reference] == value.tokenDecimals
                try db.execute(sql: "INSERT INTO ankrAssets(accountID,assetID,detail,balanceUsd,fetchedAt,onlyWhitelisted) VALUES(?,?,?,?,?,?)",
                    arguments: [ticket.account.id,asset.id,try JSONEncoder().encode(value),value.balanceUsd,now,verified])
            }
            state.totalBalanceUsd = last.value.totalBalanceUsd; state.totalCount = values.count
            state.syncStatus = try last.value.syncStatus.map { try JSONEncoder().encode($0) }
            state.lastSuccess = now; state.complete = true; state.cursor = nil; state.runID = nil; state.failure = nil
            try state.update(db)
        }
    }

    static func ankrAsset(networkID: String, reference: String, name: String, symbol: String, decimals: Int,
                          logo: String?, db: Database) throws -> AssetRecord {
        guard (0...255).contains(decimals) else { throw AnkrError.invalidResponse }
        let id = networkID + ":" + reference
        if var old = try AssetRecord.fetchOne(db, sql: "SELECT * FROM assets WHERE networkID=? AND reference=?",
            arguments: [networkID,reference]) {
            guard old.networkID == networkID, old.reference == reference, old.decimals == decimals else { throw StoreError.conflictingIdentity }
            // Heal missing/stale artwork without changing native branding or user metadata.
            if reference != "native", let incoming = ArtworkSource.normalized(logo), old.logo != incoming {
                old.logo = incoming
                try old.update(db)
            }
            return old
        }
        let safeLogo = ArtworkSource.normalized(logo)
        let asset = AssetRecord(id: id, networkID: networkID, reference: reference,
            name: name.isEmpty ? reference : String(name.prefix(512)), symbol: symbol.isEmpty ? "Token" : String(symbol.prefix(128)),
            decimals: decimals, logo: safeLogo)
        try asset.insert(db)
        return asset
    }

    private static func ankrNativeAssetID(networkID: String, db: Database) throws -> String {
        guard let id = try String.fetchOne(db, sql: "SELECT id FROM assets WHERE networkID=? AND reference='native'",
            arguments: [networkID]) else { throw StoreError.missingRecord }
        return id
    }

    public func commitAnkrTransactions(_ page: AnkrPage<AnkrTransactionResult>, ticket: AnkrSyncTicket, cursor: String?) async throws {
        let now = page.fetchedAt.timeIntervalSince1970
        try await pool.write { db in
            var state = try Self.validateAnkr(ticket, db: db)
            guard ticket.state.stream == "transactions", state.cursor == cursor else { throw StoreError.staleSync }
            for value in page.value.transactions {
                let incoming = try Self.ankrTransaction(value, network: ticket.account.networkID, now: now)
                let old = try TransactionRecord.fetchOne(db, key: incoming.id)
                let tx = incoming.retainingEVMReceipt(from: old)
                guard value.blockchain == AnkrChain(networkID: ticket.account.networkID)?.rawValue else { throw StoreError.conflictingIdentity }
                // Keep observation timestamps and receipt changes, but a replay
                // of an identical page must not rewrite the same stored record.
                if old != tx { try tx.upsert(db) }
                if let nonce = value.nonce {
                    let normalizedNonce = try AnkrQuantity.decimal(nonce)
                    try Self.saveTransactionEvidence(accountID: ticket.account.id, tx: tx,
                        keys: [value.from.lowercased() + ":" + normalizedNonce],
                        returnsToWallet: value.from.lowercased() == ticket.account.address.lowercased()
                            && value.to?.lowercased() == value.from.lowercased()
                            && (try AnkrQuantity.decimal(value.value)) == "0"
                            && (value.input == "0x" || value.input == "0x0"), db: db)
                }
                let amount = tx.state == "failed" ? "0" : try AnkrQuantity.decimal(value.value)
                try Self.ankrActivity(tx: tx, assetID: Self.ankrNativeAssetID(networkID: tx.networkID, db: db), index: -1, amount: amount,
                    from: value.from, to: value.to ?? "", ticket: ticket, db: db)
            }
            try Self.finishAnkrPage(raw: page.raw, next: page.value.nextPageToken, sync: page.value.syncStatus,
                date: page.fetchedAt, cursor: cursor, ticket: ticket, state: &state, db: db)
        }
    }
    public func commitAnkrTransfers(_ page: AnkrPage<AnkrTransferResult>, ticket: AnkrSyncTicket, cursor: String?) async throws {
        let now = page.fetchedAt.timeIntervalSince1970
        try await pool.write { db in
            var state = try Self.validateAnkr(ticket, db: db)
            guard ticket.state.stream == "transfers", state.cursor == cursor else { throw StoreError.staleSync }
            for value in page.value.transfers {
                guard value.blockchain == AnkrChain(networkID: ticket.account.networkID)?.rawValue else { throw StoreError.conflictingIdentity }
                let id = ticket.account.networkID + ":" + value.transactionHash.lowercased()
                // A token event must not overwrite a richer transaction receipt
                // (status, fee, block hash, etc.) fetched by the other stream.
                let existing = try TransactionRecord.fetchOne(db, key: id)
                var tx = existing ?? TransactionRecord(id: id, networkID: ticket.account.networkID,
                    hash: value.transactionHash.lowercased(), state: value.blockHeight > 0 ? "confirmed" : "pending",
                    blockHeight: value.blockHeight > 0 ? value.blockHeight : nil, timestamp: value.timestamp, updatedAt: now)
                if tx.state == "pending" || tx.state == "reorged" {
                    tx.state = value.blockHeight > 0 ? "confirmed" : "pending"
                    tx.blockHeight = value.blockHeight > 0 ? value.blockHeight : nil
                    tx.timestamp = value.timestamp; tx.updatedAt = now
                }
                if existing != tx { try tx.upsert(db) }
                let asset = try Self.ankrAsset(networkID: ticket.account.networkID, reference: value.contractAddress.lowercased(),
                    name: value.tokenName, symbol: value.tokenSymbol, decimals: value.tokenDecimals, logo: value.thumbnail, db: db)
                try Self.ankrActivity(tx: tx, assetID: asset.id, index: value.logIndex,
                    amount: try AnkrQuantity.decimal(value.valueRawInteger), from: value.fromAddress, to: value.toAddress, ticket: ticket, db: db)
            }
            try Self.finishAnkrPage(raw: page.raw, next: page.value.nextPageToken, sync: page.value.syncStatus,
                date: page.fetchedAt, cursor: cursor, ticket: ticket, state: &state, db: db)
        }
    }
    private static func ankrTransaction(_ item: AnkrTransaction, network: String, now: Double) throws -> TransactionRecord {
        func number(_ text: String?) throws -> Int64? {
            guard let text else { return nil }
            guard let n = Int64(try AnkrQuantity.decimal(text)) else { throw AnkrError.invalidResponse }
            return n
        }
        let height = try number(item.blockNumber)
        let status = try number(item.status)
        guard status == nil || status == 0 || status == 1 else { throw AnkrError.invalidResponse }
        var fee: String?
        if let gas = item.gasUsed, let price = item.effectiveGasPrice ?? item.gasPrice { fee = try AnkrQuantity.multiply(gas, price) }
        return TransactionRecord(id: network + ":" + item.hash.lowercased(), networkID: network, hash: item.hash.lowercased(),
            state: status == 0 ? "failed" : (height == nil || height == 0 ? "pending" : "confirmed"),
            blockHeight: height, blockHash: item.blockHash, timestamp: Double(try number(item.timestamp) ?? 0), feeAtomic: fee, updatedAt: now)
    }
    private static func ankrActivity(tx: TransactionRecord, assetID: String, index: Int, amount: String,
                                     from: String, to: String, ticket: AnkrSyncTicket, db: Database) throws {
        let address = ticket.account.address.lowercased()
        guard from.lowercased() == address || to.lowercased() == address else { throw StoreError.conflictingIdentity }
        let direction = from.lowercased() == address ? (to.lowercased() == address ? "self" : "outgoing") : "incoming"
        try Validation.amount(amount)
        let transferID = tx.id + ":" + String(index) + ":" + assetID
        let transfer = TransferRecord(id: transferID, transactionID: tx.id, networkID: tx.networkID, assetID: assetID,
            eventIndex: index, fromAddress: from, toAddress: to, amountAtomic: amount)
        if try TransferRecord.fetchOne(db, key: transferID) != transfer { try transfer.upsert(db) }
        let item = ActivityRecord(id: ticket.account.id + ":" + transferID, walletID: ticket.account.walletID,
            accountID: ticket.account.id, networkID: tx.networkID, transactionID: tx.id, assetID: assetID,
            direction: direction, amountAtomic: amount, counterparty: direction == "incoming" ? from : to, timestamp: tx.timestamp)
        if try ActivityRecord.fetchOne(db, key: item.id) != item { try item.upsert(db) }
        try db.execute(sql: """
            INSERT INTO ankrActivity(accountID,activityID,stream,seenRun) VALUES(?,?,?,?)
            ON CONFLICT(accountID,activityID) DO UPDATE SET seenRun=excluded.seenRun
            """, arguments: [ticket.account.id,item.id,ticket.state.stream,ticket.state.scanID])
    }
    private static func finishAnkrPage(raw: Data, next: String?, sync: AnkrSyncStatus?, date: Date, cursor: String?,
                                      ticket: AnkrSyncTicket, state: inout AnkrSyncRecord, db: Database) throws {
        let next = next.flatMap { $0.isEmpty ? nil : $0 }
        guard next == nil || next != cursor else { throw AnkrError.paginationLoop }
        let pageID = String(state.windowStart) + ":" + String(state.windowEnd) + ":" +
            SHA256.hash(data: Data((cursor ?? "").utf8)).map { String(format:"%02x",$0) }.joined()
        try saveAnkrResponse(raw, ticket: ticket, key: pageID, date: date, db: db)
        state.cursor = next; state.syncStatus = try sync.map { try JSONEncoder().encode($0) }; state.failure = nil
        if next == nil {
            // Reconcile disappeared/reorged events only after the whole queried
            // window succeeded. Never delete older pages on a partial failure.
            try db.execute(sql: """
                DELETE FROM activity WHERE id IN (
                    SELECT a.activityID FROM ankrActivity a JOIN activity i ON i.id=a.activityID
                    WHERE a.accountID=? AND a.stream=? AND a.seenRun<>? AND i.timestamp>=? AND i.timestamp<=?
                        AND NOT EXISTS(SELECT 1 FROM transactionEvidence e JOIN transactions t ON t.id=e.transactionID
                            WHERE e.accountID=i.accountID AND e.transactionID=i.transactionID
                            AND (e.outcome IS NOT NULL OR t.state IN ('pending','replaced','reorged')))
                )
                """, arguments: [ticket.account.id,state.stream,state.scanID,state.windowStart,
                                   min(state.windowEnd, sync?.timestamp.map { Int($0) } ?? state.windowEnd)])
            state.complete = true; state.lastSuccess = date.timeIntervalSince1970; state.runID = nil
        }
        try state.update(db)
    }
}
