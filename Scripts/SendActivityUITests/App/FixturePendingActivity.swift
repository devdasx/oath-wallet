import SwiftUI
import Observation

// Persistence/merging is tested against the real GRDB store in WalletPendingActivityTests.
@MainActor @Observable final class WalletPendingActivityStore {
    var isPresented = false
    var selection: WalletPendingActivityItem?
}
enum WalletPendingActivityItem: Identifiable {
    case operation(SendOperation)
    case transaction(String)
    var id: String {
        switch self {
        case let .operation(operation): "send:" + operation.id.uuidString
        case let .transaction(value): "stored:" + value
        }
    }
}
struct WalletPendingActivityRow: View {
    let transaction: String
    var body: some View { Text(verbatim: transaction) }
}
