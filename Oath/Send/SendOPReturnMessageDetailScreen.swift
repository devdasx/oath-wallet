import SwiftUI

struct SendOPReturnMessageDetailScreen: View {
    struct Content: Identifiable {
        let id = UUID()
        let message: String
    }

    let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                List {
                    Group {
                        Section {
                            Text(verbatim: content.message)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("sendOPReturnFullMessage")
                        }
                    }
                    .walletListRowSurface()
                }
                .walletListAppearance()
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .navigationTitle("send.bitcoin.op_return.title")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        WalletCloseButton { dismiss() }
                            .accessibilityIdentifier("sendOPReturnFullMessageClose")
                    }
                }
            }

        }
    }
}
