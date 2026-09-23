import SwiftUI

struct BitcoinGeneratedAddressListScreen: View {
    let walletID: String
    let addressType: BitcoinHDAddressType
    let branch: BitcoinHDAddressBranch
    let database: WalletDatabase

    @State private var states: [BitcoinHDAddressState] = []
    @State private var currentIndex: Int?
    @State private var query = ""
    @State private var errorMessage: String?

    private var filteredStates: [BitcoinHDAddressState] {
        guard !query.isEmpty else { return states }
        let normalized = query.lowercased()
        return states.filter {
            String($0.derived.index).contains(normalized)
                || $0.derived.address.lowercased().contains(normalized)
                || $0.derived.derivationPath.lowercased()
                    .contains(normalized)
        }
    }

    var body: some View {
        List {
            Group {
                Section("bitcoin.settings.statistics.section") {
                    LabeledContent(
                        "bitcoin.settings.current_index",
                        value: currentIndex.map(String.init) ?? "—"
                    )
                    LabeledContent(
                        "bitcoin.settings.generated_addresses",
                        value: String(states.count)
                    )
                    LabeledContent(
                        "bitcoin.settings.used_addresses",
                        value: String(states.lazy.filter(\.isUsed).count)
                    )
                    LabeledContent(
                        "bitcoin.settings.reserved_addresses",
                        value: String(states.lazy.filter(\.isReserved).count)
                    )
                }

                Section {
                    ForEach(filteredStates, id: \.derived.index) { state in
                        NavigationLink(
                            value: BitcoinWalletSettingsRoute.address(
                                addressType,
                                branch,
                                state.derived.index
                            )
                        ) {
                            BitcoinGeneratedAddressRow(
                                state: state,
                                isCurrent: state.derived.index == currentIndex
                            )
                        }
                    }
                } header: {
                    Text("bitcoin.settings.generated_addresses")
                } footer: {
                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .foregroundStyle(WalletTheme.danger)
                    } else if filteredStates.isEmpty {
                        Text("bitcoin.settings.addresses.empty")
                    }
                }

                Section {
                    NavigationLink(
                        "bitcoin.settings.generate.more",
                        value: BitcoinWalletSettingsRoute.generate(
                            addressType,
                            branch
                        )
                    )
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle(Text(LocalizedStringKey(branch.localizationKey)))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            prompt: Text("bitcoin.settings.addresses.search")
        )
        .walletTextInputDirection()
        .task {
            await load()
        }
    }

    @MainActor
    private func load() async {
        do {
            let loaded = try await database.bitcoinHDAddresses(
                walletID: walletID,
                addressType: addressType,
                branch: branch
            )
            let preferred = try await database
                .bitcoinHDPreferredAddressIndex(
                    walletID: walletID,
                    addressType: addressType,
                    branch: branch
                )
            let automatic = (loaded.lazy.filter {
                $0.isUsed || $0.isReserved
            }.map(\.derived.index).max() ?? -1) + 1
            states = loaded
            currentIndex = preferred ?? automatic
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = WalletLocalization.string(
                "bitcoin.settings.load.error"
            )
        }
    }
}

private struct BitcoinGeneratedAddressRow: View {
    let state: BitcoinHDAddressState
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(
                    EnglishNumbers.localized(
                        "bitcoin.settings.address.index",
                        state.derived.index
                    )
                )
                Spacer(minLength: 12)
                Text(LocalizedStringKey(statusKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: state.derived.address)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !state.balanceAtomic.isZero {
                Text(verbatim: state.balanceAtomic.bitcoinSettingsDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusKey: String {
        if state.isUsed { return "bitcoin.settings.address.status.used" }
        if state.isReserved {
            return "bitcoin.settings.address.status.reserved"
        }
        if isCurrent { return "bitcoin.settings.address.status.current" }
        return "bitcoin.settings.address.status.unused"
    }
}
