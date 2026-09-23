import SwiftUI

enum BitcoinReceiveAddressMode: Hashable {
    case silentPayments
    case hd(BitcoinHDAddressType)

    var localizedName: String {
        switch self {
        case .silentPayments:
            WalletLocalization.string(
                "receive.bitcoin.address_type.silent_payments"
            )
        case let .hd(type):
            type.localizedName
        }
    }

    /// Silent Payments is an intentional one-presentation choice. A new
    /// receive presentation always restores the last durable BIP address
    /// type instead of treating Silent Payments as that preference.
    static func restored(
        from addressType: BitcoinHDAddressType
    ) -> BitcoinReceiveAddressMode {
        .hd(addressType)
    }
}

struct BitcoinHDReceiveDetailsContent: View {
    private static let presentationOrder: [BitcoinHDAddressType] = [
        .bip86, .bip84, .bip49, .bip44, .brdSegwit, .brdLegacy
    ]

    let asset: WalletAsset
    let fallbackAddress: String
    let database: WalletDatabase

    @State private var walletID: String?
    @State private var selectedType = BitcoinHDAddressType.bip84
    @State private var selectedMode = BitcoinReceiveAddressMode.hd(.bip84)
    @State private var address: BitcoinHDDerivedAddress?
    @State private var muunAddress: MuunRecoveryDerivedAddress?
    @State private var silentPaymentAddress: String?
    @State private var legacyAddress: String?
    @State private var singleKeyWallet: BitcoinSingleKeyWallet?
    @State private var hdAddressTypes: [BitcoinHDAddressType] = []
    @State private var supportsSilentPayments = false
    @State private var usesHDWallet = false
    @State private var usesMuunRecoveryWallet = false
    @State private var didLoad = false
    @State private var selectionTask: Task<Void, Never>?
    @State private var showsBitcoinSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var network: ReceiveNetworkPresentation? {
        ReceiveNetworkPresentation(asset: asset)
    }

    private var displayedAddress: String? {
        if selectedMode == .silentPayments {
            return silentPaymentAddress
        }
        return muunAddress?.address ?? address?.address ?? legacyAddress
    }

