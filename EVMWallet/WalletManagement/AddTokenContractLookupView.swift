import SwiftUI
import UIKit

struct AddTokenContractLookupView: View {
    private enum LookupFailure: Hashable {
        case invalidAddress
        case notFound
        case invalidMetadata
        case unsafeToken
        case missingConfiguration
        case invalidConfiguration
        case invalidCredentials
        case unsupportedNetwork
        case http(statusCode: Int, providerMessage: String?)
        case rpc(code: Int, message: String)
        case invalidResponse
        case transport(code: Int, message: String)
        case decoding(message: String)
        case unexpected(message: String)
    }

    private enum LookupState {
        case idle
        case loading
        case found(CustomToken)
        case failed(LookupFailure)

        var token: CustomToken? {
            guard case let .found(token) = self else { return nil }
            return token
        }
    }

    let database: WalletDatabase
    let network: ReceiveNetwork
    let onTokenSaved: (WalletAsset) -> Void

    @Environment(\.walletCurrencyContext) private var currencyContext

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isContractFocused: Bool
    @State private var contractAddress = ""
    @State private var lookupState = LookupState.idle
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    @State private var isScannerPresented = false

    var body: some View {
        List {
            Group {
                Section {
                    TextField(
                        addressPlaceholderKey,
                        text: $contractAddress
                    )
                    .walletTextInputDirection()
                    .font(.body)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isContractFocused)
                    .onChange(of: contractAddress) { _, newValue in
                        let sanitized = CustomTokenAddress.sanitizedInput(
                            newValue,
                            networkID: network.id
                        )
                        if sanitized != newValue {
                            contractAddress = sanitized
                        }
                    }
                } header: {
                    Text(addressSectionKey)
                } footer: {
                    Text(addressFooterKey)
                }

                Section {
                    utilityActions
                        .walletActionUsesContainerMargins()
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }

                lookupContent
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("wallet.assets.add_token.contract.title")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isScannerPresented) {
            NavigationStack {
                Group {
                    AddTokenContractScannerView(
                        network: network,
                        onRecognized: { scannedValue in
                            guard let contract = CustomTokenAddress.extracted(
                                from: scannedValue,
                                networkID: network.id
                            ) else {
                                UniHaptic.play(.error)
                                return false
                            }
                            contractAddress = contract
                            isScannerPresented = false
                            UniHaptic.play(.successQuiet)
                            return true
                        }
                    )
                }

            }
            .walletScannerPresentation()
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if let token = lookupState.token {
                    WalletConfirmationButton("wallet.assets.add_token.save") {
                        save(token)
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("addTokenConfirm")
                }
            }
        }
        .task(id: contractAddress) {
            await lookupContractIfReady()
        }
        .alert(
            "wallet.assets.add_token.save_error.title",
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        saveErrorMessage = nil
                    }
                }
            )
        ) {
            Button("common.done", action: UniHaptic.action {
                saveErrorMessage = nil
            })
        } message: {
            if let saveErrorMessage {
                Text(verbatim: saveErrorMessage)
            }
        }
    }

    private var addressSectionKey: LocalizedStringKey {
        network.id == SolanaConstants.networkID
            ? "wallet.assets.add_token.mint.section"
            : "wallet.assets.add_token.contract.section"
    }

    private var addressPlaceholderKey: LocalizedStringKey {
        switch network.id {
        case SolanaConstants.networkID:
            "wallet.assets.add_token.mint.placeholder"
        case TronConstants.networkID:
            "wallet.assets.add_token.tron.placeholder"
        default:
            "wallet.assets.add_token.contract.placeholder"
        }
    }

    private var addressFooterKey: LocalizedStringKey {
        network.id == SolanaConstants.networkID
            ? "wallet.assets.add_token.mint.footer"
            : "wallet.assets.add_token.contract.footer"
    }

    private var addressDetailKey: LocalizedStringKey {
        network.id == SolanaConstants.networkID
            ? "wallet.assets.add_token.mint.section"
            : "wallet.asset.details.contract"
    }

    private var invalidAddressTitleKey: LocalizedStringKey {
        switch network.id {
        case SolanaConstants.networkID:
            "wallet.assets.add_token.invalid_solana.title"
        case TronConstants.networkID:
            "wallet.assets.add_token.invalid_tron.title"
        default:
            "wallet.assets.add_token.invalid.title"
        }
    }

    private var invalidAddressMessage: String {
        let key = switch network.id {
        case SolanaConstants.networkID:
            "wallet.assets.add_token.invalid_solana.message"
        case TronConstants.networkID:
            "wallet.assets.add_token.invalid_tron.message"
        default:
            "wallet.assets.add_token.invalid.message"
        }
        return WalletLocalization.string(key)
    }

    @ViewBuilder
    private var utilityActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 12) {
                pasteButton
                scanButton
            }
        } else {
            HStack(spacing: 12) {
                pasteButton
                scanButton
            }
        }
    }

    private var pasteButton: some View {
        MutedWalletActionButton(
            title: "common.paste",
            prominence: .primary
        ) {
            guard let clipboardValue = UIPasteboard.general.string else {
                return
            }
            replaceContractInput(with: clipboardValue)
        }
    }

    private var scanButton: some View {
        MutedWalletActionButton(
            title: "common.scan",
            prominence: .secondary
        ) {
            isContractFocused = false
            isScannerPresented = true
        }
        .accessibilityIdentifier("tokenContractScan")
    }

    @ViewBuilder
    private var lookupContent: some View {
        switch lookupState {
        case .idle:
            EmptyView()
        case .loading:
            Section {
                Text("wallet.assets.add_token.searching")
                    .foregroundStyle(.secondary)
            }
        case let .found(token):
            tokenDetails(token)
        case let .failed(failure):
            Section {
                lookupFailure(failure)
            }
        }
    }

    private func tokenDetails(
        _ token: CustomToken
    ) -> some View {
        Section {
            UnifiedAssetSelectionRow(
                name: token.name,
                symbol: token.symbol,
                logoSource: token.logoSource,
                networkLogoSource: network.logoSource,
                balance: nil,
                fiatValue: nil,
                isBalanceHidden: false
            )

            LabeledContent("wallet.asset.details.network") {
                HStack(spacing: 8) {
                    AssetLogoView(
                        source: network.logoSource,
                        size: 24
                    )
                    Text(verbatim: network.localizedName)
                }
            }

            LabeledContent(
                "wallet.asset.details.symbol",
                value: token.symbol
            )

            LabeledContent("wallet.assets.add_token.decimals") {
                Text(
                    verbatim: EnglishNumbers.integer(
                        Int64(token.decimals)
                    )
                )
            }

            LabeledContent("wallet.asset.details.price") {
                Text(verbatim: EnglishNumbers.unitPrice(token.usdPrice ?? 0, using: currencyContext))
                    .foregroundStyle(.secondary)
            }

            LabeledContent {
                WalletExactText(
                    token.address, textStyle: .footnote, monospaced: true,
                    foregroundColor: WalletTheme.secondaryLabel
                )
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Text(addressDetailKey)
            }
        } header: {
            Text("wallet.assets.add_token.details.section")
        } footer: {
            Text("wallet.assets.add_token.details.footer")
        }
    }

    private func lookupFailure(
        _ failure: LookupFailure
    ) -> some View {
        let content: (
            title: LocalizedStringKey,
            image: String,
            message: String
        ) = switch failure {
        case .invalidAddress:
            (
                invalidAddressTitleKey,
                "exclamationmark.triangle",
                invalidAddressMessage
            )
        case .notFound:
            (
                "wallet.assets.add_token.not_found.title",
                "questionmark.circle",
                WalletLocalization.string(
                    "wallet.assets.add_token.not_found.message"
                )
            )
        case .invalidMetadata:
            (
                "wallet.assets.add_token.invalid_metadata.title",
                "exclamationmark.triangle",
                WalletLocalization.string(
                    "wallet.assets.add_token.invalid_metadata.message"
                )
            )
        case .unsafeToken:
            (
                "wallet.assets.add_token.unsafe.title",
                "hand.raised",
                WalletLocalization.string(
                    "wallet.assets.add_token.unsafe.message"
                )
            )
        case .missingConfiguration:
            (
                "wallet.assets.add_token.configuration_missing.title",
                "wrench.and.screwdriver",
                WalletLocalization.string(
                    "wallet.assets.add_token.configuration_missing.message"
                )
            )
        case .invalidConfiguration:
            (
                "wallet.assets.add_token.configuration_invalid.title",
                "wrench.and.screwdriver",
                WalletLocalization.string(
                    "wallet.assets.add_token.configuration_invalid.message"
                )
            )
        case .invalidCredentials:
            (
                "wallet.assets.add_token.authentication.title",
                "key",
                WalletLocalization.string(
                    "wallet.assets.add_token.authentication.message"
                )
            )
        case .unsupportedNetwork:
            (
                "wallet.assets.add_token.unsupported.title",
                "network.slash",
                WalletLocalization.string(
                    "wallet.assets.add_token.unsupported.message"
                )
            )
        case let .http(statusCode, providerMessage):
            (
                "wallet.assets.add_token.provider_error.title",
                "exclamationmark.icloud",
                providerMessage.map {
                    EnglishNumbers.localized(
                        "wallet.assets.add_token.http_provider_error.message",
                        Int64(statusCode),
                        $0 as NSString
                    )
                } ?? EnglishNumbers.localized(
                    "wallet.assets.add_token.http_error.message",
                    Int64(statusCode)
                )
            )
        case let .rpc(code, message):
            (
                "wallet.assets.add_token.provider_error.title",
                "exclamationmark.icloud",
                EnglishNumbers.localized(
                    "wallet.assets.add_token.rpc_error.message",
                    Int64(code),
                    message as NSString
                )
            )
        case .invalidResponse:
            (
                "wallet.assets.add_token.invalid_response.title",
                "exclamationmark.icloud",
                WalletLocalization.string(
                    "wallet.assets.add_token.invalid_response.message"
                )
            )
        case let .transport(code, message):
            (
                "wallet.assets.add_token.transport_error.title",
                "network.slash",
                EnglishNumbers.localized(
                    "wallet.assets.add_token.transport_error.message",
                    Int64(code),
                    message as NSString
                )
            )
        case let .decoding(message):
            (
                "wallet.assets.add_token.decoding_error.title",
                "exclamationmark.icloud",
                EnglishNumbers.localized(
                    "wallet.assets.add_token.decoding_error.message",
                    message as NSString
                )
            )
        case let .unexpected(message):
            (
                "wallet.assets.add_token.unexpected_error.title",
                "exclamationmark.triangle",
                EnglishNumbers.localized(
                    "wallet.assets.add_token.unexpected_error.message",
                    message as NSString
                )
            )
        }

        return ContentUnavailableView(
            content.title,
            systemImage: content.image,
            description: Text(verbatim: content.message)
        )
    }

    @MainActor
    private func lookupContractIfReady() async {
        let trimmed = contractAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            lookupState = .idle
            return
        }
        guard let normalizedContract = CustomTokenAddress.normalized(
            trimmed,
            networkID: network.id
        ) else {
            lookupState = CustomTokenAddress.isCompleteInvalidCandidate(
                trimmed,
                networkID: network.id
            ) ? .failed(.invalidAddress) : .idle
            return
        }

        lookupState = .loading
        do {
            try await Task.sleep(for: .milliseconds(350))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        do {
            let token: CustomToken
            switch network.id {
            case SolanaConstants.networkID:
                token = .solana(
                    try await SolanaTokenEligibilityClient.shared
                        .lookupToken(
                            network: network,
                            mint: normalizedContract
                        )
                )
            case TronConstants.networkID:
                token = .tron(
                    try await TronAPIClient.shared.lookupToken(
                        network: network,
                        contractAddress: normalizedContract
                    )
                )
            default:
                let client = try AnkrAPIClient.localBuild()
                token = .evm(
                    try await client.lookupToken(
                        network: network,
                        contractAddress: normalizedContract
                    )
                )
            }
            try Task.checkCancellation()
            lookupState = .found(token)
        } catch is CancellationError {
            return
        } catch let error as SolanaCustomTokenLookupError {
            lookupState = .failed(Self.lookupFailure(for: error))
        } catch let error as TronCustomTokenLookupError {
            lookupState = .failed(Self.lookupFailure(for: error))
        } catch let error as SolanaTokenEligibilityError {
            lookupState = .failed(Self.lookupFailure(for: error))
        } catch let error as TronRPCError {
            lookupState = .failed(
                .rpc(code: error.code, message: error.message)
            )
        } catch let error as AnkrAPIError {
            lookupState = .failed(Self.lookupFailure(for: error))
        } catch let error as URLError {
            lookupState = .failed(
                .transport(
                    code: error.errorCode,
                    message: error.localizedDescription
                )
            )
        } catch let error as DecodingError {
            lookupState = .failed(
                .decoding(message: String(describing: error))
            )
        } catch {
            lookupState = .failed(
                .unexpected(message: String(describing: error))
            )
        }
    }

    @MainActor
    private func save(_ token: CustomToken) {
        guard !isSaving else { return }
        isSaving = true

        Task {
            do {
                let asset = try await database.saveCustomToken(token)
                guard !Task.isCancelled else { return }
                UniHaptic.play(.success)
                isSaving = false
                onTokenSaved(asset)
            } catch {
                guard !Task.isCancelled else { return }
                UniHaptic.play(.error)
                isSaving = false
                saveErrorMessage = WalletLocalization.string(
                    "wallet.assets.add_token.save_error.message"
                )
            }
        }
    }

    private func replaceContractInput(with value: String) {
        contractAddress = CustomTokenAddress.extracted(
            from: value,
            networkID: network.id
        ) ?? CustomTokenAddress.sanitizedInput(
            value,
            networkID: network.id
        )
    }

    private static func lookupFailure(
        for error: AnkrAPIError
    ) -> LookupFailure {
        switch error {
        case .invalidWalletAddress, .invalidContractAddress:
            .invalidAddress
        case .tokenNotFound:
            .notFound
        case .invalidTokenMetadata:
            .invalidMetadata
        case .missingConfiguration:
            .missingConfiguration
        case .invalidProxyConfiguration:
            .invalidConfiguration
        case .invalidAPIKey:
            .invalidCredentials
        case let .developmentCredentialPersistenceFailure(status):
            .unexpected(
                message: AnkrAPIError
                    .developmentCredentialPersistenceFailure(status)
                    .diagnosticDescription
            )
        case .unsupportedBlockchain:
            .unsupportedNetwork
        case .invalidResponse:
            .invalidResponse
        case let .httpFailure(statusCode, message):
            .http(
                statusCode: statusCode,
                providerMessage: message
            )
        case let .rpcFailure(code, message):
            .rpc(code: code, message: message)
        }
    }

    private static func lookupFailure(
        for error: SolanaCustomTokenLookupError
    ) -> LookupFailure {
        switch error {
        case .unsupportedNetwork: .unsupportedNetwork
        case .invalidMint: .invalidAddress
        case .tokenNotFound: .notFound
        case .invalidMintAccount, .invalidMetadata: .invalidMetadata
        case .unsafeToken: .unsafeToken
        }
    }

    private static func lookupFailure(
        for error: TronCustomTokenLookupError
    ) -> LookupFailure {
        switch error {
        case .unsupportedNetwork: .unsupportedNetwork
        case .invalidContractAddress: .invalidAddress
        case .tokenNotFound: .notFound
        case .invalidMetadata: .invalidMetadata
        case .unsafeToken: .unsafeToken
        }
    }

    private static func lookupFailure(
        for error: SolanaTokenEligibilityError
    ) -> LookupFailure {
        switch error {
        case .invalidResponse:
            .invalidResponse
        case let .httpFailure(statusCode, providerMessage):
            .http(
                statusCode: statusCode,
                providerMessage: providerMessage
            )
        case let .allEndpointsFailed(lastFailure):
            .unexpected(message: lastFailure)
        }
    }
}
