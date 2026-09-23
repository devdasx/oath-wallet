import SwiftUI

struct EVMAccessManagerView: View {
    @StateObject private var model: EVMAccessManagerModel

    init(database: WalletDatabase) {
        _model = StateObject(
            wrappedValue: EVMAccessManagerModel(database: database)
        )
    }

    var body: some View {
        List {
            Group {
                if !model.approvals.isEmpty {
                    permissionsSection
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay {
            if model.approvals.isEmpty {
                EVMAccessEmptyStateView(
                    state: model.isAvailable ? model.refreshState : .unavailable
                )
            }
        }
        .walletSheetBackground(nativeGlass: false)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("evm_access.permissions.refresh", action: UniHaptic.action {
                    Task { await model.refresh() }
                })
                .disabled(model.refreshState == .loading || !model.isAvailable)
                .accessibilityIdentifier("evm_access.refresh")
            }
        }
        .navigationTitle("settings.tools.evm_access.title")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await model.load()
        }
        .onAppear {
            Task { await model.reloadCached() }
        }
    }

    private var permissionsSection: some View {
        Section {
            ForEach(model.approvals) { approval in
                if approval.pendingRevocationTransactionHash == nil {
                    NavigationLink(
                        value: WalletSettingsSearchRoute
                            .evmApprovalReview(approval)
                    ) {
                        EVMApprovalRow(approval: approval)
                    }
                } else {
                    EVMApprovalRow(approval: approval)
                }
            }
        } header: {
            Text("evm_access.permissions.title")
        } footer: {
            Text("evm_access.permissions.footer")
        }
    }

}
