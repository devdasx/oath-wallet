import SwiftUI

struct BitcoinAddressTypeSettingsScreen: View {
    let walletID: String
    let addressType: BitcoinHDAddressType
    let database: WalletDatabase

    @State private var snapshot: BitcoinHDTypeSettingsSnapshot?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Group {
                if let snapshot {
                    Section("bitcoin.settings.account.section") {
                        LabeledContent("bitcoin.settings.derivation_path") {
                            Text(verbatim: snapshot.descriptor.accountPath)
                                .font(.system(.subheadline, design: .monospaced))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("bitcoin.settings.extended_public_key")
                            WalletExactText(snapshot.descriptor.extendedPublicKey, textStyle: .caption1, monospaced: true, foregroundColor: WalletTheme.secondaryLabel)
                        }
                    }

                    Section("bitcoin.settings.statistics.section") {
                        LabeledContent(
                            "bitcoin.settings.balance",
                            value: snapshot.balanceAtomic
                                .bitcoinSettingsDisplay
                        )
                        LabeledContent(
                            "bitcoin.settings.generated_addresses",
                            value: String(snapshot.generatedCount)
                        )
                        LabeledContent(
                            "bitcoin.settings.used_addresses",
                            value: String(snapshot.usedCount)
                        )
                        LabeledContent(
                            "bitcoin.settings.reserved_addresses",
                            value: String(
                                snapshot.external.reservedCount
                                    + snapshot.change.reservedCount
                            )
                        )
                    }

                    Section {
                        NavigationLink(
                            value: BitcoinWalletSettingsRoute.addresses(
                                addressType,
                                .external
                            )
                        ) {
                            BitcoinHDBranchSettingsRow(
                                statistics: snapshot.external
                            )
                        }
                        NavigationLink(
                            value: BitcoinWalletSettingsRoute.addresses(
                                addressType,
                                .change
                            )
                        ) {
                            BitcoinHDBranchSettingsRow(
                                statistics: snapshot.change
                            )
                        }
                    } header: {
                        Text("bitcoin.settings.branches.section")
                    } footer: {
                        Text("bitcoin.settings.branches.footer")
                    }

                    Section {
                        NavigationLink(
                            "bitcoin.settings.generate.external",
                            value: BitcoinWalletSettingsRoute.generate(
                                addressType,
                                .external
                            )
                        )
                        NavigationLink(
                            "bitcoin.settings.generate.change",
                            value: BitcoinWalletSettingsRoute.generate(
                                addressType,
                                .change
                            )
                        )
                    } header: {
                        Text("bitcoin.settings.generation.section")
                    } footer: {
                        Text("bitcoin.settings.generation.footer")
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
        .navigationTitle(Text(verbatim: addressType.localizedName))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
    }

    @MainActor
    private func load() async {
        do {
            let wallet = try await BitcoinWalletSettingsRepository(
                database: database
            ).load(walletID: walletID)
            snapshot = wallet.types.first {
                $0.descriptor.addressType == addressType
            }
            errorMessage = snapshot == nil
                ? WalletLocalization.string("bitcoin.settings.load.error")
                : nil
        } catch is CancellationError {
            return
        } catch {
            snapshot = nil
            errorMessage = WalletLocalization.string(
                "bitcoin.settings.load.error"
            )
        }
    }
}

private struct BitcoinHDBranchSettingsRow: View {
    let statistics: BitcoinHDBranchStatistics

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(statistics.branch.localizationKey))
            Text(
                EnglishNumbers.localized(
                    "bitcoin.settings.branch.summary",
                    statistics.currentIndex,
                    statistics.generatedCount,
                    statistics.usedCount
                )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}

extension BitcoinHDAddressBranch {
    var localizationKey: String {
        switch self {
        case .external:
            "bitcoin.settings.branch.external"
        case .change:
            "bitcoin.settings.branch.change"
        }
    }
}
