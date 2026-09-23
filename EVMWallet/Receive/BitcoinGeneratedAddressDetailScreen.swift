import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BitcoinGeneratedAddressDetailScreen: View {
    let walletID: String
    let addressType: BitcoinHDAddressType
    let branch: BitcoinHDAddressBranch
    let index: Int
    let database: WalletDatabase

    @State private var state: BitcoinHDAddressState?
    @State private var preferredIndex: Int?
    @State private var wifPresentation: BitcoinWIFExportPresentation?
    @State private var wifAuthenticationContext:
        WalletAuthenticationPasscodeContext?
    @State private var isWIFAuthenticationPresented = false
    @State private var pendingWIFGrant: WalletAuthenticationGrant?
    @State private var wifAccessTask: Task<Void, Never>?
    @State private var feedbackMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Group {
                if let state {
                    Section {
                        ReceiveQRCodeAddressCard(
                            address: state.derived.address,
                            payload: "bitcoin:\(state.derived.address)",
                            showsBrandMark: true
                        )
                        .frame(maxWidth: 380)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(WalletTheme.groupedBackground)
                    }

                    Section("bitcoin.settings.address.details.section") {
                        LabeledContent(
                            "bitcoin.settings.current_status"
                        ) {
                            Text(LocalizedStringKey(statusKey(for: state)))
                        }
                        LabeledContent("bitcoin.settings.current_index") {
                            Text(verbatim: String(index))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("bitcoin.settings.derivation_path")
                            WalletExactText(
                                state.derived.derivationPath, textStyle: .subheadline,
                                monospaced: true, foregroundColor: WalletTheme.secondaryLabel
                            )
                        }
                        LabeledContent(
                            "bitcoin.settings.confirmed_balance",
                            value: state.confirmedBalanceAtomic
                                .bitcoinSettingsDisplay
                        )
                        LabeledContent(
                            "bitcoin.settings.unconfirmed_balance",
                            value: state.unconfirmedBalanceAtomic
                                .bitcoinSettingsDisplay
                        )
                    }

                    Section {
                        Button("bitcoin.settings.address.copy", action: UniHaptic.action {
                            copyAddress(state.derived.address)
                        })
                        if !state.isUsed, !state.isReserved {
                            if preferredIndex == index {
                                Button("bitcoin.settings.address.use_automatic", action: UniHaptic.action {
                                    clearCurrentAddress()
                                })
                            } else {
                                Button("bitcoin.settings.address.make_current", action: UniHaptic.action {
                                    setCurrentAddress()
                                })
                            }
                        }
                        Button("bitcoin.settings.address.export_wif", action: UniHaptic.action {
                            requestWIFExport()
                        })
                        .disabled(
                            wifAccessTask != nil
                                || isWIFAuthenticationPresented
                        )
                    } header: {
                        Text("bitcoin.settings.address.actions.section")
                    } footer: {
                        if let feedbackMessage {
                            Text(verbatim: feedbackMessage)
                        } else if let errorMessage {
                            Text(verbatim: errorMessage)
                                .foregroundStyle(WalletTheme.danger)
                        } else {
                            Text("bitcoin.settings.address.actions.footer")
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
        .navigationTitle(
            EnglishNumbers.localized(
                "bitcoin.settings.address.index",
                index
            )
        )
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $wifPresentation) { presentation in
            NavigationStack {
                Group {
                    BitcoinAddressWIFExportScreen(
                        walletID: walletID,
                        addressType: addressType,
                        branch: branch,
                        index: index,
                        authorization: presentation.authorization,
                        database: database
                    )
                }

            }
            .walletSheetPresentation(nativeGlass: false)
            .presentationDetents([.large])
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
        .onAppear {
            Task { await load() }
        }
        .onDisappear {
            wifAccessTask?.cancel()
            wifAccessTask = nil
        }
    }

    @MainActor
    private func load() async {
        do {
            state = try await database.bitcoinHDAddresses(
                walletID: walletID,
                addressType: addressType,
                branch: branch
            ).first { $0.derived.index == index }
            preferredIndex = try await database
                .bitcoinHDPreferredAddressIndex(
                    walletID: walletID,
                    addressType: addressType,
                    branch: branch
                )
            errorMessage = state == nil
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

    private func setCurrentAddress() {
        Task { @MainActor in
            do {
                try await database.setBitcoinHDPreferredAddress(
                    walletID: walletID,
                    addressType: addressType,
                    branch: branch,
                    index: index
                )
                feedbackMessage = WalletLocalization.string(
                    "bitcoin.settings.address.current.saved"
                )
                await load()
            } catch {
                errorMessage = WalletLocalization.string(
                    "bitcoin.settings.address.current.error"
                )
            }
        }
    }

    private func clearCurrentAddress() {
        Task { @MainActor in
            do {
                try await database.clearBitcoinHDPreferredAddress(
                    walletID: walletID,
                    addressType: addressType,
                    branch: branch
                )
                feedbackMessage = WalletLocalization.string(
                    "bitcoin.settings.address.automatic.saved"
                )
                await load()
            } catch {
                errorMessage = WalletLocalization.string(
                    "bitcoin.settings.address.current.error"
                )
            }
        }
    }

    private func copyAddress(_ address: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: address]],
            options: [.localOnly: true]
        )
        feedbackMessage = WalletLocalization.string(
            "common.copied_to_clipboard"
        )
    }

    private func requestWIFExport() {
        guard wifAccessTask == nil, wifAuthenticationContext == nil else { return }
        feedbackMessage = nil
        errorMessage = nil
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
                errorMessage = WalletLocalization.string(
                    "bitcoin.settings.wif.error"
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
                errorMessage = WalletLocalization.string("bitcoin.settings.wif.error")
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

    private func statusKey(
        for state: BitcoinHDAddressState
    ) -> String {
        if state.isUsed { return "bitcoin.settings.address.status.used" }
        if state.isReserved {
            return "bitcoin.settings.address.status.reserved"
        }
        if preferredIndex == index {
            return "bitcoin.settings.address.status.current"
        }
        return "bitcoin.settings.address.status.unused"
    }
}
