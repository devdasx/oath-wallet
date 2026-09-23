import SwiftUI

#Preview("Wallet Home — iPhone") {
    WalletDatabasePreviewHost { database in
        NavigationStack {
            WalletHomeView(database: database)
        }
    }
}

#Preview("Wallet Home — Empty") {
    WalletDatabasePreviewHost { database in
        NavigationStack {
            WalletHomeView(
                database: database,
                state: .content(.empty)
            )
        }
    }
}

#Preview("Wallet Home — Loading") {
    WalletDatabasePreviewHost { database in
        NavigationStack {
            WalletHomeView(database: database, state: .loading)
        }
    }
}

#Preview("Wallet Home — Error") {
    WalletDatabasePreviewHost { database in
        NavigationStack {
            WalletHomeView(database: database, state: .failed)
        }
    }
}

#Preview("Wallet Home — Accessibility Text") {
    WalletDatabasePreviewHost { database in
        NavigationStack {
            WalletHomeView(database: database)
        }
        .environment(\.dynamicTypeSize, .accessibility3)
    }
}
