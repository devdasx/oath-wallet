import Foundation
import SwiftUI

struct WalletActivityNetworkOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct WalletActivityFilter: Hashable, Sendable {
    var networkIDs: Set<String> = []
    var kind: WalletActivityKindFilter = .all
    var status: WalletActivityStatusFilter = .all
    var minimumUSDValue: Decimal?
    var maximumUSDValue: Decimal?
    var startDate: Date?
    var endDate: Date?

    var isActive: Bool {
        activeCriteriaCount > 0
    }

    var activeCriteriaCount: Int {
        var count = networkIDs.isEmpty ? 0 : 1
        count += kind == .all ? 0 : 1
        count += status == .all ? 0 : 1
        count += minimumUSDValue == nil ? 0 : 1
        count += maximumUSDValue == nil ? 0 : 1
        count += startDate == nil ? 0 : 1
        count += endDate == nil ? 0 : 1
        return count
    }

    func includes(_ transaction: WalletTransaction) -> Bool {
        if !networkIDs.isEmpty {
            guard
                let networkID =
                    WalletNetworkSelectionOrdering.canonicalNetworkID(
                        transaction.metadata.blockchainIdentifier
                    ),
                networkIDs.contains(networkID)
            else {
                return false
            }
        }

        guard kind.includes(transaction.kind),
              status.includes(transaction.status) else {
            return false
        }

        if minimumUSDValue != nil || maximumUSDValue != nil {
            guard let fiatValue = transaction.fiatValue else {
                return false
            }
            let absoluteUSDValue = fiatValue < 0 ? -fiatValue : fiatValue

            if let minimumUSDValue,
               absoluteUSDValue < minimumUSDValue {
                return false
            }

            if let maximumUSDValue,
               absoluteUSDValue > maximumUSDValue {
                return false
            }
        }

        if startDate != nil || endDate != nil {
            guard let transactionDate = transaction.metadata.date else {
                return false
            }

            if let startDate, transactionDate < startDate {
                return false
            }

            if let endDate, transactionDate > endDate {
                return false
            }
        }

        return true
    }
}

enum WalletActivityKindFilter:
    String,
    CaseIterable,
    Identifiable,
    Hashable,
    Sendable
{
    case all
    case sent
    case received
    case selfTransfer
    case swapped

    var id: String { rawValue }

    var localizedKey: LocalizedStringKey {
        switch self {
        case .all:
            "wallet.activity.filter.type.all"
        case .sent:
            "wallet.transaction.details.direction.sent"
        case .received:
            "wallet.transaction.details.direction.received"
        case .selfTransfer:
            "wallet.activity.self_transfer.title"
        case .swapped:
            "wallet.transaction.details.direction.swapped"
        }
    }

    func includes(_ kind: WalletTransactionKind) -> Bool {
        switch (self, kind) {
        case (.all, _),
             (.sent, .sent),
             (.received, .received),
             (.selfTransfer, .selfTransfer),
             (.swapped, .swapped):
            true
        default:
            false
        }
    }
}

enum WalletActivityStatusFilter:
    String,
    CaseIterable,
    Identifiable,
    Hashable,
    Sendable
{
    case all
    case confirmed
    case pending
    case failed
    case canceled

    var id: String { rawValue }

    var localizedKey: LocalizedStringKey {
        switch self {
        case .all:
            "wallet.activity.filter.status.all"
        case .confirmed:
            "wallet.activity.status.confirmed"
        case .pending:
            "wallet.activity.status.pending"
        case .failed:
            "wallet.activity.status.failed"
        case .canceled:
            "wallet.activity.status.canceled"
        }
    }

    func includes(_ status: WalletTransactionStatus) -> Bool {
        switch (self, status) {
        case (.all, _),
             (.confirmed, .confirmed),
             (.pending, .pending),
             (.pending, .notFound),
             (.failed, .failed),
             (.canceled, .canceled):
            true
        case (.canceled, .replaced): true
        default:
            false
        }
    }
}
