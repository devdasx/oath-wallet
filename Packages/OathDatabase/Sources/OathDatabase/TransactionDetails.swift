import Foundation
import GRDB
import OathBitcoin
import OathAnkr
import OathDiagnostics

/// One decoded input/output. Repeated addresses retain their distinct positions.
public struct TransactionEndpoint: Equatable, Sendable, Identifiable {
    public enum Ownership: Equatable, Sendable { case unrecognized, owned, change }
    public let ownership: Ownership
    public let id: String
    public let address: String?
    public let amountAtomic: String?
    public let dataOutput: BitcoinDataOutput?
    public init(id: String, address: String?, amountAtomic: String? = nil, dataOutput: BitcoinDataOutput? = nil,
                ownership: Ownership = .unrecognized) {
        self.ownership = ownership
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
    public var totalAmount: TransactionReceiptTotal? = nil
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
        let exchangeRate = try Self.exchangeRates(db)?.rate(for: currency) ?? (currency == "USD" ? 1 : nil)
        func value(_ amount: AtomicAmount, _ asset: AssetRecord) throws -> Decimal? {
            if amount.rawValue == "0" { return 0 }
            let locale = Locale(identifier: "en_US_POSIX")
            guard let exchangeRate, let units = try? amount.units(decimals: asset.decimals),
                  let quantity = Decimal(string: units, locale: locale),
                  let price = try String.fetchOne(db, sql: "SELECT value FROM prices WHERE assetID=? AND currency='USD' ORDER BY observedAt DESC LIMIT 1", arguments: [asset.id]),
                  let usd = Decimal(string: price, locale: locale),
                  let localPrice = FiatConversion.multiply(usd, exchangeRate) else { return nil }
            return FiatConversion.multiply(quantity, localPrice)
        }
        let fiat = try asset.flatMap { asset in
            try tx.feeAtomic.flatMap { try? AtomicAmount($0) }.flatMap { try value($0, asset) }
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
        let state = outcome ?? tx.state
        let total = try receiptTotal(db, transaction: tx, state: state, entries: entries, transfers: transfers,
                                     feeAsset: asset, parties: parties, value: value)
        return TransactionDetails(transaction: tx, state: state,
            transfers: transfers, fromAddresses: parties.from, toAddresses: parties.to,
            feeAsset: asset,
            replacementHash: try String.fetchOne(db, sql: "SELECT replacementHash FROM transactionEvidence WHERE accountID=? AND transactionID=?", arguments: [accountID, transactionID]),
            feeFiatValue: fiat, totalAmount: total,
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

    /// Match public locking scripts across accounts of this wallet on this chain.
    /// Page the indexed lookups so even consolidation receipts fit SQLite's bind limit.
    private static func bitcoinReceiptOwnership(_ db: Database, accountID: String, network: UTXONetwork,
                                                scripts: Set<String>) throws -> [String: TransactionEndpoint.Ownership] {
        guard !scripts.isEmpty else { return [:] }
        var roles: [String: TransactionEndpoint.Ownership] = [:]
        let accounts = try Row.fetchAll(db, sql: """
            SELECT id,address FROM walletAccounts
            WHERE walletID=(SELECT walletID FROM walletAccounts WHERE id=?) AND networkID=?
            """, arguments: [accountID, network.rawValue])
        let keys = Array(scripts)
        for account in accounts {
            // Older accounts can have a public receive address before discovery runs.
            if let bytes = try? BitcoinSendPlan.recipientScript(account["address"], chain: network) {
                let script = bytes.map { String(format: "%02x", $0) }.joined()
                if scripts.contains(script), roles[script] == nil { roles[script] = .owned }
            }
            for start in stride(from: 0, to: keys.count, by: 400) {
                let batch = keys[start..<min(start + 400, keys.count)]
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let records = try Data.fetchAll(db, sql: """
                    SELECT detail FROM bitcoinAddresses WHERE accountID=? AND script IN (\(placeholders))
                    """, arguments: StatementArguments([account["id"] as String] + batch))
                for record in records {
                    let address = try JSONDecoder().decode(BitcoinDerivedAddress.self, from: record)
                    if address.change == 1 { roles[address.script] = .change }
                    else if roles[address.script] == nil { roles[address.script] = .owned }
                }
            }
        }
        return roles
    }

    /// Public, offline receipt projection. A history row's single counterparty
    /// is intentionally blank for multi-party transactions; it is not the full
    /// sender/recipient record. Preserve every known address without choosing a
    /// random Bitcoin input or using an HD account's representative address.
    private static func transactionParties(_ db: Database, accountID: String, transaction tx: TransactionRecord,
                                          transfers: [TransferRecord], publicOwner: String? = nil, includeHiddenActivity: Bool = false) throws -> ReceiptParties {
        var from = Set(transfers.map(\.fromAddress).filter { !$0.isEmpty })
        var to = Set(transfers.map(\.toAddress).filter { !$0.isEmpty })
        if let network = UTXONetwork(rawValue: tx.networkID) {
            var inputs: [TransactionEndpoint]?, outputs: [TransactionEndpoint]?
            var signedRecipientAmount: String?
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
            func indexedTransaction(_ hash: String) throws -> Data? {
                // A parent can have been indexed under a sibling account that received the coin.
                try Data.fetchOne(db, sql: """
                    SELECT t.raw FROM walletAccounts a JOIN bitcoinTransactions t ON t.accountID=a.id
                    WHERE a.walletID=(SELECT walletID FROM walletAccounts WHERE id=?) AND a.networkID=? AND t.txid=?
                    ORDER BY t.accountID=? DESC LIMIT 1
                    """, arguments: [accountID, tx.networkID, hash, accountID])
            }
            let indexedRaw = try indexedTransaction(tx.hash)
            if let raw = indexedRaw ?? journalRaw {
                let details = try BitcoinTransactions.details(raw, network: network)
                guard details.txid == tx.hash else {
                    throw OathDiagnostics.failure(StoreError.conflictingIdentity, reason: "receipt_transaction_hash_mismatch")
                }
                let journalPlan: BitcoinSendPlan? = try (journal?["plan"] as Data?).map {
                    let plan = try JSONDecoder().decode(BitcoinSendPlan.self, from: $0)
                    guard plan.chain == network else {
                        throw OathDiagnostics.failure(StoreError.conflictingIdentity, reason: "receipt_journal_chain_mismatch")
                    }
                    return plan
                }
                to.formUnion(details.outputs.compactMap(\.address))
                var parents: [String: BitcoinTransactions.Details] = [:]
                var prevouts: [BitcoinTransactions.Output?] = []
                for input in details.inputs {
                    if parents[input.txid] == nil {
                        var parentRaw = try indexedTransaction(input.txid)
                        if parentRaw == nil {
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
                    prevouts.append(output)
                }
                let scripts = Set(details.outputs.filter { $0.address != nil }.map(\.script))
                    .union(prevouts.compactMap { $0?.script })
                let roles = try bitcoinReceiptOwnership(db, accountID: accountID, network: network, scripts: scripts)
                inputs = zip(details.inputs, prevouts).map { input, output in
                    TransactionEndpoint(id: input.outpoint, address: output?.address, amountAtomic: output.map { String($0.value) },
                                        ownership: output.flatMap { roles[$0.script] } ?? .unrecognized)
                }
                let changeIndex = journalPlan?.outputs.firstIndex(where: \.isChange)
                signedRecipientAmount = journalPlan.map { String($0.recipientAmount) }
                outputs = details.outputs.enumerated().map { index, output in
                    var role = roles[output.script] ?? .unrecognized
                    if let journalPlan {
                        // A single-key wallet can pay and receive change on the same script.
                        if index == changeIndex, output.script == journalPlan.change.script, output.value == journalPlan.changeAmount {
                            role = .change
                        } else if role == .change {
                            role = .owned
                        }
                    }
                    return TransactionEndpoint(id: String(index), address: output.address, amountAtomic: String(output.value),
                                               dataOutput: output.dataOutput, ownership: role)
                }
            }
            // Missing parents and non-address scripts are unknown, not the
            // wallet's current receive address. Coinbase has no sender address.
            return ReceiptParties(from: from.sorted(), to: to.sorted(), senderFee: tx.feeAtomic, inputs: inputs, outputs: outputs,
                                 signedRecipientAmount: signedRecipientAmount)
        }
        guard let account = try AccountRecord.fetchOne(db, key: accountID) else { return ReceiptParties(from: from.sorted(), to: to.sorted(), senderFee: nil) }
        let selectedSolana = tx.networkID == "solana" ? try publicOwner ?? String.fetchOne(db,
            sql: "SELECT address FROM solanaReceiveAddresses WHERE accountID=? AND isSelected=1", arguments: [accountID]) ?? account.address : nil
        var scopedEntryIDs: Set<String>? = selectedSolana == nil ? nil : []
        var senderFee = tx.feeAtomic
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
                   owner == selectedSolana {
                    scopedEntryIDs?.insert(row.id)
                    movement(row.direction, owner: owner, peer: row.counterparty)
                }
            } else { movement(row.direction, owner: account.address, peer: row.counterparty) }
        }
        let decoder = JSONDecoder()
        if tx.networkID == "stellar" {
            var paidFee: String?
            for data in try Data.fetchAll(db, sql: "SELECT detail FROM stellarEvents WHERE accountID=? AND hash=?", arguments: [accountID, tx.hash]) {
                let event = try decoder.decode(StellarEvent.self, from: data)
                if event.kind == "fee" {
                    try Validation.amount(event.amount.hasPrefix("-") ? String(event.amount.dropFirst()) : event.amount)
                    paidFee = StellarIdentity.sum(paidFee ?? "0", event.amount)
                } else {
                    movement(event.direction, owner: account.address, peer: event.counterparty)
                }
            }
            senderFee = paidFee ?? senderFee
        } else if tx.networkID == "aptos",
                  let data = try Data.fetchOne(db, sql: "SELECT detail FROM aptosTransactions WHERE accountID=? AND hash=?", arguments: [accountID, tx.hash]) {
            let detail = try decoder.decode(AptosTransaction.self, from: data)
            let payer = try decoder.decode(AptosJSON.self, from: detail.raw)["receipt"]["signature"]["fee_payer_address"].string
            if let payer, try AptosIdentity.address(payer) != AptosIdentity.address(detail.sender) { senderFee = "0" }
            for event in detail.events { movement(event.direction, owner: event.owner, peer: nil) }
            let parties = try AptosDecoding.parties(detail)
            from.formUnion(parties.from); to.formUnion(parties.to)
        } else if tx.networkID == "solana", let owner = selectedSolana,
                  let data = try Data.fetchOne(db, sql: "SELECT detail FROM solanaTransactions WHERE accountID=? AND owner=? AND signature=?", arguments: [accountID, owner, tx.hash]) {
            let detail = try decoder.decode(SolanaTransaction.self, from: data)
            for change in detail.changes { movement(change.direction, owner: owner, peer: change.counterparty) }
            let parties = try SolanaDecoding.parties(detail, owner: owner)
            from.formUnion(parties.from); to.formUnion(parties.to)
            let payer = try decoder.decode(SolanaJSON.self, from: detail.raw)["transaction"]["message"]["accountKeys"].array?.first
            let payerAddress = payer?["pubkey"].string ?? payer?.string
            senderFee = from.count == 1 ? payerAddress.map { from.contains($0) ? detail.fee : "0" } : nil
        } else if tx.networkID == "sui",
                  let data = try Data.fetchOne(db, sql: "SELECT detail FROM suiTransactions WHERE accountID=? AND hash=?", arguments: [accountID, tx.hash]) {
            let detail = try decoder.decode(SuiTransaction.self, from: data)
            if detail.owner == detail.sender, let paid = detail.fee {
                senderFee = paid
            } else {
                let sponsor = try decoder.decode(SuiJSON.self, from: detail.raw)["gasInput"]["gasSponsor"]["address"].string
                senderFee = try sponsor.map(SuiIdentity.address).flatMap { $0 == detail.sender ? tx.feeAtomic : "0" }
            }
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
        return ReceiptParties(from: unique(from), to: unique(to), senderFee: senderFee, owner: selectedSolana ?? account.address,
                             isEVM: isEVM, scopedEntryIDs: scopedEntryIDs)
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
