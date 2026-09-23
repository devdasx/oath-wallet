import SwiftUI

/// Notifications and activity share the exact same details UI and persistence path.
struct NotificationTransactionDetailsContent: View {
    let notification: DBNotificationRecord
    let database: WalletDatabase
    let failureCode: String?
    let retry: () -> Void
    let transaction: WalletTransaction
    let isBalanceHidden: Bool

    var body: some View {
        WalletTransactionDetailsView(
            transaction: transaction,
            isBalanceHidden: isBalanceHidden,
            database: database,
            allowsRepeat: false
        )
    }
}
