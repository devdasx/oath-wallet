import Foundation
import GRDB
import OathBitcoin

public struct BitcoinAccountState: Sendable, Equatable {
    public let descriptor: BitcoinWalletDescriptor
    public let preferredType: BitcoinAddressType
    public let requiredThrough: [String: UInt32]
    public let lastSuccess: Date?
    public let failure: String?
    public let tipHeight: Int64?
    public let confirmed: Int64
    public let unconfirmed: Int64
}

public struct BitcoinSpendableOutput: Sendable, Equatable {
    public let output: UTXORecord
    public let derivation: BitcoinDerivedAddress
    public let previousTransaction: Data
}

/// Searches public address metadata only. The name format and locale match the
/// address browser's localized "Address N" label; no key is read or derived.
public struct BitcoinAddressSearch: Sendable, Equatable {
    public let query: String
    public let nameFormat: String
    public let localeIdentifier: String
    private let normalizedQuery: String

    public init(query: String = "", nameFormat: String = "Address %@", localeIdentifier: String = "en") {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.nameFormat = nameFormat
        self.localeIdentifier = localeIdentifier
        self.normalizedQuery = Self.normalized(self.query)
    }

    func matches(_ address: BitcoinDerivedAddress) -> Bool {
        guard !query.isEmpty else { return true }
        let locale = Locale(identifier: localeIdentifier)
        let number = Int(address.index).formatted(.number.grouping(.never).locale(locale))
        let name = String(format: nameFormat, locale: locale, arguments: [number])
        return [address.address, address.path, name].contains { Self.normalized($0).contains(normalizedQuery) }
    }

    private static func normalized(_ value: String) -> String {
        // Accept either localized or ASCII digits and smart apostrophes when
        // looking up a derivation path. Query punctuation stays literal.
        let text = value.replacingOccurrences(of: "’", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        // Foundation may isolate formatted numbers in RTL labels. Those
        // invisible display controls must not prevent ordinary typed matches.
        let unmarked = String(String.UnicodeScalarView(text.unicodeScalars.filter { !$0.properties.isBidiControl }))
        return unmarked.map { character in character.wholeNumberValue.map(String.init) ?? String(character) }.joined()
    }
}

extension OathDatabase {
    public func prepareBitcoin(accountID: String, descriptor: BitcoinWalletDescriptor) async throws {
        // Validating all public descriptors before the transaction also prevents
        // an accidentally secret-bearing descriptor from reaching SQLite/WAL.
        let first = try descriptor.branches.flatMap { try BitcoinKeys.addresses(branch: $0, range: 0..<($0.isHD ? 20 : 1)) }
        let data = try JSONEncoder().encode(descriptor)
        try await pool.write { db in
            guard let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == descriptor.network.rawValue else { throw StoreError.missingRecord }
            if let old = try Data.fetchOne(db, sql: "SELECT descriptor FROM bitcoinWallets WHERE accountID=?", arguments: [accountID]) {
                guard try JSONDecoder().decode(BitcoinWalletDescriptor.self, from: old) == descriptor else { throw StoreError.conflictingIdentity }
            } else {
                try db.execute(sql: "INSERT INTO bitcoinWallets(accountID,descriptor,preferredType) VALUES(?,?,?)", arguments: [accountID, data, descriptor.defaultType.rawValue])
            }
            for address in first { try Self.saveBitcoinAddress(address, accountID: accountID, used: false, db: db) }
        }
    }

