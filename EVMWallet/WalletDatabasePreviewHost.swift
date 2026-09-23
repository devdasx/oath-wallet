import SwiftUI

/// Gives previews an isolated migrated database without restoring the
/// production singleton or introducing a crash-only preview path.
@MainActor
struct WalletDatabasePreviewHost<Content: View>: View {
    private let database: WalletDatabase?
    private let content: (WalletDatabase) -> Content

    init(
        @ViewBuilder content: @escaping (WalletDatabase) -> Content
    ) {
        database = try? WalletDatabase.temporary()
        self.content = content
    }

    @ViewBuilder
    var body: some View {
        if let database {
            content(database)
                .environment(
                    WalletSettingsStore(
                        database: database,
                        initialSettings: .default
                    )
                )
        } else {
            ContentUnavailableView(
                "wallet.launch.restore.error.title",
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text(
                    "wallet.launch.restore.error.database"
                )
            )
        }
    }
}
