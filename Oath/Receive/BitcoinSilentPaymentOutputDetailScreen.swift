import SwiftUI

struct BitcoinSilentPaymentOutputDetailScreen: View {
    let walletID: String
    let transactionHash: String
    let outputIndex: Int
    let database: WalletDatabase

    @State private var output: BitcoinSilentPaymentOutput?
    @State private var wifPresentation: BitcoinWIFExportPresentation?
    @State private var wifAuthenticationContext:
        WalletAuthenticationPasscodeContext?
    @State private var isWIFAuthenticationPresented = false
    @State private var pendingWIFGrant: WalletAuthenticationGrant?
    @State private var wifAccessTask: Task<Void, Never>?
    @State private var wifExportErrorMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Group {
                if let output {
                    Section("bitcoin.settings.address.details.section") {
                        LabeledContent("bitcoin.settings.current_status") {
                            Text(LocalizedStringKey(
                                output.isSpent
                                    ? "bitcoin.settings.address.status.spent"
                                    : "bitcoin.settings.address.status.unspent"
                            ))
                        }
                        LabeledContent(
                            "bitcoin.settings.balance",
                            value: output.valueAtomic.bitcoinSettingsDisplay
                        )
                        LabeledContent(
                            "bitcoin.settings.silent.output_index",
                            value: String(output.outputIndex)
                        )
                        LabeledContent(
                            "bitcoin.settings.silent.block_height",
                            value: output.blockHeight.map(String.init) ?? "—"
                        )
                    }

                    Section("bitcoin.settings.silent.transaction.section") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("bitcoin.settings.silent.transaction_hash")
                            WalletExactText(output.transactionHash, textStyle: .caption1, monospaced: true, foregroundColor: WalletTheme.secondaryLabel)
                        }
                        if let spentBy = output.spentByTransactionHash {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("bitcoin.settings.silent.spent_by")
                                WalletExactText(spentBy, textStyle: .caption1, monospaced: true, foregroundColor: WalletTheme.secondaryLabel)
                            }
                        }
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("bitcoin.settings.silent.output_public_key")
                            WalletExactText(output.outputPublicKey.hexString, textStyle: .caption1, monospaced: true, foregroundColor: WalletTheme.secondaryLabel)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("bitcoin.settings.silent.script_public_key")
                            WalletExactText(output.scriptPubKey.hexString, textStyle: .caption1, monospaced: true, foregroundColor: WalletTheme.secondaryLabel)
                        }
                        Button("bitcoin.settings.silent.export", action: UniHaptic.action {
                            requestWIFExport()
                        })
                        .disabled(
                            output.isSpent || wifAccessTask != nil
                                || isWIFAuthenticationPresented
                        )
                    } header: {
                        Text("bitcoin.settings.silent.output_keys.section")
                    } footer: {
                        if let wifExportErrorMessage {
                            Text(verbatim: wifExportErrorMessage)
                                .foregroundStyle(WalletTheme.danger)
                        } else {
                            Text("bitcoin.settings.silent.wif.footer")
                        }
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
        .navigationTitle("bitcoin.settings.silent.output.title")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $wifPresentation) { presentation in
            NavigationStack {
                Group {
                    BitcoinSilentPaymentOutputExportScreen(
                        walletID: walletID,
                        transactionHash: transactionHash,
                        outputIndex: outputIndex,
                        authorization: presentation.authorization,
                        database: database
                    )
                }

            }
            .presentationDetents([.large])
            .walletSheetPresentation(nativeGlass: false)
        }
        .fullScreenCover(
            isPresented: $isWIFAuthenticationPresented,
            onDismiss: wifAuthenticationDidDismiss
        ) {
            if let context = wifAuthenticationContext {
                WalletAuthenticationFullScreenContainer(
                    title: "security.authentication.navigation_title"
                ) {
                    WalletSecurityAuthenticationView(
                        database: database,
                        settings: context.settings,
                        purpose: .walletSensitiveData,
                        beginsWithPasscode: true,
                        initialErrorKey: context.initialErrorKey,
                        onAuthenticationGranted:
                            completeWIFAuthentication
                    )
                }
            }
        }
        .task {
            await load()
        }
        .onDisappear {
            wifAccessTask?.cancel()
            wifAccessTask = nil
        }
    }

    @MainActor
    private func load() async {
        do {
            output = try await database.bitcoinSilentPaymentOutputs(
                walletID: walletID
            ).first {
                $0.transactionHash == transactionHash.lowercased()
                    && $0.outputIndex == outputIndex
            }
            errorMessage = output == nil
                ? WalletLocalization.string("bitcoin.settings.load.error")
                : nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = WalletLocalization.string(
                "bitcoin.settings.load.error"
            )
        }
    }

    private func requestWIFExport() {
        guard wifAccessTask == nil, wifAuthenticationContext == nil else { return }
        wifExportErrorMessage = nil
        wifAccessTask = Task { @MainActor in
            defer { wifAccessTask = nil }
            do {
                let preparation = try await WalletSensitiveActionAuthorizer
                    .prepare(database: database)
                try Task.checkCancellation()
                switch preparation {
                case let .authorized(grant):
                    try await presentWIF(using: grant)
                case let .requiresPasscode(context):
                    wifAuthenticationContext = context
                    isWIFAuthenticationPresented = true
                case .cancelled:
                    break
                }
            } catch is CancellationError {
            } catch {
                wifExportErrorMessage = WalletLocalization.string(
                    "settings.wallets.private_key.export.load.error"
                )
            }
        }
    }

    private func completeWIFAuthentication(
        _ grant: WalletAuthenticationGrant
    ) {
        pendingWIFGrant = grant
        isWIFAuthenticationPresented = false
    }

    private func wifAuthenticationDidDismiss() {
        let grant = pendingWIFGrant
        pendingWIFGrant = nil
        wifAuthenticationContext = nil
        guard let grant, wifAccessTask == nil else { return }
        wifAccessTask = Task { @MainActor in
            defer { wifAccessTask = nil }
            do {
                try await presentWIF(using: grant)
            } catch is CancellationError {
            } catch {
                wifExportErrorMessage = WalletLocalization.string("settings.wallets.private_key.export.load.error")
            }
        }
    }

    @MainActor
    private func presentWIF(
        using grant: WalletAuthenticationGrant
    ) async throws {
        try await WalletAuthenticationPresentationReadiness().wait()
        let authorization = try await database.authorizeSecretExport(
            walletID: walletID,
            authenticationGrant: grant
        )
        try Task.checkCancellation()
        wifPresentation = BitcoinWIFExportPresentation(
            authorization: authorization
        )
    }
}
