import SwiftUI

struct BitcoinWalletSettingsScreen: View {
    let walletID: String
    let database: WalletDatabase

    @State private var snapshot: BitcoinWalletSettingsSnapshot?
    @State private var errorMessage: String?
    @State private var isRefreshing = false

    var body: some View {
        List {
            Group {
                if let snapshot {
                    if let errorMessage {
                        Section {
                            Text(errorMessage).foregroundStyle(WalletTheme.danger)
                        }
                    }
                    if snapshot.silentPayments.account != nil {
                        Section {
                            Text("bitcoin.silent.known_outputs_only")
                                .font(.footnote)
                                .foregroundStyle(WalletTheme.secondaryLabel)
                        }
                    }
                    Section("bitcoin.settings.summary.section") {
                        LabeledContent(
                            "bitcoin.settings.balance",
                            value: snapshot.balanceAtomic.bitcoinSettingsDisplay
                        )
                        LabeledContent(
                            "bitcoin.settings.generated_addresses",
                            value: String(snapshot.generatedAddressCount)
                        )
                    }

                    Section {
                        ForEach(snapshot.types, id: \.descriptor.addressType) {
                            typeSnapshot in
                            NavigationLink(
                                value: BitcoinWalletSettingsRoute.addressType(
                                    typeSnapshot.descriptor.addressType
                                )
                            ) {
                                BitcoinSettingsTypeRow(
                                    title: typeSnapshot.descriptor.addressType
                                        .localizedName,
                                    summary: EnglishNumbers.localized(
                                        "bitcoin.settings.type.summary",
                                        typeSnapshot.generatedCount,
                                        typeSnapshot.usedCount,
                                        typeSnapshot.balanceAtomic
                                            .bitcoinSettingsDisplay
                                    ),
                                    isSelected:
                                        !snapshot.usesSilentPayments
                                        && snapshot.selectedType
                                            == typeSnapshot.descriptor.addressType
                                )
                            }
                        }

                        if !snapshot.silentPayments.outputs.isEmpty {
                            NavigationLink(
                                value: BitcoinWalletSettingsRoute.silentPayments
                            ) {
                                BitcoinSettingsTypeRow(
                                    title: WalletLocalization.string(
                                        "receive.bitcoin.address_type.silent_payments"
                                    ),
                                    summary: snapshot.silentPayments.balanceAtomic
                                        .bitcoinSettingsDisplay,
                                    isSelected: snapshot.usesSilentPayments
                                )
                            }
                        }
                    } header: {
                        Text("bitcoin.settings.address_types.section")
                    } footer: {
                        Text("bitcoin.settings.aggregate.footer")
                    }

                    Section {
                        Button(action: UniHaptic.action {
                            refreshWalletState()
                        }) {
                            Text(LocalizedStringKey(
                                isRefreshing
                                    ? "bitcoin.settings.refreshing"
                                    : "bitcoin.settings.refresh"
                            ))
                        }
                        .disabled(isRefreshing)
                    }
                } else if let errorMessage {
                    Section {
                        Text(verbatim: errorMessage)
                            .foregroundStyle(WalletTheme.danger)
                    }
                } else {
                    Section {
                        Text("receive.details.loading")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("bitcoin.settings.title")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
    }

    @MainActor
    private func load() async {
        do {
            snapshot = try await BitcoinWalletSettingsRepository(
                database: database
            ).load(walletID: walletID)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            snapshot = nil
            errorMessage = WalletLocalization.string(
                "bitcoin.settings.load.error"
            )
        }
    }

    private func refreshWalletState() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { @MainActor in
            do {
                async let standard = BitcoinHDDiscoveryService(
                    database: database
                ).discover(walletID: walletID)
                async let silent = BitcoinSilentPaymentSyncService(
                    database: database
                ).refresh(walletID: walletID)
                _ = try await (standard, silent)
                await load()
            } catch is CancellationError {
                isRefreshing = false
                return
            } catch {
                errorMessage = WalletLocalization.string(
                    "bitcoin.settings.refresh.error"
                )
            }
            isRefreshing = false
        }
    }
}
