import SwiftUI

/// Home activity owns this presentation. Send keeps ownership of live-operation receipts.
struct WalletPendingActivityScreen: View {
    let items: [WalletPendingActivityItem]
    let maximumHeight: CGFloat
    let onSelect: (WalletPendingActivityItem) -> Void
    let onClose: () -> Void
    var onContentHeightChanged: (CGFloat) -> Void = { _ in }
    @State private var contentHeight: CGFloat?
    @State private var viewportHeight: CGFloat = 0

    private var contentFits: Bool { (contentHeight ?? .infinity) <= viewportHeight + 1 }

    private struct ContentMeasurement: Equatable {
        let rowsHeight: CGFloat
        let viewportHeight: CGFloat
    }

    var body: some View {
        activityList
            .foregroundStyle(WalletTheme.primaryLabel)
            .gesture(SendActivitySwipeGesture(isEnabled: contentFits, onTranslation: { _ in }, onDismiss: onClose))
            .accessibilityAction(.escape, onClose)
            .onKeyPress(.escape) { onClose(); return .handled }
    }

    private var activityList: some View {
        List {
            Group {
                Section {
                    ForEach(items) { item in
                        Button(action: UniHaptic.action(nil) { onSelect(item) }) {
                            switch item {
                            case let .operation(operation): SendActivityRow(operation: operation)
                            case let .transaction(transaction): WalletPendingActivityRow(transaction: transaction)
                            }
                        }
                        .accessibilityHint(Text("send.broadcast.navigation_title"))
                        .accessibilityIdentifier("pending-activity-row-" + item.id)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden, edges: .top)
                        .listRowSeparator(item.id == items.last?.id ? .hidden : .visible, edges: .bottom)
                    }
                }
            }
            .walletListRowSurface()
        }
        // The native popover supplies the same glass surface behind its
        // navigation bar and rows. A grouped page canvas breaks that continuity.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: ContentMeasurement.self) {
            ContentMeasurement(rowsHeight: $0.contentSize.height.rounded(.up),
                viewportHeight: $0.containerSize.height)
        } action: { _, measurement in
            // SwiftUI reports the usable viewport; UIKit's navigation inset
            // is already reserved outside this content area.
            viewportHeight = measurement.viewportHeight
            if measurement.rowsHeight > 0 {
                contentHeight = measurement.rowsHeight
                // UIKit already reserves navigation/safe-area insets. Only row
                // content contributes to the popover's preferred content size.
                onContentHeightChanged(min(maximumHeight, measurement.rowsHeight))
            }
        }
        .onChange(of: maximumHeight) { _, _ in
            if let contentHeight { onContentHeightChanged(min(maximumHeight, contentHeight)) }
        }
        .scrollDisabled(contentFits)
        .accessibilityIdentifier("pending-activity-list")
    }
}
