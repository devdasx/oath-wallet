import SwiftUI

struct SendAssetSelectionScreen: View {
    let request: SendPaymentRequest
    let choices: [SendAssetChoice]
    let transactions: [WalletTransaction]
    let onSelected: (SendAssetChoice) -> String?
    private let networkOptions: [AssetNetworkSelectorOption]
    private let networkSelectionOrdering:
        WalletNetworkSelectionOrdering

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WalletSettingsStore.self) private var applicationSettings
    @State private var searchText = ""
    @State private var selectedNetworkID: String?
    @State private var selectionError: String?
    @State private var displayedChoices: [SendAssetChoice]

    init(
        request: SendPaymentRequest,
        choices: [SendAssetChoice],
        transactions: [WalletTransaction],
        onSelected: @escaping (SendAssetChoice) -> String?
    ) {
        self.request = request
        self.choices = choices
        self.transactions = transactions
        self.onSelected = onSelected
        // A family chip is offered as soon as one of its members can be sent.
        let availableNetworkIDs = Set(choices.map(\.networkID))
            .union(choices.compactMap { $0.family?.selectorID })
        networkOptions = AssetNetworkSelectorOption.allSelectable.filter {
            availableNetworkIDs.contains($0.id)
        }
        networkSelectionOrdering = WalletNetworkSelectionOrdering(
            sendChoices: choices,
            transactions: transactions
        )
        let initialNetworkID: String?
        if let requested = request.requestedNetworkID,
           availableNetworkIDs.contains(requested) {
            initialNetworkID = requested
        } else if availableNetworkIDs.count == 1 {
            initialNetworkID = availableNetworkIDs.first
        } else {
            initialNetworkID = nil
        }
        _selectedNetworkID = State(initialValue: initialNetworkID)
        _displayedChoices = State(
            initialValue: SendAssetChoiceCatalog.filtered(
                choices,
                networkID: initialNetworkID,
                searchText: ""
            )
        )
    }

    var body: some View {
        List {
            Group {
                if let selectionError {
                    Section {
                        Text(verbatim: selectionError)
                            .foregroundStyle(WalletTheme.danger)
                    }
                }

                Section {
                    if displayedChoices.isEmpty {
                        WalletSearchEmptyStateView()
                    } else {
                        ForEach(displayedChoices) { choice in
                            Button(action: UniHaptic.action {
                                choose(choice)
                            }) {
                                UnifiedAssetSelectionRow(
                                    name: choice.name,
                                    symbol: choice.symbol,
                                    logoSource: choice.logoSource,
                                    networkLogoSource:
                                        choice.networkLogoSource,
                                    familyLogoSource:
                                        choice.familyLogoSource,
                                    balance: choice.balance,
                                    fiatValue: choice.fiatValue,
                                    isBalanceHidden:
                                        applicationSettings
                                            .balancePrivacyEnabled,
                                    logoDiagnosticIdentity: choice.id
                                )
                            }
                            .buttonStyle(.automatic)
                        }
                    }
                } header: {
                    Text("send.assets.section")
                } footer: {
                    Text("send.assets.footer")
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("send.asset_selection.title")
        .navigationBarTitleDisplayMode(.inline)
        .assetNetworkAppBar(
            isPresented: networkOptions.count > 1,
            options: networkOptions,
            selectedNetworkID: $selectedNetworkID,
            ordering: networkSelectionOrdering
        )
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text("send.search.prompt")
        )
        .walletTextInputDirection()
        .walletAutomaticSearchToolbarBehavior()
        .task(id: SearchRequest(
            query: searchText,
            networkID: selectedNetworkID,
            choices: choices.map {
                ChoiceRevision(
                    id: $0.id,
                    balance: $0.balance,
                    fiatValue: $0.fiatValue
                )
            }
        )) {
            await prepareDisplayedChoices()
        }
    }

    @MainActor
    private func prepareDisplayedChoices() async {
        let query = searchText
        let networkID = selectedNetworkID
        if !AssetDiscoveryRanking.normalized(query).isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
        }
        let source = choices
        let result = await Task.detached(priority: .userInitiated) {
            SendAssetChoiceCatalog.filtered(
                source,
                networkID: networkID,
                searchText: query
            )
        }.value
        guard !Task.isCancelled else { return }
        AssetListRenderingWindow.replaceBalanceRankedResults(
            currentIDs: displayedChoices.map(\.id),
            updatedIDs: result.map(\.id),
            reduceMotion: reduceMotion
        ) {
            displayedChoices = result
        }
    }

    private func choose(_ choice: SendAssetChoice) {
        selectionError = onSelected(choice)
        if selectionError != nil {
            UniHaptic.play(.error)
        } else {
            UniHaptic.play(.selection)
        }
    }

    private struct SearchRequest: Hashable {
        let query: String
        let networkID: String?
        let choices: [ChoiceRevision]
    }

    private struct ChoiceRevision: Hashable {
        let id: String
        let balance: Decimal
        let fiatValue: Decimal
    }
}
