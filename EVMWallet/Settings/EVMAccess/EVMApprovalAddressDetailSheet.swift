import SwiftUI
import UIKit

struct EVMApprovalAddressDetailSheet: View {
    let detail: EVMApprovalAddressDetail

    @State private var copyFeedback = WalletClipboardCopyFeedback()

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section {
                        WalletExactText(detail.value)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(Text(detail.kind.titleKey))
                            .accessibilityValue(Text(verbatim: detail.value))
                    }
                    if detail.kind == .transactionID {
                        Section {
                            Button(action: UniHaptic.action(.successQuiet) {
                                UIPasteboard.general.string = detail.value
                                copyFeedback.markCopied()
                            }) {
                                Text(LocalizedStringKey(copyFeedback.localizationKey))
                            }
                            if let url = detail.explorerURL {
                                ShareLink(item: "\(detail.value)\n\(url.absoluteString)") {
                                    Text("wallet.transaction.details.share_transaction_id")
                                }
                                Link("wallet.transaction.details.explorer.open", destination: url)
                            }
                        }
                    }
                }
                .walletListRowSurface()
            }
            .walletListAppearance()
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle(detail.kind.titleKey)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    WalletCloseButton { dismiss() }
                }
            }
        }
        .walletSheetBackground()
        .onDisappear { copyFeedback.reset() }
    }
}
