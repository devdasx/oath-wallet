import SwiftUI

/// Owns the Settings tools catalog. Each tool remains an independent
/// destination while this screen provides one stable place for future tools.
struct ToolsSettingsView: View {
    let database: WalletDatabase
    @State private var showsEVMAccessManager = false

    var body: some View {
        List {
            Group {
                Section {
                    NavigationLink(
                        value: WalletSettingsSearchRoute.currencyConverter
                    ) {
                        SettingsNavigationLabel(
                            title: "settings.converter.title",
                            icon: .currencyConverter
                        )
                    }

                    NavigationLink(value: WalletSettingsSearchRoute.networkFeeDashboard) {
                        SettingsNavigationLabel(title: "network_fees.title", icon: .networkFees)
                    }

                    NavigationLink(value: WalletSettingsSearchRoute.transactionExport) {
                        SettingsNavigationLabel(title: "transaction_export.title", icon: .transactionExport)
                    }

                    NavigationLink(
                        value: WalletSettingsSearchRoute
                            .bitcoinTransactionBroadcaster
                    ) {
                        SettingsNavigationLabel(
                            title:
                                "settings.tools.broadcast_bitcoin.title",
                            icon: .bitcoinTransactionBroadcaster
                        )
                    }

                    NavigationLink(
                        value: WalletSettingsSearchRoute
                            .mnemonicLastWordFinder
                    ) {
                        SettingsNavigationLabel(
                            title:
                                "settings.tools.mnemonic_last_word.title",
                            icon: .mnemonicLastWordFinder
                        )
                    }
                }

                if showsEVMAccessManager {
                    Section("settings.tools.evm_access.section") {
                        NavigationLink(
                            value: WalletSettingsSearchRoute
                                .evmAccessManager
                        ) {
                            SettingsNavigationLabel(
                                title: "settings.tools.evm_access.title",
                                icon: .evmAccessManager
                            )
                        }
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("settings.section.tools")
        .navigationBarTitleDisplayMode(.large)
        .task {
            showsEVMAccessManager = (try? await database
                .selectedWalletEVMAccessContext()) != nil
        }
    }
}

#Preview("Tools") {
    WalletDatabasePreviewHost { database in
        NavigationStack {
            ToolsSettingsView(database: database)
                .navigationDestination(
                    for: WalletSettingsSearchRoute.self
                ) { route in
                    if route == .currencyConverter {
                        CurrencyConverterView(database: database)
                    } else if route == .networkFeeDashboard {
                        NetworkFeeDashboardView(database: database)
                    } else if route == .transactionExport {
                        TransactionExportView(database: database)
                    } else if case let .networkFeeDetails(networkID) = route {
                        NetworkFeeDetailsView(database: database, networkID: networkID)
                    } else if route == .bitcoinTransactionBroadcaster {
                        BitcoinTransactionBroadcastView()
                    } else if route == .mnemonicLastWordFinder {
                        MnemonicLastWordFinderView()
                    } else if route == .evmAccessManager {
                        EVMAccessManagerView(database: database)
                    } else if case let .evmApprovalReview(approval) = route {
                        EVMApprovalReviewScreen(
                            database: database,
                            approval: approval
                        )
                    }
                }
        }
    }
}
