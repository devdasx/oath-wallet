import Foundation
import GRDB
import OathBitcoin
import OathAnkr
import OathDiagnostics

/// One decoded input/output. Repeated addresses retain their distinct positions.
public struct TransactionEndpoint: Equatable, Sendable, Identifiable {
    public let id: String
    public let address: String?
    public let amountAtomic: String?
    public let dataOutput: BitcoinDataOutput?
    public init(id: String, address: String?, amountAtomic: String? = nil, dataOutput: BitcoinDataOutput? = nil) {
        self.id = id; self.address = address; self.amountAtomic = amountAtomic; self.dataOutput = dataOutput
    }
}

/// Wallet-scoped details with the actual fee currency where the chain supports it.
public struct TransactionDetails: Equatable, Sendable {
    public let transaction: TransactionRecord
    /// Account-scoped cancellation/replacement evidence takes precedence over
    /// the original transaction's raw pending state, just as in history rows.
    public let state: String
    public let transfers: [TransferRecord]
    public let fromAddresses: [String]
    public let toAddresses: [String]
    public let feeAsset: AssetRecord?
    public let replacementHash: String?
    /// Current cached value in the requested display currency. Missing market
    /// data stays unknown; a missing price must never turn a paid fee into zero.
    public let feeFiatValue: Decimal?
    /// Observed block depth for height-based chains. Nil means the provider has
    /// not supplied a usable head, or the chain reports finality instead.
    public var confirmations: Int64? = nil
    public var inputs: [TransactionEndpoint]? = nil
    public var outputs: [TransactionEndpoint]? = nil
    /// Refreshed account-scoped amounts use the same fee ownership rules as history.
    public var swap: ChainHistoryItem? = nil
    public var historyEntries: [HistoryEntry] = []
}

extension OathDatabase {
    public func transactionDetails(accountID: String, transactionID: String, currency: String = "USD") async throws -> TransactionDetails? {
        try await pool.read { db in
            try Self.transactionDetails(db, accountID: accountID, transactionID: transactionID, currency: currency)
        }
    }

    public func observeTransactionDetails(accountID: String, transactionID: String, currency: String) -> AsyncThrowingStream<TransactionDetails?, Error> {
        stream { db in
            try Self.transactionDetails(db, accountID: accountID, transactionID: transactionID, currency: currency)
        }
    }

