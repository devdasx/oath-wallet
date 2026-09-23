import SwiftUI

struct BitcoinAddressGenerationScreen: View {
    let walletID: String
    let addressType: BitcoinHDAddressType
    let initialBranch: BitcoinHDAddressBranch
    let database: WalletDatabase

    @State private var branch: BitcoinHDAddressBranch
    @State private var indexText = ""
    @State private var highestGeneratedIndex = -1
    @State private var isGenerating = false
    @State private var feedbackMessage: String?
    @State private var errorMessage: String?

    init(
        walletID: String,
        addressType: BitcoinHDAddressType,
        initialBranch: BitcoinHDAddressBranch,
        database: WalletDatabase
    ) {
        self.walletID = walletID
        self.addressType = addressType
        self.initialBranch = initialBranch
        self.database = database
        _branch = State(initialValue: initialBranch)
    }

    private var maximumIndex: Int {
        highestGeneratedIndex
            + WalletDatabase.bitcoinHDMaximumManualAddressAdvance
    }

    private var requestedIndex: Int? {
        guard !indexText.isEmpty,
              indexText.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(indexText),
              value >= 0,
              value <= maximumIndex else { return nil }
        return value
    }

    var body: some View {
        List {
            Group {
                Section {
                    Picker(
                        "bitcoin.settings.branch.label",
                        selection: $branch
                    ) {
                        Text("bitcoin.settings.branch.external")
                            .tag(BitcoinHDAddressBranch.external)
                        Text("bitcoin.settings.branch.change")
                            .tag(BitcoinHDAddressBranch.change)
                    }

                    LabeledContent(
                        "bitcoin.settings.highest_generated_index",
                        value: highestGeneratedIndex >= 0
                            ? String(highestGeneratedIndex) : "—"
                    )
                    LabeledContent(
                        "bitcoin.settings.maximum_batch_index",
                        value: maximumIndex >= 0 ? String(maximumIndex) : "—"
                    )

                    TextField(
                        "bitcoin.settings.target_index",
                        text: $indexText
                    )
                    .keyboardType(.asciiCapableNumberPad)
                    .walletTextInputDirection()
                    .onChange(of: indexText) { _, value in
                        let bytes = Array(
                            value.utf8.filter { (48...57).contains($0) }
                                .prefix(10)
                        )
                        let ascii = String(bytes: bytes, encoding: .ascii) ?? ""
                        if ascii != value { indexText = ascii }
                    }
                } header: {
                    Text("bitcoin.settings.generation.parameters.section")
                } footer: {
                    Text("bitcoin.settings.generation.limit.footer")
                }

                Section {
                    Button(action: UniHaptic.action {
                        generate()
                    }) {
                        Text(LocalizedStringKey(
                            isGenerating
                                ? "bitcoin.settings.generating"
                                : "bitcoin.settings.generate.through_index"
                        ))
                    }
                    .disabled(requestedIndex == nil || isGenerating)
                } footer: {
                    if let feedbackMessage {
                        Text(verbatim: feedbackMessage)
                    } else if let errorMessage {
                        Text(verbatim: errorMessage)
                            .foregroundStyle(WalletTheme.danger)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("bitcoin.settings.generate.title")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: branch) {
            await loadBranch()
        }
    }

    @MainActor
    private func loadBranch() async {
        do {
            let states = try await database.bitcoinHDAddresses(
                walletID: walletID,
                addressType: addressType,
                branch: branch
            )
            highestGeneratedIndex = states.map(\.derived.index).max() ?? -1
            if indexText.isEmpty {
                indexText = String(
                    highestGeneratedIndex
                        + BitcoinHDDerivationService.gapLimit
                )
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = WalletLocalization.string(
                "bitcoin.settings.load.error"
            )
        }
    }

    private func generate() {
        guard let requestedIndex else { return }
        isGenerating = true
        feedbackMessage = nil
        errorMessage = nil
        Task { @MainActor in
            do {
                _ = try await database.generateBitcoinHDAddresses(
                    walletID: walletID,
                    addressType: addressType,
                    branch: branch,
                    through: requestedIndex
                )
                feedbackMessage = EnglishNumbers.localized(
                    "bitcoin.settings.generation.success",
                    requestedIndex
                )
                await loadBranch()
            } catch is CancellationError {
                isGenerating = false
                return
            } catch {
                errorMessage = WalletLocalization.string(
                    "bitcoin.settings.generation.error"
                )
            }
            isGenerating = false
        }
    }
}
