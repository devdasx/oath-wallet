import Foundation
import GRDB
import OathAnkr
import OathBitcoin

public struct TransactionReceiptTotal: Equatable, Sendable {
    public struct Component: Equatable, Sendable {
        public let amount: AtomicAmount
        public let asset: AssetRecord
    }

    public let components: [Component]
    public let fiatValue: Decimal?
}

extension HistoryEntry {
    /// Receipt direction belongs to the selected wallet activity, even when one
    /// transaction has both sent and received legs.
    public var showsSenderTotal: Bool {
        guard contractKind == nil, ["pending", "confirmed", "failed"].contains(state) else { return false }
        return ["outgoing", "self", "swap", "bridge", "bridgeOutgoing"].contains(direction)
    }
}

struct ReceiptParties {
    let from: [String]
    let to: [String]
    let senderFee: String?
    var inputs: [TransactionEndpoint]? = nil
    var outputs: [TransactionEndpoint]? = nil
    var signedRecipientAmount: String? = nil
    var owner: String? = nil
    var isEVM = false
    var scopedEntryIDs: Set<String>? = nil

    /// The signed plan distinguishes recipient and change even when both use the same script.
    var bitcoinRecipientAmount: String? {
        if let signedRecipientAmount { return signedRecipientAmount }
        guard let inputs, !inputs.isEmpty, inputs.allSatisfy({ $0.ownership != .unrecognized }),
              let outputs, !outputs.isEmpty else { return nil }
        let payments = outputs.filter { $0.dataOutput == nil }
        // An indexed single-address wallet can receive change back to an input address.
        let inputAddresses = Set(inputs.compactMap(\.address))
        let paysAnotherAddress = payments.contains { $0.ownership != .change && $0.address.map(inputAddresses.contains) == false }
        let recipients = payments.filter { output in
            output.ownership != .change && !(paysAnotherAddress && output.address.map(inputAddresses.contains) == true)
        }
        // With reused scripts and no journal, identical self-payment and change
        // outputs have no identifiable roles. Keep their total unknown.
        if recipients.isEmpty && !payments.isEmpty { return nil }
        if !paysAnotherAddress && recipients.count > 1 &&
            recipients.contains(where: { $0.address.map(inputAddresses.contains) == true }) { return nil }
        var total: Int64 = 0
        for output in recipients {
            guard let raw = output.amountAtomic, let amount = Int64(raw), amount >= 0 else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(amount)
            guard !overflow else { return nil }
            total = sum
        }
        return String(total)
    }
}

extension OathDatabase {
    static func receiptTotal(_ db: Database, transaction: TransactionRecord, state: String, entries: [HistoryEntry],
                             transfers: [TransferRecord], feeAsset: AssetRecord?, parties: ReceiptParties,
                             value: (AtomicAmount, AssetRecord) throws -> Decimal?) throws -> TransactionReceiptTotal? {
        let sends = entries.filter { (parties.scopedEntryIDs?.contains($0.id) ?? true) && $0.showsSenderTotal }
        guard !sends.isEmpty,
              let feeAsset, let rawFee = parties.senderFee, let fee = try? AtomicAmount(rawFee) else { return nil }
        var amounts: [String: String] = [:]
        if state != "failed" {
            if UTXONetwork(rawValue: transaction.networkID) != nil {
                guard let principal = parties.bitcoinRecipientAmount else { return nil }
                amounts[feeAsset.id] = principal
            } else {
                // A journal summary and its indexed transfers can coexist. Take the actual
                // recipient events once per asset, including repeated payments to the same address.
                func belongsToOwner(_ address: String) -> Bool {
                    guard let owner = parties.owner else { return false }
                    return parties.isEVM ? owner.caseInsensitiveCompare(address) == .orderedSame : address == owner
                }
                let indexed = transfers.filter { belongsToOwner($0.fromAddress) }
                let indexedAssets = Set(indexed.map(\.assetID))
                let payments = indexed.map { ($0.assetID, $0.amountAtomic) } +
                    sends.filter { !indexedAssets.contains($0.assetID) }.map { ($0.assetID, $0.amountAtomic) }
                for (assetID, raw) in payments where raw != "0" {
                    guard let atomic = try? AtomicAmount(raw) else { return nil }
                    amounts[assetID] = StellarIdentity.sum(amounts[assetID] ?? "0", atomic.rawValue)
                }
                // A balance-delta index can collapse a self-payment to zero. Its
                // signed journal still identifies the recipient and exact principal.
                if amounts.isEmpty, let owner = parties.owner, let entry = sends.first,
                   let send = try Row.fetchOne(db, sql: """
                    SELECT assetID, amountAtomic FROM sends WHERE transactionID=? AND accountID=?
                        AND senderAddress=? AND recipient=senderAddress AND signedPayload IS NOT NULL
                        AND amountAtomic<>'0' AND state IN ('signed','broadcast','confirmed')
                    """, arguments: [transaction.id, entry.accountID, owner]),
                   sends.contains(where: { $0.assetID == send["assetID"] as String }) {
                    let raw: String = send["amountAtomic"]
                    guard let amount = try? AtomicAmount(raw) else { return nil }
                    amounts[send["assetID"]] = amount.rawValue
                }
            }
        }
        if fee.rawValue != "0" || amounts.isEmpty {
            amounts[feeAsset.id] = StellarIdentity.sum(amounts[feeAsset.id] ?? "0", fee.rawValue)
        }

        var components: [TransactionReceiptTotal.Component] = []
        var fiat: Decimal? = 0
        // Put a separately denominated network fee after the assets being transferred.
        let assetIDs = amounts.keys.filter { $0 != feeAsset.id }.sorted() + (amounts[feeAsset.id] == nil ? [] : [feeAsset.id])
        for assetID in assetIDs {
            guard let asset = try assetID == feeAsset.id ? feeAsset : AssetRecord.fetchOne(db, key: assetID),
                  let amount = amounts[assetID].flatMap({ try? AtomicAmount($0) }) else { return nil }
            components.append(.init(amount: amount, asset: asset))
            if let subtotal = fiat {
                fiat = try value(amount, asset).flatMap { price in
                    let result = subtotal + price
                    return result.isNaN ? nil : result
                }
            }
        }
        return TransactionReceiptTotal(components: components, fiatValue: fiat)
    }
}
