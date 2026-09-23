import SwiftUI

struct BitcoinFamilyHDReceiveContent: View {
    let asset: WalletAsset
    let chain: BitcoinFamilyChain
    let fallbackAddress: String
    let database: WalletDatabase
    @State private var address: String?
    @State private var isHD = false
    @State private var finished = false
    @State private var selectedType: BitcoinHDAddressType

    init(asset: WalletAsset, chain: BitcoinFamilyChain, fallbackAddress: String, database: WalletDatabase) {
        self.asset = asset
        self.chain = chain
        self.fallbackAddress = fallbackAddress
        self.database = database
        _selectedType = State(initialValue: chain.familyHDDefaultType)
    }

    var body: some View {
        Group {
            if let address, let network = ReceiveNetworkPresentation(asset: asset) {
                IndependentNetworkReceiveDetailsContent(asset: asset, address: address, network: network)
            } else if finished {
                ContentUnavailableView("receive.address.unavailable", systemImage: "qrcode",
                    description: Text("receive.address.unavailable.message"))
            } else { ProgressView() }
        }
        .toolbar {
            if isHD, chain.familyHDTypes.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("receive.bitcoin.address_type.label", selection: $selectedType) {
                            ForEach(chain.familyHDTypes, id: \.self) { type in
                                Text(LocalizedStringKey(type.localizationKey)).tag(type)
                            }
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel(Text("receive.bitcoin.address_type.label"))
                }
            }
        }
        .task(id: selectedType) { await resolve() }
    }

    @MainActor private func resolve() async {
        address = nil
        finished = false
        do {
            guard let identity = try await database.selectedWalletIdentity() else {
                finished = true
                return
            }
            isHD = try await database.ensureBitcoinFamilyHDWallet(walletID: identity.walletID, chain: chain)
            if isHD {
                let initial = try await database.freshBitcoinFamilyHDAddress(walletID: identity.walletID,
                    chain: chain, addressType: selectedType)
                guard !Task.isCancelled else { return }
                address = initial.address
                // Receiving stays available offline from persisted public keys.
                // A successful scan advances past addresses used in another wallet.
                if (try? await BitcoinFamilyHDDiscoveryService(database: database).discover(walletID: identity.walletID, chain: chain)) != nil {
                    let fresh = try await database.freshBitcoinFamilyHDAddress(walletID: identity.walletID,
                        chain: chain, addressType: selectedType)
                    guard !Task.isCancelled else { return }
                    address = fresh.address
                }
            } else {
                let candidate = asset.receiveAddress ?? fallbackAddress
                address = ReceiveAddressResolver.validatedIndependentAddress(candidate, for: chain.blockchain)
                if address == nil {
                    let stored = try await ReceiveAddressResolver.independentAddress(for: chain.blockchain, database: database)
                    guard !Task.isCancelled else { return }
                    address = ReceiveAddressResolver.validatedIndependentAddress(stored, for: chain.blockchain)
                }
            }
        } catch { }
        guard !Task.isCancelled else { return }
        finished = true
    }
}
