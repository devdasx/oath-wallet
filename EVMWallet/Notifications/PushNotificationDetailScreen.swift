import SwiftUI

struct PushNotificationDetailScreen: View {
    let notification: DBNotificationRecord
    let database: WalletDatabase

    var body: some View {
        List {
            Group {
                Section {
                    PushNotificationTitle(notification: notification, content: content, database: database)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(verbatim: content.body)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("notifications.detail.section") {
                    LabeledContent(
                        "notifications.detail.category",
                        value: WalletLocalization.string(categoryKey)
                    )
                    LabeledContent(
                        "notifications.detail.time",
                        value: EnglishNumbers.transactionDateTime(
                            Date(
                                timeIntervalSince1970:
                                    notification.createdAt
                            )
                        )
                    )

                    if let networkID = notification.networkID {
                        LabeledContent(
                            "notifications.detail.network",
                            value: networkID
                        )
                    }

                    if let transactionHash =
                        notification.transactionHash {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("notifications.detail.transaction")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            WalletExactText(transactionHash, monospaced: true)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
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
        .background(WalletTheme.groupedBackground)
        .navigationTitle("notifications.detail.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var content: PushNotificationDisplayContent {
        PushNotificationContentFormatter.content(for: notification)
    }

    private var categoryKey: String {
        switch PushNotificationCategory(rawValue: notification.category) {
        case .received:
            "settings.notifications.received"
        case .sent:
            "settings.notifications.sent"
        case .admin, .none:
            "settings.notifications.admin"
        }
    }
}