    static func transactionDetails(_ db: Database, accountID: String, transactionID: String, currency: String, publicOwner: String? = nil, includeHiddenActivity: Bool = false) throws -> TransactionDetails? {
        let activitySource = includeHiddenActivity ? "activity" : "visibleActivity"
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(activitySource) WHERE accountID=? AND transactionID=?)", arguments: [accountID, transactionID]) == true,
              var tx = try TransactionRecord.fetchOne(db, key: transactionID) else { return nil }
        var asset = try AssetRecord.fetchOne(db, sql: "SELECT * FROM assets WHERE networkID=? AND reference='native'", arguments: [tx.networkID])
        if tx.networkID == "celo",
           let raw = try Data.fetchOne(db, sql: "SELECT detail FROM indexedEVMEvents WHERE accountID=? AND id=?", arguments: [accountID, tx.hash + ":external"]) {
            let event = try JSONDecoder().decode(IndexedEVMEvent.self, from: raw)
            if let currency = event.feeCurrency, let amount = event.feeCurrencyAmount {
                tx.feeAtomic = amount
                asset = try AssetRecord.fetchOne(db, sql: "SELECT * FROM assets WHERE networkID='celo' AND reference=?", arguments: [currency.reference])
            }
        }
        let price: String? = try asset.flatMap {
            try String.fetchOne(db, sql: "SELECT value FROM prices WHERE assetID=? AND currency='USD' ORDER BY observedAt DESC LIMIT 1", arguments: [$0.id])
        }
        let exchangeRate = try Self.exchangeRates(db)?.rate(for: currency) ?? (currency == "USD" ? 1 : nil)
        var fiat: Decimal?
        if let fee = tx.feeAtomic, let asset,
           let units = try? AtomicAmount(fee).units(decimals: asset.decimals),
           let quantity = Decimal(string: units, locale: Locale(identifier: "en_US_POSIX")) {
            if quantity == 0 { fiat = 0 }
            else if let price, let usd = Decimal(string: price, locale: Locale(identifier: "en_US_POSIX")),
                    let exchangeRate, let localPrice = FiatConversion.multiply(usd, exchangeRate) {
                fiat = FiatConversion.multiply(quantity, localPrice)
            }
        }
        let outcome = try String.fetchOne(db, sql: "SELECT outcome FROM transactionEvidence WHERE accountID=? AND transactionID=?",
                                         arguments: [accountID, transactionID])
        let transfers = try TransferRecord.fetchAll(db, sql: """
            SELECT tr.* FROM transfers tr WHERE tr.transactionID=? AND EXISTS(
                SELECT 1 FROM \(activitySource) a WHERE a.transactionID=tr.transactionID
                    AND a.assetID=tr.assetID AND a.accountID=?) ORDER BY tr.eventIndex
            """, arguments: [transactionID, accountID])
        let parties = try transactionParties(db, accountID: accountID, transaction: tx, transfers: transfers, publicOwner: publicOwner, includeHiddenActivity: includeHiddenActivity)
        let entries = try HistoryEntry.fetchAll(db, sql: """
            SELECT a.id,a.accountID,a.networkID,a.transactionID,a.assetID,a.direction,
                   a.amountAtomic,a.counterparty,a.sortTimestamp AS timestamp,? AS state,? AS hash
            FROM \(activitySource) a WHERE a.accountID=? AND a.transactionID=?
            """, arguments: [outcome ?? tx.state, tx.hash, accountID, transactionID])
            .map { try Self.projectSelfTransferFee($0, db: db) }
        let wallet = try String.fetchOne(db, sql: "SELECT walletID FROM walletAccounts WHERE id=?", arguments: [accountID]) ?? ""
        let swap = try readChainHistory(db, walletID: wallet, networkID: tx.networkID, accountID: accountID,
            assetID: nil, currency: currency, before: nil, limit: 1, search: "", filter: .init(),
            localeIdentifier: "en_US_POSIX", transactionID: transactionID).first(where: { ["swap", "bridge", "bridgeIncoming", "bridgeOutgoing"].contains($0.entry.direction) })
        return TransactionDetails(transaction: tx, state: outcome ?? tx.state,
            transfers: transfers, fromAddresses: parties.from, toAddresses: parties.to,
            feeAsset: asset,
            replacementHash: try String.fetchOne(db, sql: "SELECT replacementHash FROM transactionEvidence WHERE accountID=? AND transactionID=?", arguments: [accountID, transactionID]),
            feeFiatValue: fiat,
            confirmations: try transactionConfirmations(db, accountID: accountID, transaction: tx, state: outcome ?? tx.state),
            inputs: parties.inputs, outputs: parties.outputs, swap: swap, historyEntries: entries)
    }

    private static func transactionConfirmations(_ db: Database, accountID: String,
                                                 transaction tx: TransactionRecord, state: String) throws -> Int64? {
        let utxo = UTXONetwork(rawValue: tx.networkID) != nil
        let evm = AnkrChain(networkID: tx.networkID) != nil ||
            ["arc", "robinhood", "hyperevm", "chiliz", "filecoin", "sei", "zerog", "iotex", "celo", "unichain", "monad"].contains(tx.networkID)
        // Slots, ledger versions and finality flags are not confirmation counts.
        guard utxo || evm, ["pending", "confirmed", "failed"].contains(state) else { return nil }
        if state == "pending" { return 0 }
        var head: Int64?
        var height = tx.blockHeight
        if utxo {
            head = try Int64.fetchOne(db, sql: "SELECT tipHeight FROM bitcoinWallets WHERE accountID=?", arguments: [accountID])
            height = try Int64.fetchOne(db, sql: "SELECT height FROM bitcoinHistory WHERE accountID=? AND txid=? AND height>0", arguments: [accountID, tx.hash]) ?? height
        } else {
            let table: String? = switch tx.networkID {
            case "arc": "arcSync"
            case "robinhood": "robinhoodSync"
            case "hyperevm": "hyperevmSync"
            case "chiliz", "filecoin", "sei", "zerog", "iotex", "celo", "unichain", "monad": "indexedEVMSync"
            default: nil
            }
            if let table {
                head = try Int64.fetchOne(db, sql: "SELECT checkpoint FROM \(table) WHERE accountID=?", arguments: [accountID])
            }
            for data in try Data.fetchAll(db, sql: "SELECT syncStatus FROM ankrSync WHERE accountID=? AND syncStatus IS NOT NULL", arguments: [accountID]) {
                let status = try JSONDecoder().decode(AnkrSyncStatus.self, from: data)
                if let observed = status.blockNumber { head = max(head ?? observed, observed) }
            }
        }
        guard let head, let height, height > 0, head >= height else { return nil }
        return head - height + 1
    }

    /// Public, offline receipt projection. A history row's single counterparty
    /// is intentionally blank for multi-party transactions; it is not the full
    /// sender/recipient record. Preserve every known address without choosing a
    /// random Bitcoin input or using an HD account's representative address.
    private static func transactionParties(_ db: Database, accountID: String, transaction tx: TransactionRecord,
                                          transfers: [TransferRecord], publicOwner: String? = nil, includeHiddenActivity: Bool = false) throws -> (from: [String], to: [String], inputs: [TransactionEndpoint]?, outputs: [TransactionEndpoint]?) {
        var from = Set(transfers.map(\.fromAddress).filter { !$0.isEmpty })
        var to = Set(transfers.map(\.toAddress).filter { !$0.isEmpty })
        if let network = UTXONetwork(rawValue: tx.networkID) {
            var inputs: [TransactionEndpoint]?, outputs: [TransactionEndpoint]?
            // A send is visible immediately after signing, before the indexer
            // stores its raw transaction. Read the durable, validated journal
            // without inserting synthetic indexer history or changing send state.
            // Wallet scope also covers sends funded by several of its accounts.
            let journal = try Row.fetchOne(db, sql: """
                SELECT s.signedPayload,p.plan FROM sends s
                JOIN bitcoinSendPlans p ON p.sendID=s.id
                JOIN walletAccounts a ON a.walletID=s.walletID AND a.networkID=s.networkID
                WHERE a.id=? AND s.networkID=? AND s.transactionID=?
                    AND s.signedPayload IS NOT NULL AND s.state IN ('signed','broadcast','confirmed','failed')
                ORDER BY s.createdAt,s.id LIMIT 1
                """, arguments: [accountID, tx.networkID, tx.id])
            let journalRaw: Data? = journal?["signedPayload"]
            let indexedRaw = try Data.fetchOne(db, sql: "SELECT raw FROM bitcoinTransactions WHERE accountID=? AND txid=?", arguments: [accountID, tx.hash])
            if let raw = indexedRaw ?? journalRaw {
                let details = try BitcoinTransactions.details(raw, network: network)
                guard details.txid == tx.hash else {
                    throw OathDiagnostics.failure(StoreError.conflictingIdentity, reason: "receipt_transaction_hash_mismatch")
                }
                inputs = []
                outputs = details.outputs.enumerated().map {
                    TransactionEndpoint(id: String($0.offset), address: $0.element.address,
                        amountAtomic: String($0.element.value), dataOutput: $0.element.dataOutput)
                }
                to.formUnion(details.outputs.compactMap(\.address))
                var parents: [String: BitcoinTransactions.Details] = [:]
                var journalPlan: BitcoinSendPlan?
                for input in details.inputs {
                    if parents[input.txid] == nil {
                        var parentRaw = try Data.fetchOne(db, sql: "SELECT raw FROM bitcoinTransactions WHERE accountID=? AND txid=?", arguments: [accountID, input.txid])
                        if parentRaw == nil, let bytes: Data = journal?["plan"] {
                            if journalPlan == nil {
                                journalPlan = try JSONDecoder().decode(BitcoinSendPlan.self, from: bytes)
                                guard journalPlan?.chain == network else {
                                    throw OathDiagnostics.failure(StoreError.conflictingIdentity, reason: "receipt_journal_chain_mismatch")
                                }
                            }
                            parentRaw = journalPlan?.coins.first { $0.id == input.outpoint }?.previousTransaction
                        }
                        if let parentRaw {
                            let parent = try BitcoinTransactions.details(parentRaw, network: network)
                            guard parent.txid == input.txid else {
                                throw OathDiagnostics.failure(StoreError.conflictingIdentity, reason: "receipt_parent_hash_mismatch")
                            }
                            parents[input.txid] = parent
                        }
                    }
                    let output = parents[input.txid].flatMap { $0.outputs.indices.contains(input.index) ? $0.outputs[input.index] : nil }
                    if let address = output?.address { from.insert(address) }
                    inputs?.append(TransactionEndpoint(id: input.outpoint, address: output?.address,
                        amountAtomic: output.map { String($0.value) }))
                }
            }
            // Missing parents and non-address scripts are unknown, not the
            // wallet's current receive address. Coinbase has no sender address.
            return (from.sorted(), to.sorted(), inputs, outputs)
        }
        guard let account = try AccountRecord.fetchOne(db, key: accountID) else { return (from.sorted(), to.sorted(), nil, nil) }
        let selectedSolana = tx.networkID == "solana" ? try publicOwner ?? String.fetchOne(db,
            sql: "SELECT address FROM solanaReceiveAddresses WHERE accountID=? AND isSelected=1", arguments: [accountID]) ?? account.address : nil
        func movement(_ direction: String, owner: String, peer: String?) {
            if direction == "incoming" { to.insert(owner); if let peer, !peer.isEmpty { from.insert(peer) } }
            else if direction == "outgoing" { from.insert(owner); if let peer, !peer.isEmpty { to.insert(peer) } }
            // A zero net balance change is not evidence of a self-transfer.
            else if direction == "self", peer == owner { from.insert(owner); to.insert(owner) }
        }
        let activitySource = includeHiddenActivity ? "activity" : "visibleActivity"
        for row in try ActivityRecord.fetchAll(db, sql: "SELECT * FROM \(activitySource) WHERE accountID=? AND transactionID=?", arguments: [accountID, tx.id]) {
            if tx.networkID == "solana" {
                // Solana derivations share an account record. Match the owner
                // attached to this activity, never its representative address.
                if let owner = try String.fetchOne(db, sql: "SELECT owner FROM solanaActivity WHERE activityID=?", arguments: [row.id]),
                   owner == selectedSolana { movement(row.direction, owner: owner, peer: row.counterparty) }
            } else { movement(row.direction, owner: account.address, peer: row.counterparty) }
        }
        let decoder = JSONDecoder()
        if tx.networkID == "stellar" {
            for data in try Data.fetchAll(db, sql: "SELECT detail FROM stellarEvents WHERE accountID=? AND hash=?", arguments: [accountID, tx.hash]) {
                let event = try decoder.decode(StellarEvent.self, from: data)
                if event.kind != "fee" { movement(event.direction, owner: account.address, peer: event.counterparty) }
            }
        } else if tx.networkID == "aptos",
                  let data = try Data.fetchOne(db, sql: "SELECT detail FROM aptosTransactions WHERE accountID=? AND hash=?", arguments: [accountID, tx.hash]) {
            let detail = try decoder.decode(AptosTransaction.self, from: data)
            for event in detail.events { movement(event.direction, owner: event.owner, peer: nil) }
            let parties = try AptosDecoding.parties(detail)
            from.formUnion(parties.from); to.formUnion(parties.to)
        } else if tx.networkID == "solana", let owner = selectedSolana,
                  let data = try Data.fetchOne(db, sql: "SELECT detail FROM solanaTransactions WHERE accountID=? AND owner=? AND signature=?", arguments: [accountID, owner, tx.hash]) {
            let detail = try decoder.decode(SolanaTransaction.self, from: data)
            for change in detail.changes { movement(change.direction, owner: owner, peer: change.counterparty) }
            let parties = try SolanaDecoding.parties(detail, owner: owner)
            from.formUnion(parties.from); to.formUnion(parties.to)
        } else if tx.networkID == "sui",
                  let data = try Data.fetchOne(db, sql: "SELECT detail FROM suiTransactions WHERE accountID=? AND hash=?", arguments: [accountID, tx.hash]) {
            let detail = try decoder.decode(SuiTransaction.self, from: data)
            let parties = try SuiDecoding.parties(detail)
            from.formUnion(parties.from); to.formUnion(parties.to)
        } else if tx.networkID == "tron",
                  let data = try Data.fetchOne(db, sql: "SELECT detail FROM tronTransactions WHERE accountID=? AND hash=?", arguments: [accountID, tx.hash]) {
            // Retain receipt endpoints even for interaction-only history rows.
            // Failed transfers have no emitted events, but still have a caller
            // and an attempted destination in the cached transaction body.
            let detail = try decoder.decode(TronTransaction.self, from: data)
            let owner = try TronIdentity.address(account.address)
            for event in detail.events where event.amount != "0" && (event.from == owner || event.to == owner) {
                from.insert(event.from); to.insert(event.to)
            }
            if from.isEmpty && to.isEmpty {
                from.insert(detail.payer)
                let raw = try decoder.decode(TronJSON.self, from: detail.raw)["transaction"]
                for contract in raw["raw_data"]["contract"].array ?? [] {
                    let value = contract["parameter"]["value"]
                    switch contract["type"].string {
                    case "TransferContract", "TransferAssetContract":
                        if let address = value["to_address"].string { to.insert(try TronIdentity.address(address)) }
                    case "TriggerSmartContract":
                        if let address = value["contract_address"].string { to.insert(try TronIdentity.address(address)) }
                    default: break // A permission/voting operation need not have a recipient.
                    }
                }
            }
        } else if tx.networkID == "near", from.isEmpty && to.isEmpty,
                  let data = try Data.fetchOne(db, sql: "SELECT detail FROM nearTransactions WHERE accountID=? AND hash=?", arguments: [accountID, tx.hash]) {
            // Contract-only/failed actions have no transfer event. Their cached
            // execution still identifies the caller and destination contract.
            // Do not mix that contract into a token transfer's recipient list.
            let detail = try decoder.decode(NearExecution.self, from: data)
            let raw = try decoder.decode(NearJSON.self, from: detail.raw)["transaction"]
            if let hash = raw["hash"].string {
                guard hash == tx.hash else { throw NearError.malformed }
                if let sender = raw["signer_id"].string { from.insert(try NearIdentity.address(sender)) }
                if let recipient = raw["receiver_id"].string { to.insert(try NearIdentity.address(recipient)) }
            }
        } else if tx.networkID == "xrpl",
                  let data = try Data.fetchOne(db, sql: "SELECT detail FROM xrplTransactions WHERE accountID=? AND hash=?", arguments: [accountID, tx.hash]) {
            let detail = try decoder.decode(XrplTransaction.self, from: data)
            let raw = try decoder.decode(XrplJSON.self, from: detail.raw)["tx_json"]
            if let sender = raw["Account"].string { from.insert(try XrplIdentity.address(sender)) }
            if ["Payment", "AccountDelete"].contains(raw["TransactionType"].string ?? ""), let destination = raw["Destination"].string {
                to.insert(try XrplIdentity.address(destination))
            }
        }
        // Imported EVM accounts may retain their checksummed spelling while
        // indexed transfers use lowercase. They are one address, not two peers.
        let isEVM = try String.fetchOne(db, sql: "SELECT family FROM networks WHERE id=?", arguments: [tx.networkID]) == "evm"
        func unique(_ addresses: Set<String>) -> [String] {
            Set(addresses.filter { !$0.isEmpty }.map { isEVM && AnkrQuantity.address($0) ? $0.lowercased() : $0 }).sorted()
        }
        return (unique(from), unique(to), nil, nil)
    }

    /// A conflict key is an actual spent outpoint, or an EVM sender + nonce.
    /// Only a mined competitor settles the outcome. Missing history alone is
    /// not evidence of cancellation; ordinary self-transfers are not cancels.
    static func saveTransactionEvidence(accountID: String, tx: TransactionRecord, keys: Set<String>, returnsToWallet: Bool, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO transactionEvidence(accountID,transactionID,conflictKeys,returnsToWallet) VALUES(?,?,?,?)
            ON CONFLICT(accountID,transactionID) DO UPDATE SET conflictKeys=excluded.conflictKeys,returnsToWallet=excluded.returnsToWallet
            WHERE transactionEvidence.conflictKeys IS NOT excluded.conflictKeys
               OR transactionEvidence.returnsToWallet IS NOT excluded.returnsToWallet
            """, arguments: [accountID, tx.id, try JSONEncoder().encode(keys.sorted()), returnsToWallet])
        // Overlapping history refreshes revisit confirmed transactions. Keep
        // the same evidence/index without deleting and reinserting every key.
        // Reconciliation below still runs when a receipt or competitor changes.
        let existingKeys = Set(try String.fetchAll(db,
            sql: "SELECT conflictKey FROM transactionConflictKeys WHERE accountID=? AND transactionID=?",
            arguments: [accountID, tx.id]))
        for key in existingKeys.subtracting(keys) {
            try db.execute(sql: "DELETE FROM transactionConflictKeys WHERE accountID=? AND transactionID=? AND conflictKey=?",
                arguments: [accountID, tx.id, key])
        }
        for key in keys.subtracting(existingKeys) {
            try db.execute(sql: "INSERT INTO transactionConflictKeys(accountID,transactionID,conflictKey) VALUES(?,?,?)", arguments: [accountID, tx.id, key])
        }
        // Reconcile in both arrival orders (historical pages may arrive newest first).
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.*,t.state,t.hash,t.timestamp FROM transactionEvidence e JOIN transactions t ON t.id=e.transactionID
            WHERE e.accountID=? AND t.networkID=? AND e.transactionID IN (
                SELECT other.transactionID FROM transactionConflictKeys mine
                JOIN transactionConflictKeys other ON other.accountID=mine.accountID AND other.conflictKey=mine.conflictKey
                WHERE mine.accountID=? AND mine.transactionID=?)
            """, arguments: [accountID, tx.networkID, accountID, tx.id])
        let decoder = JSONDecoder()
        for old in rows {
            let oldID: String = old["transactionID"], oldState: String = old["state"]
            guard oldState != "confirmed", oldState != "failed" else { continue }
            try db.execute(sql: "UPDATE transactionEvidence SET outcome=NULL,replacementHash=NULL,outcomeAt=NULL WHERE accountID=? AND transactionID=? AND (outcome IS NOT NULL OR replacementHash IS NOT NULL OR outcomeAt IS NOT NULL)", arguments: [accountID, oldID])
            let oldKeys = try decoder.decode(Set<String>.self, from: old["conflictKeys"])
            guard !oldKeys.isEmpty else { continue }
            for winner in rows where (winner["state"] as String) == "confirmed" || (winner["state"] as String) == "failed" {
                let winnerID: String = winner["transactionID"]
                guard winnerID != oldID else { continue }
                let winnerKeys = try decoder.decode(Set<String>.self, from: winner["conflictKeys"])
                guard !oldKeys.isDisjoint(with: winnerKeys) else { continue }
                let canceled = (winner["returnsToWallet"] as Bool) && (winner["state"] as String) == "confirmed"
                try db.execute(sql: "UPDATE transactionEvidence SET outcome=?,replacementHash=?,outcomeAt=? WHERE accountID=? AND transactionID=?",
                    arguments: [canceled ? "canceled" : "replaced", winner["hash"] as String, winner["timestamp"] as Double, accountID, oldID])
                break
            }
        }
        if tx.state == "confirmed" || tx.state == "failed" {
            try db.execute(sql: "UPDATE transactionEvidence SET outcome=NULL,replacementHash=NULL,outcomeAt=NULL WHERE accountID=? AND transactionID=? AND (outcome IS NOT NULL OR replacementHash IS NOT NULL OR outcomeAt IS NOT NULL)", arguments: [accountID, tx.id])
        }
    }
}
