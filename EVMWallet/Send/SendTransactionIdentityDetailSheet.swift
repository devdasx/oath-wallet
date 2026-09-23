import SwiftUI
import UIKit

@MainActor
protocol SendTransactionIdentityPasteboard: AnyObject {
    var string: String? { get set }
}

extension UIPasteboard: SendTransactionIdentityPasteboard {}

@MainActor
enum SendTransactionIdentityClipboard {
    static func copy(
        _ value: String,
        to pasteboard: any SendTransactionIdentityPasteboard
    ) {
        pasteboard.string = value
    }
}

struct SendTransactionIdentityDetail: Identifiable {
    enum Kind: String, Hashable {
        case recipient
        case transactionID

        var titleKey: LocalizedStringKey {
            switch self {
            case .recipient:
                "send.recipient.section"
            case .transactionID:
                "send.broadcast.transaction_id.title"
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
        explorerURL = kind == .transactionID
            ? WalletTransactionExplorer.url(
                transactionHash: value,
                networkID: networkID
            )
            : nil
    }

    var id: Kind { kind }

    var showsTransactionActions: Bool {
        kind == .transactionID
    }

    var transactionSharingPayload: String? {
        guard showsTransactionActions,
              let explorerURL else {
            return nil
        }
        return "\(value)\n\(explorerURL.absoluteString)"
    }
}

struct SendTransactionIdentityDetailSheet: View {
    let detail: SendTransactionIdentityDetail

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

                        if detail.showsTransactionActions {
                            Section {
                                Button(action: UniHaptic.action(.successQuiet) {
                                    SendTransactionIdentityClipboard.copy(
                                        detail.value,
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

                                if let payload = detail.transactionSharingPayload {
                                    ShareLink(item: payload) {
                                        Text("wallet.transaction.details.share_transaction_id")
                                    }
                                }

                                if let explorerURL = detail.explorerURL {
                                    Link(
                                        "wallet.transaction.details.explorer.open",
                                        destination: explorerURL
                                    )
                                }
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
