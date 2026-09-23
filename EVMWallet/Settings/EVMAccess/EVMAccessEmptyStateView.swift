import SwiftUI

/// A single empty presentation for the permissions tool. A failed or incomplete
/// lookup must never be presented as proof that no permissions exist.
struct EVMAccessEmptyStateView: View {
    let state: EVMAccessManagerModel.RefreshState

    var body: some View {
        ContentUnavailableView {
            Label("evm_access.permissions.title", systemImage: symbol)
        } description: {
            if let message {
                Text(verbatim: message)
            }
        }
        // The containing List supplies the canvas. An opaque overlay background
        // also paints over the native large title in the List's scroll area.
        .accessibilityIdentifier("evm_access.empty_state")
    }

    private var symbol: String {
        switch state {
        case .idle, .loading:
            "hourglass"
        case .loaded:
            "doc.text.magnifyingglass"
        case .partialFailure, .unavailable:
            "doc.text.magnifyingglass"
        }
    }

    private var message: String? {
        switch state {
        case .idle, .loading:
            WalletLocalization.string("evm_access.permissions.loading")
        case .loaded:
            WalletLocalization.string("evm_access.permissions.empty")
        case .unavailable, .partialFailure:
            nil
        }
    }
}
