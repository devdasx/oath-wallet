import SwiftUI

struct SettingsBackupBitcoinKeyAddressListScreen: View {
    let wallet: ManagedWallet
    let type: WalletBitcoinPrivateKeyExportCatalog.AddressType
    let isSensitiveContentProtected: Bool

    @State private var query = ""

    var body: some View {
        List {
            Group {
                ForEach(
                    [
                        BitcoinHDAddressBranch.external,
                        BitcoinHDAddressBranch.change,
                    ],
                    id: \.rawValue
                ) { branch in
                    Section {
                        ForEach(addresses(for: branch)) { address in
                            NavigationLink {
                                Group {
                                    SettingsBackupPrivateKeyDisplayScreen(
                                        wallet: wallet,
                                        item: address.displayItem
                                    )
                                    .walletSensitiveContentMask(
                                        isProtected:
                                            isSensitiveContentProtected
                                    )
                                }

                            } label: {
                                SettingsBackupBitcoinKeyAddressRow(
                                    address: address
                                )
                            }
                        }
                    } header: {
                        Text(LocalizedStringKey(branch.localizationKey))
                    } footer: {
                        if addresses(for: branch).isEmpty {
                            Text("bitcoin.settings.addresses.empty")
                        }
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle(Text(verbatim: type.addressType.localizedName))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            prompt: Text("bitcoin.settings.addresses.search")
        )
        .walletTextInputDirection()
    }

    private func addresses(
        for branch: BitcoinHDAddressBranch
    ) -> [WalletBitcoinPrivateKeyExportCatalog.Address] {
        type.addresses.filter { address in
            guard address.state.derived.branch == branch else {
                return false
            }
            guard !query.isEmpty else { return true }
            let normalized = query.lowercased()
            return String(address.state.derived.index).contains(normalized)
                || address.state.derived.address.lowercased()
                    .contains(normalized)
                || address.state.derived.derivationPath.lowercased()
                    .contains(normalized)
        }
    }
}

private struct SettingsBackupBitcoinKeyAddressRow: View {
    let address: WalletBitcoinPrivateKeyExportCatalog.Address

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(
                    EnglishNumbers.localized(
                        "bitcoin.settings.address.index",
                        address.state.derived.index
                    )
                )
                Spacer(minLength: 12)
                Text(LocalizedStringKey(statusKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: address.state.derived.address)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: address.state.derived.derivationPath)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusKey: String {
        if address.state.isUsed {
            return "bitcoin.settings.address.status.used"
        }
        if address.state.isReserved {
            return "bitcoin.settings.address.status.reserved"
        }
        return "bitcoin.settings.address.status.unused"
    }
}
