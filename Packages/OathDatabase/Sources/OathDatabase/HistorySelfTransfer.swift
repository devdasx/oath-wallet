import Foundation
import GRDB
import OathBitcoin
import OathAnkr

extension OathDatabase {
    /// Project fees at read time so cached history is corrected without rewriting
    /// provider transfers, input/output amounts, or account balances. Optional
    /// receipt/ownership evidence being absent is not a diagnostic failure.
    static func projectSelfTransferFee(_ entry: HistoryEntry, db: Database) throws -> HistoryEntry {
        var entry = entry
        if entry.amountAtomic == "0", ["outgoing", "self"].contains(entry.direction),
           ["confirmed", "failed"].contains(entry.state) {
            // Shared by combined history, asset activity and transaction details.
            // Only native placeholders get a call label; token movements stay intact.
            entry.contractKind = try String.fetchOne(db, sql: """
                SELECT c.contractKind FROM evmHistorySwaps c
                JOIN accounts owner ON owner.id=c.accountID AND owner.syncGeneration=c.generation
                JOIN transactions t ON t.id=c.transactionID AND lower(t.blockHash)=c.blockHash
                JOIN assets asset ON asset.id=? AND asset.reference='native'
                JOIN networks n ON n.id=asset.networkID AND n.family='evm'
                WHERE c.accountID=? AND c.transactionID=? AND c.version IN (4,5,?)
                """, arguments: [entry.assetID, entry.accountID, entry.transactionID, EVMHistorySwap.version])
        }
        guard entry.direction == "self",
              let asset = try AssetRecord.fetchOne(db, key: entry.assetID), asset.reference == "native",
              let tx = try TransactionRecord.fetchOne(db, key: entry.transactionID),
              let account = try AccountRecord.fetchOne(db, key: entry.accountID) else { return entry }
        let decoder = JSONDecoder()
        var fee = tx.feeAtomic
        var paysFee = false
        if UTXONetwork(rawValue: entry.networkID) != nil {
            // "self" also labels a zero net collaborative transaction. Only
            // all-owned inputs and all-owned outputs prove a fee-only debit.
            paysFee = try Bool.fetchOne(db, sql: "SELECT returnsToWallet FROM transactionEvidence WHERE accountID=? AND transactionID=?",
                arguments: [entry.accountID, entry.transactionID]) == true
        } else if try String.fetchOne(db, sql: "SELECT family FROM networks WHERE id=?", arguments: [entry.networkID]) == "evm" {
            paysFee = !entry.counterparty.isEmpty && entry.counterparty.lowercased() == account.address.lowercased()
            if entry.networkID == "celo",
               let data = try Data.fetchOne(db, sql: "SELECT detail FROM indexedEVMEvents WHERE accountID=? AND id=?", arguments: [entry.accountID, tx.hash + ":external"]),
               try decoder.decode(IndexedEVMEvent.self, from: data).feeCurrencyAmount != nil {
                fee = "0" // Gas paid in a token does not reduce native CELO.
            }
        } else {
            switch entry.networkID {
            case "sui":
                if let data = try Data.fetchOne(db, sql: "SELECT detail FROM suiTransactions WHERE accountID=? AND hash=?", arguments: [entry.accountID, tx.hash]) {
                    let receipt = try decoder.decode(SuiTransaction.self, from: data)
                    // A sponsor's fee and storage rebates are not this wallet's debit.
                    fee = receipt.fee
                    paysFee = fee != nil && !receipt.netGas.hasPrefix("-")
                } else {
                    // A locally signed ordinary self-send has not synced effects yet.
                    paysFee = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sends WHERE accountID=? AND transactionID=? AND senderAddress=recipient AND signedPayload IS NOT NULL)", arguments: [entry.accountID, tx.id]) == true
                }
            case "solana":
                let owner = try String.fetchOne(db, sql: "SELECT owner FROM solanaActivity WHERE activityID=?", arguments: [entry.id])
                if let owner, entry.amountAtomic == "0",
                   let data = try Data.fetchOne(db, sql: "SELECT detail FROM solanaTransactions WHERE accountID=? AND owner=? AND signature=?", arguments: [entry.accountID, owner, tx.hash]) {
                    let receipt = try decoder.decode(SolanaTransaction.self, from: data)
                    let raw = try decoder.decode(SolanaJSON.self, from: receipt.raw)
                    let payer = raw["transaction"]["message"]["accountKeys"].array?.first
                    paysFee = (payer?["pubkey"].string ?? payer?.string) == owner
                }
            case "stellar":
                if entry.amountAtomic == "0" {
                    let events = try Data.fetchAll(db, sql: "SELECT detail FROM stellarEvents WHERE accountID=? AND hash=?", arguments: [entry.accountID, tx.hash])
                        .map { try decoder.decode(StellarEvent.self, from: $0) }
                    // Fees are indexed by the fee-paying account, including fee bumps.
                    paysFee = events.contains { $0.kind == "fee" }
                    if paysFee { fee = events.filter { $0.kind == "fee" }.reduce("0") { StellarIdentity.sum($0, $1.amount) } }
                }
            case "xrpl":
                if entry.amountAtomic == "0", let data = try Data.fetchOne(db, sql: "SELECT detail FROM xrplTransactions WHERE accountID=? AND hash=?", arguments: [entry.accountID, tx.hash]) {
                    let receipt = try decoder.decode(XrplTransaction.self, from: data)
                    let raw = try decoder.decode(XrplJSON.self, from: receipt.raw)
                    paysFee = raw["tx_json"]["Account"].string == account.address
                }
            case "aptos":
                if entry.amountAtomic == "0", let data = try Data.fetchOne(db, sql: "SELECT detail FROM aptosTransactions WHERE accountID=? AND hash=?", arguments: [entry.accountID, tx.hash]) {
                    let receipt = try decoder.decode(AptosTransaction.self, from: data)
                    let raw = try decoder.decode(AptosJSON.self, from: receipt.raw)
                    let payer = raw["receipt"]["signature"]["fee_payer_address"].string
                    paysFee = try AptosIdentity.address(payer ?? receipt.sender) == AptosIdentity.address(account.address)
                }
            case "near":
                paysFee = !entry.counterparty.isEmpty && entry.counterparty == account.address
            default:
                // Message-based chains may debit and return the principal in
                // different transactions. A matching endpoint alone is not net effect.
                break
            }
        }
        guard paysFee else { return entry }
        if let fee { try Validation.amount(fee) }
        var result = entry
        result.usesSelfTransferFee = true
        result.selfTransferFeeAtomic = fee
        return result
    }
}
