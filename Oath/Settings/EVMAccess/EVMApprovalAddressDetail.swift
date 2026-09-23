import SwiftUI

struct EVMApprovalAddressDetail: Identifiable {
    enum Kind: String {
        case spender
        case contract
        case transactionID

        var titleKey: LocalizedStringKey {
            switch self {
            case .spender: "evm_access.permission.spender"
            case .contract: "evm_access.permission.contract"
            case .transactionID: "send.broadcast.transaction_id.title"
            }
        }
    }

    let kind: Kind
    let value: String

    let explorerURL: URL?

    init(kind: Kind, value: String, networkID: String? = nil) {
        self.kind = kind
        self.value = value
        explorerURL = kind == .transactionID
            ? WalletTransactionExplorer.url(transactionHash: value, networkID: networkID)
            : nil
    }

    var id: Kind { kind }
}