    public func bitcoinState(accountID: String) async throws -> BitcoinAccountState? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM bitcoinWallets WHERE accountID=?", arguments: [accountID]) else { return nil }
            let descriptor = try JSONDecoder().decode(BitcoinWalletDescriptor.self, from: row["descriptor"])
            guard let type = BitcoinAddressType(rawValue: row["preferredType"]) else { throw StoreError.conflictingIdentity }
            var required: [String: UInt32] = [:]
            for item in try Row.fetchAll(db, sql: "SELECT branchID,MAX(addressIndex) AS addressIndex FROM bitcoinAddresses WHERE accountID=? AND (used=1 OR issued=1) GROUP BY branchID", arguments: [accountID]) {
                required[item["branchID"]] = item["addressIndex"]
            }
            return .init(descriptor: descriptor, preferredType: type, requiredThrough: required,
                         lastSuccess: (row["lastSuccess"] as Double?).map(Date.init(timeIntervalSince1970:)), failure: row["failure"],
                         tipHeight: row["tipHeight"], confirmed: row["confirmed"], unconfirmed: row["unconfirmed"])
        }
    }

    /// A short reuse window for review preparation, not an alternative to
    /// spendability/reservation checks. Missing, failed, future-dated or running
    /// scans are ordinary cache misses. Reads never renew the scan's age.
    public func bitcoinSnapshotIsRecentForSend(accountID: String, now: Date = .now) async throws -> Bool {
        try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT lastSuccess,failure,scanID,tipHeight FROM bitcoinWallets WHERE accountID=?", arguments: [accountID]),
                  let success: Double = row["lastSuccess"], (0...30).contains(now.timeIntervalSince1970 - success),
                  let tip: Int64 = row["tipHeight"], tip > 0,
                  (row["failure"] as String?) == nil, (row["scanID"] as String?) == nil else { return false }
            return true
        }
    }

    /// Returns the first unused address after the last used one. Reopening the
    /// sheet reuses that address until paid, avoiding accidental gap exhaustion.
    public func bitcoinReceiveAddress(accountID: String, type: BitcoinAddressType? = nil) async throws -> BitcoinDerivedAddress {
        try await pool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT descriptor,preferredType FROM bitcoinWallets WHERE accountID=?", arguments: [accountID]) else { throw StoreError.missingRecord }
            let descriptor = try JSONDecoder().decode(BitcoinWalletDescriptor.self, from: row["descriptor"])
            let selected = type ?? BitcoinAddressType(rawValue: row["preferredType"]) ?? descriptor.defaultType
            guard let branch = descriptor.branches.first(where: { $0.type == selected && $0.change == 0 }) ?? descriptor.branches.first(where: { $0.type == selected }) else { throw StoreError.invalidTransition }
            let highest = try Int.fetchOne(db, sql: "SELECT MAX(addressIndex) FROM bitcoinAddresses WHERE accountID=? AND branchID=? AND used=1", arguments: [accountID, branch.id]) ?? -1
            let index = branch.isHD ? UInt32(highest + 1) : 0
            let address = try BitcoinKeys.addresses(branch: branch, range: index..<(index + 1))[0]
            try Self.saveBitcoinAddress(address, accountID: accountID, used: false, db: db)
            try db.execute(sql: "UPDATE bitcoinAddresses SET issued=1 WHERE accountID=? AND branchID=? AND addressIndex=?", arguments: [accountID, branch.id, index])
            try db.execute(sql: "UPDATE bitcoinWallets SET preferredType=? WHERE accountID=?", arguments: [selected.rawValue, accountID])
            return address
        }
    }

    /// Public generated addresses, including unused lookahead, issued receive
    /// addresses and discovered change. Keyset pagination has no total cap.
    /// Search scans the indexed account/branch range on the database queue,
    /// stopping at a page of matches instead of filtering only the first page.
    public func bitcoinAddresses(accountID: String, branchID: String, after: UInt32? = nil,
                                 limit: Int = 50, search: BitcoinAddressSearch = .init()) async throws -> [BitcoinDerivedAddress] {
        try await pool.read { db in
            let cursor = try Data.fetchCursor(db, sql: """
                SELECT detail FROM bitcoinAddresses
                WHERE accountID=? AND branchID=? AND addressIndex>?
                ORDER BY addressIndex
                """, arguments: [accountID, branchID, after.map(Int64.init) ?? -1])
            var matches: [BitcoinDerivedAddress] = []
            let decoder = JSONDecoder()
            while matches.count < max(1, min(limit, 200)), let data = try cursor.next() {
                try Task.checkCancellation()
                let address = try decoder.decode(BitcoinDerivedAddress.self, from: data)
                if search.matches(address) { matches.append(address) }
            }
            return matches
        }
    }

    public func bitcoinAddress(accountID: String, branchID: String, index: UInt32) async throws -> BitcoinDerivedAddress? {
        try await pool.read { db in
            try Data.fetchOne(db, sql: "SELECT detail FROM bitcoinAddresses WHERE accountID=? AND branchID=? AND addressIndex=?",
                             arguments: [accountID, branchID, index])
                .map { try JSONDecoder().decode(BitcoinDerivedAddress.self, from: $0) }
        }
    }

    public func beginBitcoinScan(accountID: String) async throws -> String {
        let id = UUID().uuidString
        try await pool.write { db in
            try db.execute(sql: "UPDATE bitcoinWallets SET scanID=?,failure=NULL WHERE accountID=?", arguments: [id, accountID])
            guard db.changesCount == 1 else { throw StoreError.missingRecord }
        }
        return id
    }

    public func failBitcoinScan(accountID: String, scanID: String, code: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE bitcoinWallets SET scanID=NULL,failure=? WHERE accountID=? AND scanID=?", arguments: [String(code.prefix(64)), accountID, scanID])
        }
    }

    public func commitBitcoinScan(accountID: String, scanID: String, scan: BitcoinScan,
                                  transactions: [String: Data], tipHeight: Int64) async throws {
        guard tipHeight > 0, let state = try await bitcoinState(accountID: accountID) else { throw StoreError.missingRecord }
        try scan.validate(wallet: state.descriptor, requiredThrough: state.requiredThrough)
        guard scan.addresses.allSatisfy({ $0.state.history.allSatisfy { $0.height <= tipHeight } && $0.state.unspent.allSatisfy { $0.height <= tipHeight } }) else {
            throw BitcoinError.inconsistentSnapshot
        }
        try await pool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM bitcoinWallets WHERE accountID=? AND scanID=?", arguments: [accountID, scanID]),
                  let account = try AccountRecord.fetchOne(db, key: accountID) else { throw StoreError.staleSync }
            let descriptor = try JSONDecoder().decode(BitcoinWalletDescriptor.self, from: row["descriptor"])
            guard descriptor == state.descriptor, scan.total >= 0 else { throw StoreError.invalidTransition }
            let now = scan.completedAt.timeIntervalSince1970
            let network = descriptor.network.rawValue
            guard account.networkID == network else { throw StoreError.conflictingIdentity }
            // Scoped replacement: never mark another wallet's outputs spent.
            // The same outpoint can belong to multiple imported wallets and has
            // one shared reservation in the existing send ledger.
            try db.execute(sql: """
                UPDATE utxos SET spent=1,updatedAt=? WHERE networkID=? AND (transactionHash,outputIndex) IN
                    (SELECT transactionHash,outputIndex FROM accountUTXOs WHERE accountID=? AND networkID=?);
                """, arguments: [now, network, accountID, network])
            try db.execute(sql: "DELETE FROM bitcoinHistory WHERE accountID=?", arguments: [accountID])
            var history: [String: Int64] = [:]
            for record in scan.addresses {
                let address = record.address
                try Self.saveBitcoinAddress(address, accountID: accountID, used: !record.state.history.isEmpty, db: db)
                for item in record.state.history { history[item.txid] = max(history[item.txid] ?? -1, item.height) }
                for output in record.state.unspent {
                    // Require the serialized funding transaction to match both
                    // value and script before making an output spendable.
                    guard let raw = try transactions[output.txid] ?? Data.fetchOne(db, sql: "SELECT raw FROM bitcoinTransactions WHERE accountID=? AND txid=?", arguments: [accountID, output.txid]),
                          try BitcoinTransactions.validates(raw, txid: output.txid, vout: output.vout, value: output.value, script: address.script, network: descriptor.network) else { throw StoreError.invalidTransition }
                    try db.execute(sql: """
                        INSERT INTO utxos(networkID,transactionHash,outputIndex,value,script,blockHeight,spent,reservedBy,updatedAt)
                        VALUES(?,?,?,?,?,?,0,NULL,?)
                        ON CONFLICT(networkID,transactionHash,outputIndex) DO UPDATE SET value=excluded.value,script=excluded.script,
                            blockHeight=excluded.blockHeight,spent=0,updatedAt=excluded.updatedAt
                        """, arguments: [network, output.txid, output.vout, output.value, address.script, output.height > 0 ? output.height : nil, now])
                    try db.execute(sql: "INSERT OR IGNORE INTO accountUTXOs(accountID,networkID,transactionHash,outputIndex) VALUES(?,?,?,?)", arguments: [accountID, network, output.txid, output.vout])
                }
            }
            for (txid, height) in history {
                try db.execute(sql: "INSERT INTO bitcoinHistory(accountID,txid,height) VALUES(?,?,?)", arguments: [accountID, txid, height])
            }
            for (txid, raw) in transactions {
                guard try BitcoinTransactions.txid(raw, network: descriptor.network) == txid else { throw StoreError.invalidTransition }
                try db.execute(sql: "INSERT OR IGNORE INTO bitcoinTransactions(accountID,txid,raw) VALUES(?,?,?)", arguments: [accountID, txid, raw])
            }
            // The display balance is confirmed + the signed mempool delta.
            // Pending incoming/change counts immediately; pending spends subtract
            // their inputs, so they cannot be counted again as confirmed funds.
            try BalanceRecord(accountID: accountID, assetID: network + ":native", networkID: network, amountAtomic: String(scan.total),
                              observedAt: now, source: "electrum").save(db)
            try db.execute(sql: "UPDATE bitcoinWallets SET scanID=NULL,failure=NULL,lastSuccess=?,confirmed=?,unconfirmed=?,tipHeight=? WHERE accountID=?",
                           arguments: [now, scan.confirmed, scan.unconfirmed, tipHeight, accountID])
            _ = account
        }
    }

    public func bitcoinMissingTransactions(accountID: String, txids: Set<String>) async throws -> [String] {
        guard !txids.isEmpty else { return [] }
        return try await pool.read { db in
            let ids = txids.sorted()
            var missing = txids
            for start in stride(from: 0, to: ids.count, by: 300) {
                let batch = ids[start..<min(start + 300, ids.count)]
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let saved = try String.fetchAll(db, sql: "SELECT txid FROM bitcoinTransactions WHERE accountID=? AND txid IN (\(placeholders))",
                                                arguments: StatementArguments([accountID] + batch))
                missing.subtract(saved)
            }
            return missing.sorted()
        }
    }

    /// Unified, wallet-wide coin pool, including confirmed and zero-confirmation
    /// incoming/change outputs, regardless of the Receive type or network. A send
    /// must have fresh verified discovery before reserving these outputs. Existing global
    /// outpoint reservations prevent two wallets from spending the same coin.
    public func bitcoinSpendableOutputs(walletID: String, now: Date = .now, network: UTXONetwork = .bitcoin) async throws -> [BitcoinSpendableOutput] {
        try await pool.read { db in
            try Self.bitcoinSpendableOutputs(walletID: walletID, now: now, network: network, db: db)
        }
    }

    static func bitcoinSpendableOutputs(walletID: String, now: Date, network: UTXONetwork = .bitcoin, accountID: String? = nil, db: Database) throws -> [BitcoinSpendableOutput] {
        guard try bitcoinFundingDeadline(walletID: walletID, network: network, accountID: accountID, now: now, db: db) != nil
        else { throw StoreError.staleSync }
        return try storedBitcoinOutputs(walletID: walletID, network: network, accountID: accountID, db: db)
    }

    private static func bitcoinFundingDeadline(walletID: String, network: UTXONetwork, accountID: String?,
                                               now: Date, db: Database) throws -> Date? {
        let rows = try Row.fetchAll(db, sql: """
            SELECT w.lastSuccess,w.failure,w.scanID,w.tipHeight FROM walletAccounts a
            LEFT JOIN bitcoinWallets w ON w.accountID=a.id
            WHERE a.walletID=? AND a.networkID=? AND (? IS NULL OR a.id=?)
            """, arguments: [walletID, network.rawValue, accountID, accountID])
        guard !rows.isEmpty else { throw StoreError.missingRecord }
        var deadline = Date.distantFuture
        for row in rows {
            guard let success: Double = row["lastSuccess"], let tip: Int64 = row["tipHeight"], tip > 0 else { throw StoreError.staleSync }
            if (row["failure"] as String?) != nil || (row["scanID"] as String?) != nil || success > now.timeIntervalSince1970 {
                deadline = .distantPast
            } else {
                deadline = min(deadline, Date(timeIntervalSince1970: success + 120))
            }
        }
        return deadline >= now ? deadline : nil
    }

    private static func storedBitcoinOutputs(walletID: String, network: UTXONetwork, accountID: String?, db: Database) throws -> [BitcoinSpendableOutput] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT u.*,o.accountID,d.detail,t.raw,w.tipHeight FROM walletAccounts a
            JOIN accountUTXOs o ON o.accountID=a.id
            JOIN utxos u ON u.networkID=o.networkID AND u.transactionHash=o.transactionHash AND u.outputIndex=o.outputIndex
            JOIN bitcoinAddresses d ON d.accountID=a.id AND d.script=u.script
            JOIN bitcoinWallets w ON w.accountID=a.id
            JOIN bitcoinTransactions t ON t.accountID=a.id AND t.txid=u.transactionHash
            WHERE a.walletID=? AND a.networkID=? AND u.spent=0 AND u.reservedBy IS NULL
              AND (? IS NULL OR a.id=?)
            ORDER BY u.value DESC,u.transactionHash,u.outputIndex
            """, arguments: [walletID, network.rawValue, accountID, accountID])
        var seen = Set<String>()
        return try rows.compactMap { row in
            let output = try UTXORecord(row: row)
            let raw: Data = row["raw"]
            // Keep CashToken-bearing BCH in balances/history, but never hand it
            // to the ordinary BCH spending pool: that could destroy the token.
            guard try !BitcoinTransactions.hasTokens(raw, vout: output.outputIndex, network: network) else { return nil }
            guard let tip: Int64 = row["tipHeight"],
                  try network.permitsSpending(blockHeight: output.blockHeight, tipHeight: tip,
                                             isCoinbase: BitcoinTransactions.isCoinbase(raw, network: network),
                                             isPegout: BitcoinTransactions.isPegout(raw, vout: output.outputIndex, network: network)) else { return nil }
            guard seen.insert("\(output.transactionHash):\(output.outputIndex)").inserted else { return nil }
            return BitcoinSpendableOutput(output: output,
                derivation: try JSONDecoder().decode(BitcoinDerivedAddress.self, from: row["detail"]), previousTransaction: raw)
        }
    }

    public func dogecoinSpendableOutputs(walletID: String, now: Date = .now) async throws -> [BitcoinSpendableOutput] {
        try await bitcoinSpendableOutputs(walletID: walletID, now: now, network: .dogecoin)
    }

    public func bitcoinHistory(accountID: String, limit: Int = 50, offset: Int = 0) async throws -> [BitcoinHistoryItem] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT txid,height FROM bitcoinHistory WHERE accountID=? ORDER BY CASE WHEN height<=0 THEN 1 ELSE 0 END DESC,height DESC,txid LIMIT ? OFFSET ?",
                             arguments: [accountID, max(1, min(limit, 200)), max(0, offset)]).map { .init(txid: $0["txid"], height: $0["height"]) }
        }
    }

    static func saveBitcoinAddress(_ address: BitcoinDerivedAddress, accountID: String, used: Bool, db: Database) throws {
        if let old = try String.fetchOne(db, sql: "SELECT scriptHash FROM bitcoinAddresses WHERE accountID=? AND branchID=? AND addressIndex=?", arguments: [accountID, address.branchID, address.index]), old != address.scriptHash { throw StoreError.conflictingIdentity }
        try db.execute(sql: """
            INSERT INTO bitcoinAddresses(accountID,branchID,addressIndex,address,script,scriptHash,detail,used,issued) VALUES(?,?,?,?,?,?,?,?,0)
            ON CONFLICT(accountID,branchID,addressIndex) DO UPDATE SET used=MAX(bitcoinAddresses.used,excluded.used)
            """, arguments: [accountID, address.branchID, address.index, address.address, address.script, address.scriptHash, try JSONEncoder().encode(address), used])
    }
}
