import SwiftUI

struct WalletBitcoinPrivateKeyTypeSelectionScreen: View {
    let wallet: ManagedWallet
    let catalog: WalletBitcoinPrivateKeyExportCatalog
    let isSensitiveContentProtected: Bool

    var body: some View {
        List {
            Group {
                Section {
                    ForEach(catalog.addressTypes) { type in
                        NavigationLink {
                            Group {
                                WalletBitcoinPrivateKeyAddressListScreen(
                                    wallet: wallet,
                                    type: type,
                                    isSensitiveContentProtected:
                                        isSensitiveContentProtected
                                )
                            }

                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: type.addressType.localizedName)
                                Text(
                                    verbatim: EnglishNumbers.localized(
                                        "bitcoin.settings.type.summary",
                                        type.generatedCount,
                                        type.usedCount,
                                        type.balanceAtomic
                                            .bitcoinSettingsDisplay
                                    )
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }

                    if let silentPayments = catalog.silentPayments {
                        NavigationLink {
                            Group {
                                WalletBitcoinSilentPaymentKeyListScreen(
                                    wallet: wallet,
                                    silentPayments: silentPayments,
                                    isSensitiveContentProtected:
                                        isSensitiveContentProtected
                                )
                            }

                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(
                                    "receive.bitcoin.address_type.silent_payments"
                                )
                                Text(verbatim: silentPayments.address)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                } header: {
                    Text("bitcoin.settings.address_types.section")
                } footer: {
                    Text("bitcoin.settings.aggregate.footer")
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("network.bitcoin.name")
        .navigationBarTitleDisplayMode(.inline)
    }
}