    private var availableAddressTypes: [BitcoinHDAddressType] {
        Self.presentationOrder.filter { type in
            if let singleKeyWallet {
                return singleKeyWallet.address(for: type) != nil
            }
            return hdAddressTypes.contains(type)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let network {
                    ReceiveNetworkLabel(
                        networkName: network.localizedName,
                        logoSource: network.logoSource
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(
                        WalletTheme.mutedSecondaryFill,
                        in: Capsule()
                    )
                }

                if let displayedAddress, let network {
                    ReceiveQRCodeAddressCard(
                        address: displayedAddress,
                        payload: paymentPayload(displayedAddress),
                        showsBrandMark: true,
                        animatesPayloadReplacement: true
                    )

                    ReceiveAddressActionButtons(
                        context: ReceiveShareContext(
                            address: displayedAddress,
                            qrPayload: paymentPayload(displayedAddress),
                            assetSymbol: asset.symbol,
                            assetLogoSource: asset.logoSource,
                            networkName: network.localizedName,
                            networkLogoSource: network.logoSource
                        )
                    )

                    Text(
                        EnglishNumbers.localized(
                            "receive.bitcoin_family.warning",
                            asset.symbol,
                            network.localizedName
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                } else if didLoad {
                    unavailableContent
                } else {
                    Text("receive.details.loading")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 360, minHeight: 280)
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.28),
                value: displayedAddress
            )
        }
        .background(WalletTheme.groupedBackground)
        .navigationTitle(
            EnglishNumbers.localized(
                "receive.details.navigation.title",
                asset.symbol
            )
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if usesHDWallet {
                ToolbarItem(placement: .topBarTrailing) {
                    addressTypeMenu
                }
            }
        }
        .task(id: asset.id) {
            await loadFreshAddress()
        }
        .task(id: walletID) {
            await observeFreshAddress()
        }
        .sheet(isPresented: $showsBitcoinSettings) {
            if let walletID {
                BitcoinWalletSettingsFlow(
                    walletID: walletID,
                    database: database
                )
                .presentationDetents([.large])
            }
        }
    }

    private func addressTypeName(_ type: BitcoinHDAddressType) -> String {
        if let wallet = singleKeyWallet, let material = wallet.importedMaterial,
           let address = wallet.address(for: type) {
            let parts = address.derivationPath.split(separator: ":")
            if parts.count == 4, let source = Int(parts[1]), material.sources.indices.contains(source),
               material.sources[source].descriptor.script == .rawtr {
                return WalletLocalization.string("receive.bitcoin.address_type.rawtr")
            }
        }
        return type.localizedName
    }

    private var selectedAddressTypeName: String {
        if case let .hd(type) = selectedMode { return addressTypeName(type) }
        return selectedMode.localizedName
    }

    private var addressTypeMenu: some View {
        Menu {
            Menu("bitcoin.settings.types") {
                Picker(
                    "receive.bitcoin.address_type.label",
                    selection: addressTypeSelection
                ) {
                    if supportsSilentPayments {
                        Text("receive.bitcoin.address_type.silent_payments")
                            .tag(BitcoinReceiveAddressMode.silentPayments)
                    }
                    ForEach(availableAddressTypes, id: \.self) { type in
                        Text(verbatim: addressTypeName(type))
                            .tag(BitcoinReceiveAddressMode.hd(type))
                    }
                }
            }
            if singleKeyWallet == nil {
                Button("settings.title", action: UniHaptic.action(nil) {
                    showsBitcoinSettings = true
                })
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel(
            Text("receive.bitcoin.address_type.label")
        )
        .accessibilityValue(Text(verbatim: selectedAddressTypeName))
        .accessibilityIdentifier("bitcoinReceiveAddressTypeMenu")
    }

    private var addressTypeSelection: Binding<BitcoinReceiveAddressMode> {
        Binding(
            get: { selectedMode },
            set: { newMode in
                guard let selectionWalletID = walletID else { return }
                let precedingSelection = selectionTask
                selectedMode = newMode
                if case let .hd(type) = newMode {
                    selectedType = type
                }
                selectionTask = Task { @MainActor in
                    // Preserve user order. In particular, a regular BIP type
                    // chosen immediately before Silent Payments must finish
                    // persisting before the presentation-only Silent Payment
                    // selection is displayed.
                    await precedingSelection?.value
                    guard !Task.isCancelled else { return }
                    await selectAddressMode(
                        newMode,
                        walletID: selectionWalletID
                    )
                }
            }
        )
    }

    private var unavailableContent: some View {
        VStack(spacing: 10) {
            Text("receive.address.unavailable")
                .font(.headline)
            Text("receive.address.unavailable.message")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360, minHeight: 280)
    }

    private func paymentPayload(_ address: String) -> String {
        if selectedMode == .silentPayments {
            return "bitcoin:?sp=\(address)"
        }
        return "bitcoin:\(address)"
    }

    @MainActor
    private func loadFreshAddress() async {
        didLoad = false
        address = nil
        muunAddress = nil
        silentPaymentAddress = nil
        legacyAddress = nil
        singleKeyWallet = nil
        hdAddressTypes = []
        supportsSilentPayments = false
        usesHDWallet = false
        usesMuunRecoveryWallet = false
        var publishedLocalAddress = false
        do {
            guard let identity = try await database
                .selectedWalletIdentity() else {
                didLoad = true
                return
            }
            walletID = identity.walletID
            if try await database.muunRecoveryWallet(
                walletID: identity.walletID
            ) != nil {
                guard let localAddress = try await database
                    .freshMuunRecoveryReceiveAddress(
                        walletID: identity.walletID
                    ) else {
                    throw MuunRecoveryDiscoveryError.missingReceiveAddress
                }
                muunAddress = localAddress
                supportsSilentPayments = false
                usesHDWallet = false
                usesMuunRecoveryWallet = true
                didLoad = true
                publishedLocalAddress = true
                let result = try await MuunRecoveryDiscoveryService(
                    database: database
                ).discover(walletID: identity.walletID)
                guard !Task.isCancelled else { return }
                muunAddress = result.receiveAddress
                return
            }
            supportsSilentPayments = BitcoinSilentPaymentScanClient.isAvailable
            hdAddressTypes = try await database
                .bitcoinHDAccountDescriptors(walletID: identity.walletID)
                .map(\.addressType)
            let preparedType = try await database
                .restoreBitcoinStandardReceiveAddressType(
                    walletID: identity.walletID
                )
            if let prepared = try await database.freshBitcoinReceiveAddress(
                walletID: identity.walletID,
                addressType: preparedType
            ) {
                selectedType = preparedType
                selectedMode = .restored(from: preparedType)
                address = prepared
                usesHDWallet = true
                walletID = identity.walletID
                didLoad = true
                publishedLocalAddress = true
            }
            guard try await database.ensureBitcoinHDWallet(
                walletID: identity.walletID
            ) else {
                if let singleKey = try await database
                    .bitcoinSingleKeyWallet(walletID: identity.walletID) {
                    let preferred = try await database
                        .bitcoinReceiveAddressType(
                            walletID: identity.walletID
                        )
                    let selected = singleKey.address(for: preferred)
                        ?? singleKey.address(
                            for: singleKey.defaultAddressType
                        )
                    guard let selected else {
                        throw BitcoinHDDiscoveryError
                            .missingReceiveAddress
                    }
                    singleKeyWallet = singleKey
                    hdAddressTypes = []
                    supportsSilentPayments = false
                    selectedType = selected.addressType
                    selectedMode = .hd(selected.addressType)
                    address = selected
                    usesHDWallet = singleKey.addresses.count > 1
                    didLoad = true
                    return
                }
                legacyAddress = fallbackAddress
                didLoad = true
                return
            }
            hdAddressTypes = try await database
                .bitcoinHDAccountDescriptors(walletID: identity.walletID)
                .map(\.addressType)
            let type = try await database.bitcoinReceiveAddressType(
                walletID: identity.walletID
            )
            selectedType = type
            selectedMode = .restored(from: type)
            address = try await database.freshBitcoinReceiveAddress(
                walletID: identity.walletID,
                addressType: type
            )
            usesHDWallet = true
            walletID = identity.walletID
            didLoad = true
            publishedLocalAddress = displayedAddress != nil

            // Electrum discovery may advance the fresh child, but it never
            // gates the locally prepared QR address from being rendered.
            let result = try await BitcoinHDDiscoveryService(
                database: database
            ).discover(walletID: identity.walletID)
            guard !Task.isCancelled else { return }
            let refreshedType = try await database.bitcoinReceiveAddressType(
                walletID: identity.walletID
            )
            selectedType = refreshedType
            if selectedMode != .silentPayments {
                selectedMode = .hd(refreshedType)
                address = refreshedType == result.receiveAddress.addressType
                    ? result.receiveAddress
                    : try await database.freshBitcoinReceiveAddress(
                        walletID: identity.walletID,
                        addressType: refreshedType
                    )
            }
        } catch is CancellationError {
            return
        } catch {
            if !publishedLocalAddress {
                address = nil
            }
        }
        didLoad = true
    }

    @MainActor
    private func selectAddressMode(
        _ mode: BitcoinReceiveAddressMode,
        walletID: String
    ) async {
        do {
            switch mode {
            case .silentPayments:
                guard BitcoinSilentPaymentScanClient.isAvailable,
                      supportsSilentPayments,
                      singleKeyWallet == nil else {
                    throw BitcoinHDWalletDatabaseError.unsupportedWallet
                }
                guard try await database.ensureBitcoinSilentPaymentAccount(
                    walletID: walletID
                ), let account = try await database
                    .bitcoinSilentPaymentAccount(walletID: walletID) else {
                    throw BitcoinSilentPaymentDatabaseError.invalidAccount
                }
                try Task.checkCancellation()
                guard selectedMode == mode else { return }
                silentPaymentAddress = account.address.encoded
                selectedMode = .silentPayments
            case let .hd(type):
                if let singleKeyWallet {
                    guard singleKeyWallet.address(for: type) != nil else {
                        throw BitcoinHDWalletDatabaseError
                            .unsupportedWallet
                    }
                    let fresh = try await database
                        .setBitcoinSingleKeyReceiveAddressType(
                            type,
                            walletID: walletID
                        )
                    try Task.checkCancellation()
                    guard selectedMode == mode else { return }
                    selectedType = type
                    selectedMode = .hd(type)
                    address = fresh
                    return
                }
                try await database.setBitcoinReceiveAddressType(
                    type,
                    walletID: walletID
                )
                let fresh = try await database.freshBitcoinReceiveAddress(
                    walletID: walletID,
                    addressType: type
                )
                try Task.checkCancellation()
                guard selectedMode == mode else { return }
                selectedType = type
                selectedMode = .hd(type)
                address = fresh
            }
        } catch is CancellationError {
            return
        } catch {
            if selectedMode == mode {
                address = nil
            }
        }
    }

    @MainActor
    private func observeFreshAddress() async {
        guard let walletID,
              singleKeyWallet == nil,
              !usesMuunRecoveryWallet else { return }
        do {
            for try await fresh in database
                .bitcoinReceiveAddressObservation(walletID: walletID) {
                guard !Task.isCancelled else { return }
                guard let fresh else { continue }
                guard selectedMode == .hd(fresh.addressType) else {
                    continue
                }
                selectedType = fresh.addressType
                selectedMode = .hd(fresh.addressType)
                address = fresh
            }
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }
}
