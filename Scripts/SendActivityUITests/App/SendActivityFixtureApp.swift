import SwiftUI

@main struct SendActivityFixtureApp: App {
    var body: some Scene { WindowGroup { SendActivityFixtureScreen() } }
}

struct SendActivityFixtureScreen: View {
    @State private var store: SendActivityStore
    @State private var pending = WalletPendingActivityStore()
    private let largeText = ProcessInfo.processInfo.arguments.contains("fixture-large-text")
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let count = arguments.contains("fixture-many") ? 12 : 2
        let operations = (0..<count).map { index in
            SendOperation(database: WalletDatabase(), draft: SendDraft(recipient: "Recipient-\(index)", amount: "\(index + 1)"),
                          walletAddress: "fixture", nativeUnitUSDPrice: nil)
        }
        _store = State(initialValue: SendActivityStore(operations: operations))
    }
    private var items: [WalletPendingActivityItem] {
        store.operations.reversed().filter {
            $0.capsuleStatus != .confirmed && ($0.capsuleStatus != .failed || !$0.isAcknowledged)
        }.map(WalletPendingActivityItem.operation)
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack {
                    if !pending.isPresented {
                        SendActivityGroupCapsule(store: store, walletAddress: "fixture",
                                                maximumHeight: min(560, geometry.size.height * 0.7))
                            .frame(maxWidth: 560).padding(.horizontal, 16)
                    }
                    Spacer()
                    HStack {
                        Button("Confirm newest") { store.operations.last?.finish(.confirmed) }
                            .accessibilityIdentifier("fixture-confirm")
                        Button("Fail newest") { store.operations.last?.finish(.failed) }
                            .accessibilityIdentifier("fixture-fail")
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Text("Fixture Wallet") }
                    if !items.isEmpty || pending.isPresented || pending.selection != nil {
                        ToolbarItem(placement: .topBarLeading) {
                            WalletPendingActivityToolbarButton(store: pending, items: items,
                                maximumHeight: min(480, geometry.size.height * 0.65)) { item in
                                    if case let .operation(operation) = item { store.openDetails(operation) }
                                }
                        }
                    }
                }
            }
        }
        .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
        .sheet(item: $store.presentedOperation) { operation in
            VStack {
                Text(verbatim: operation.draft.recipient).accessibilityIdentifier("fixture-selected-recipient")
                Button("Close") { store.finishDetails(operation) }.accessibilityIdentifier("fixture-close")
            }
        }
    }
}
