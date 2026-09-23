import SwiftUI

struct WalletBitcoinSilentPaymentKeyListScreen: View {
    let wallet: ManagedWallet
    let silentPayments:
        WalletBitcoinPrivateKeyExportCatalog.SilentPayments
    let isSensitiveContentProtected: Bool

    var body: some View {
        List {
            Group {
                Section("receive.details.address.section") {
                    WalletExactText(silentPayments.address, textStyle: .caption1, monospaced: true)
                }

                Section {
                    ForEach(silentPayments.outputs) { entry in
                        NavigationLink {
                            Group {
                                WalletPrivateKeyExportDisplayScreen(
                                    wallet: wallet,
                                    item: entry.displayItem
                                )
                                .walletSensitiveContentMask(
                                    isProtected:
                                        isSensitiveContentProtected
                                )
                            }

                        } label: {
                            WalletBitcoinSilentPaymentKeyRow(entry: entry)
                        }
                    }
                } header: {
                    Text("bitcoin.settings.silent.outputs")
                } footer: {
                    Text(
                        silentPayments.outputs.isEmpty
                            ? "bitcoin.settings.silent.outputs.empty"
                            : "bitcoin.settings.silent.outputs.footer"
                    )
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle(
            "receive.bitcoin.address_type.silent_payments"
        )
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WalletBitcoinSilentPaymentKeyRow: View {
    let entry: WalletBitcoinPrivateKeyExportCatalog.SilentPaymentOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: entry.output.valueAtomic.bitcoinSettingsDisplay)
                Spacer(minLength: 12)
                Text(LocalizedStringKey(
                    entry.output.isSpent
                        ? "bitcoin.settings.address.status.spent"
                        : "bitcoin.settings.address.status.unspent"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(verbatim: entry.id)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}
