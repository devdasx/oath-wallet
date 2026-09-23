import SwiftUI
import UIKit

struct TransactionExportView: View {
    let database: WalletDatabase
    @State private var model = TransactionExportModel()
    @State private var filter = TransactionExportFilter()
    @State private var format = TransactionExportFormat.csv
    @State private var exportTask: Task<Void, Never>?
    @State private var showsShareSheet = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var networks: [ReceiveNetwork] {
        ReceiveNetworkCatalog.catalogNetworkIdentifiers.compactMap { ReceiveNetworkCatalog.catalogNetwork(for: $0) }
            .sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
    }

    var body: some View {
        List {
            Group {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Label {
                            Text("transaction_export.subtitle")
                                .font(.headline)
                                .foregroundStyle(WalletTheme.primaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(WalletTheme.accent)
                                .accessibilityHidden(true)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            if let count = model.count {
                                Text(EnglishNumbers.integer(Int64(count)))
                                    .font(.system(.largeTitle, design: .rounded).bold())
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .foregroundStyle(WalletTheme.primaryLabel)
                            } else if model.errorKey != nil {
                                Text("—")
                                    .font(.largeTitle)
                                    .foregroundStyle(WalletTheme.secondaryLabel)
                            } else {
                                ProgressView()
                            }
                            Text("transaction_export.entries")
                                .foregroundStyle(WalletTheme.secondaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    Picker("wallet.transaction.details.network", selection: $filter.networkID.hapticSelection()) {
                        Text("wallet.activity.filter.network.all").tag(String?.none)
                        ForEach(networks) { network in
                            Text(LocalizedStringKey(network.nameKey)).tag(Optional(network.id))
                        }
                    }
                    Picker("transaction_export.date_range", selection: $filter.usesDateRange.hapticSelection()) {
                        Text("transaction_export.all_time").tag(false)
                        Text("transaction_export.custom_range").tag(true)
                    }
                    if filter.usesDateRange {
                        DatePicker("wallet.activity.filter.date.start", selection: $filter.startDate, displayedComponents: .date)
                        DatePicker("wallet.activity.filter.date.end", selection: $filter.endDate, displayedComponents: .date)
                    }
                }
                .foregroundStyle(WalletTheme.primaryLabel)

                Section {
                    Picker("transaction_export.format", selection: $format.hapticSelection()) {
                        ForEach(TransactionExportFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Toggle("transaction_export.include_notes", isOn: $filter.includesNotes.hapticSelection())
                        .foregroundStyle(WalletTheme.primaryLabel)
                } header: {
                    Text("transaction_export.format")
                } footer: {
                    Text("transaction_export.format_footer")
                }

                if let error = model.errorKey {
                    Section {
                        Text(LocalizedStringKey(error))
                            .foregroundStyle(WalletTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("common.retry", action: UniHaptic.action {
                            Task { await model.load(database: database, filter: filter) }
                        })
                    }
                } else if model.count == 0 {
                    Section {
                        WalletEmptyStateView("wallet.activity.filter.empty.title", message: "wallet.activity.filter.empty.message")
                    }
                }
            }
            .walletListRowSurface()
        }
        .disabled(model.isPreparing)
        .listStyle(.insetGrouped)
        .walletListAppearance()
        .navigationTitle("transaction_export.title")
        .navigationBarTitleDisplayMode(.inline)
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if model.isPreparing { ProgressView() }
                PrimaryWalletButton(title: model.isPreparing ? "transaction_export.preparing" : "transaction_export.action") {
                    exportTask = Task {
                        await model.prepare(database: database, filter: filter, format: format)
                    }
                }
                .disabled(model.isPreparing || (model.count ?? 0) == 0)
                .accessibilityIdentifier("transactionExportAction")
            }
            .walletActionScreenMargins()
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: filter.usesDateRange)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.count)
        .task(id: filter) { await model.load(database: database, filter: filter) }
        .onChange(of: model.document?.id) { _, id in
            if id != nil { showsShareSheet = true }
        }
        .sheet(isPresented: $showsShareSheet, onDismiss: model.discardDocument) {
            if let document = model.document {
                TransactionExportShareSheet(url: document.url)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { exportTask?.cancel() }
        }
        .onDisappear {
            exportTask?.cancel()
            if !showsShareSheet { model.discardDocument() }
        }
    }
}

private struct TransactionExportShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
