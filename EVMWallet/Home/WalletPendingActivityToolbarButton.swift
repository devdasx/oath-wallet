import SwiftUI

struct WalletPendingActivityToolbarButton: View {
    @Bindable var store: WalletPendingActivityStore
    let items: [WalletPendingActivityItem]
    let maximumHeight: CGFloat
    let onOpen: (WalletPendingActivityItem) -> Void
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .body) private var estimatedRowHeight = 104.0
    @State private var contentHeight: CGFloat?

    var body: some View {
        Button(action: UniHaptic.action(nil) {
            store.selection = nil
            store.isPresented = true
        }) {
            // A composed label keeps the UIKit source mounted. SwiftUI can
            // promote a bare icon Label to a bar item and discard its anchor.
            ZStack {
                Image(systemName: "bell")
                    .font(.subheadline.weight(.semibold))
            }
            .background { presentationAnchor }
        }
        // Native toolbar badge; verbatim text prevents locale-shaped numerals.
        .badge(items.isEmpty ? nil : Text(verbatim: String(items.count)))
        .accessibilityLabel(Text("wallet.activity.all.title"))
        .accessibilityValue(Text(verbatim: String(items.count)))
        .accessibilityHint(Text("send.activity.show_all"))
        .accessibilityIdentifier("wallet-home-pending-activity")
        .onChange(of: items.map(\.id)) { _, ids in
            if ids.isEmpty { close() }
        }
    }

    private var presentationAnchor: some View {
        // Shared presentation primitive: the real UIBarButtonItem is the native
        // popover source, enabling the system toolbar-to-capsule morph on iOS 26+.
        WalletHomeQuickActionsPopover(
            isPresented: $store.isPresented,
            onDismiss: finishSelection,
            navigationBar: .init(
                title: localized("wallet.activity.all.title"),
                closeTitle: localized("common.close"),
                closeIdentifier: "pending-activity-close",
                contentSize: CGSize(width: 380, height: min(maximumHeight,
                    contentHeight ?? CGFloat(min(items.count, 3)) * estimatedRowHeight)),
                onClose: close
            )
        ) {
            WalletPendingActivityScreen(items: items, maximumHeight: maximumHeight, onSelect: select, onClose: close,
                onContentHeightChanged: { height in
                    if contentHeight != height { contentHeight = height }
                })
                .environment(\.locale, locale)
                .environment(\.layoutDirection, layoutDirection)
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .environment(\.colorScheme, colorScheme)
                .environment(\.verticalSizeClass, verticalSizeClass)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func localized(_ key: String) -> String {
        let language = Bundle.preferredLocalizations(
            from: Bundle.main.localizations, forPreferences: [locale.identifier]
        ).first
        let bundle = language.flatMap {
            Bundle.main.path(forResource: $0, ofType: "lproj")
        }.flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    private func select(_ item: WalletPendingActivityItem) {
        store.selection = item
        store.isPresented = false
    }

    private func close() {
        store.selection = nil
        store.isPresented = false
    }

    private func finishSelection() {
        guard let item = store.selection else { return }
        store.selection = nil
        onOpen(item)
    }
}
