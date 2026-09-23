import SwiftUI
import UIKit

struct WalletTransactionIdentityDetail: Identifiable {
    enum Kind: String, Hashable {
        case fromAddress
        case toAddress
        case transactionHash

        var titleKey: LocalizedStringKey {
            switch self {
            case .fromAddress:
                "wallet.transaction.details.from"
            case .toAddress:
                "wallet.transaction.details.to"
            case .transactionHash:
                "wallet.transaction.details.hash"
            }
        }
    }

    let kind: Kind
    let value: String
    let explorerURL: URL?

    init(
        kind: Kind,
        value: String,
        networkID: String?
    ) {
        self.kind = kind
        self.value = value
        explorerURL = kind == .transactionHash
            ? WalletTransactionExplorer.url(
                transactionHash: value,
                networkID: networkID
            )
            : nil
    }

    var id: Kind { kind }

    var transactionSharingPayload: String? {
        guard kind == .transactionHash,
              let explorerURL else {
            return nil
        }
        return "\(value)\n\(explorerURL.absoluteString)"
    }
}

extension WalletTransactionKind {
    var transactionDetailsAddressOrder:
        [WalletTransactionIdentityDetail.Kind]
    {
        [.fromAddress, .toAddress]
    }
}

struct WalletTransactionIdentityDetailSheet: View {
    let detail: WalletTransactionIdentityDetail

    @Environment(\.dismiss) private var dismiss
    @State private var copyFeedback = WalletClipboardCopyFeedback()

    var body: some View {
        NavigationStack {
            Group {
                List {
                    Group {
                        Section {
                            WalletExactText(detail.value, foregroundColor: WalletTheme.primaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel(Text(detail.kind.titleKey))
                                .accessibilityValue(Text(verbatim: detail.value))
                        }

                        if let payload = detail.transactionSharingPayload,
                           let explorerURL = detail.explorerURL {
                            Section {
                                Button(action: UniHaptic.action(.successQuiet) {
                                    SendTransactionIdentityClipboard.copy(
                                        payload,
                                        to: UIPasteboard.general
                                    )
                                    copyFeedback.markCopied()
                                }) {
                                    Text(
                                        LocalizedStringKey(
                                            copyFeedback.localizationKey
                                        )
                                    )
                                }

                                ShareLink(item: payload) {
                                    Text("wallet.transaction.details.share_transaction_id")
                                }

                                Link(
                                    "wallet.transaction.details.explorer.open",
                                    destination: explorerURL
                                )
                            }
                        }
                    }
                    .walletListRowSurface()
                }
                .walletListAppearance()
                .listStyle(.insetGrouped)
                .navigationTitle(detail.kind.titleKey)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        WalletCloseButton {
                            dismiss()
                        }
                    }
                }
            }

        }
        .onChange(of: detail.value) { _, _ in
            copyFeedback.reset()
        }
        .onDisappear {
            copyFeedback.reset()
        }
    }
}
