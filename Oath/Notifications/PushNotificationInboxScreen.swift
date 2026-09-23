import SwiftUI
import GRDB

struct PushNotificationInboxScreen: View {
    private enum LoadState {
        case loading
        case loaded([DBNotificationRecord])
        case failed
    }

    let database: WalletDatabase
    var initialNotificationID: String? = nil
    @State private var routedNotification: DBNotificationRecord?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadState: LoadState = .loading

    var body: some View {
        Group {
            if let notification = routedNotification {
                // Replace the existing sheet's root. There is no pushed screen,
                // so Close dismisses the protected sheet rather than going Back.
                destination(notification)
            } else if initialNotificationID != nil {
                NotificationTransactionSkeleton()
            } else {
                switch loadState {
                case .loading:
                    loadingList
                case let .loaded(notifications):
                    if notifications.isEmpty {
                        WalletEmptyStateView(
                            "notifications.inbox.empty.title",
                            message: "notifications.inbox.empty.detail"
                        )
                    } else {
                        notificationList(notifications)
                    }
                case .failed:
                    ContentUnavailableView(
                        "notifications.inbox.failed.title",
                        systemImage: "exclamationmark.triangle",
                        description: Text("notifications.inbox.failed.detail")
                    )
                }
            }
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.24),
            value: loadStateID
        )
        .background(WalletTheme.groupedBackground)
        .navigationTitle(LocalizedStringKey(
            routedNotification == nil && initialNotificationID == nil
                ? "notifications.inbox.title"
                : (isTransaction(routedNotification) || routedNotification == nil
                    ? "wallet.transaction.details.title" : "notifications.detail.title")
        ))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isTransaction(routedNotification) {
                ToolbarItem(placement: .cancellationAction) {
                    WalletCloseButton { dismiss() }
                }
            }
        }
        .task(id: initialNotificationID) {
            await load()
        }
    }

    private var loadingList: some View {
        List {
            Group {
                Section {
                    Text("notifications.inbox.loading")
                        .foregroundStyle(WalletTheme.secondaryLabel)
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func notificationList(
        _ notifications: [DBNotificationRecord]
    ) -> some View {
        List {
            Group {
                Section {
                    ForEach(notifications, id: \.id) { notification in
                        Button(action: UniHaptic.action {
                            routedNotification = notification
                        }) {
                            PushNotificationInboxRow(
                                notification: notification, database: database
                            )
                        }
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func isTransaction(_ notification: DBNotificationRecord?) -> Bool {
        notification?.category == "received" || notification?.category == "sent"
    }

    @ViewBuilder
    private func destination(_ notification: DBNotificationRecord) -> some View {
        if notification.category == "received" || notification.category == "sent" {
            PushNotificationTransactionDetailScreen(notification: notification, database: database)
                .id(notification.id)
        } else {
            PushNotificationDetailScreen(notification: notification, database: database)
        }
    }

    @MainActor
    private func load() async {
        do {
            if let identifier = initialNotificationID {
                let target = try await database.pool.read { db in
                    try DBNotificationRecord
                        .filter(Column("profileID") == WalletDatabase.defaultProfileID)
                        .filter(Column("remoteNotificationID") == identifier || Column("id") == identifier)
                        .fetchOne(db)
                }
                guard !Task.isCancelled else { return }
                routedNotification = target
            }
            let observation = ValueObservation.tracking { database in
                try DBNotificationRecord
                    .filter(Column("profileID") == WalletDatabase.defaultProfileID)
                    .order(Column("createdAt").desc, Column("id").desc)
                    .limit(200)
                    .fetchAll(database)
            }
            for try await notifications in observation.values(
                in: database.pool, bufferingPolicy: .bufferingNewest(1)
            ) {
                guard !Task.isCancelled else { return }
                loadState = .loaded(notifications)
                if routedNotification == nil, let identifier = initialNotificationID {
                    routedNotification = notifications.first {
                        $0.id == identifier || $0.remoteNotificationID == identifier
                    }
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed
        }
    }

    private var loadStateID: Int {
        switch loadState {
        case .loading: 0
        case .loaded: 1
        case .failed: 2
        }
    }
}

private struct PushNotificationInboxRow: View {
    let notification: DBNotificationRecord
    let database: WalletDatabase

    var body: some View {
        let displayContent =
            PushNotificationContentFormatter.content(
                for: notification
            )
        let timestamp = EnglishNumbers.walletTimestamp(
            Date(timeIntervalSince1970: notification.createdAt)
        )

        HStack(alignment: .center, spacing: 12) {
            PushNotificationRowLogo(notification: notification, database: database)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: displayContent.title)
                    .font(.headline)
                    .foregroundStyle(WalletTheme.primaryLabel)
                    .lineLimit(2)

                Text(verbatim: displayContent.body)
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .lineLimit(3)

                Text(verbatim: timestamp)
                    .font(.caption)
                    .foregroundStyle(WalletTheme.tertiaryLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
