import Foundation

enum PrivateKeyImportNetwork: String, CaseIterable, Hashable, Sendable {
    case aptos
    case stellar
    case evm
    case bitcoin
    case litecoin
    case dogecoin
    case bitcoinCash = "bitcoin_cash"
    case tron
    case solana
    case ton
    case sui
    case xrp
    case near

    var requirementKey: String {
        switch self {
        case .aptos:
            "import.private_key.requirement.aptos"
        case .stellar:
            "import.private_key.requirement.stellar"
        case .evm:
            "import.private_key.requirement.evm"
        case .bitcoin:
            "import.private_key.requirement.bitcoin"
        case .litecoin:
            "import.private_key.requirement.litecoin"
        case .dogecoin:
            "import.private_key.requirement.dogecoin"
        case .bitcoinCash:
            "import.private_key.requirement.bitcoin_cash"
        case .tron:
            "import.private_key.requirement.tron"
        case .solana:
            "import.private_key.requirement.solana"
        case .ton:
            "import.private_key.requirement.ton"
        case .sui:
            "import.private_key.requirement.sui"
        case .xrp:
            "import.private_key.requirement.xrp"
        case .near:
            "import.private_key.requirement.near"
        }
    }

    var titleKey: String {
        switch self {
        case .aptos:
            "network.aptos.name"
        case .stellar:
            "network.stellar.name"
        case .evm:
            "import.private_key.network.evm"
        case .bitcoin:
            "network.bitcoin.name"
        case .litecoin:
            "network.litecoin.name"
        case .dogecoin:
            "network.dogecoin.name"
        case .bitcoinCash:
            "network.bitcoin_cash.name"
        case .tron:
            "network.tron.name"
        case .solana:
            "network.solana.name"
        case .ton:
            "network.ton.name"
        case .sui:
            "network.sui.name"
        case .xrp:
            "network.xrp.name"
        case .near:
            "network.near.name"
        }
    }

    var localizedTitle: String {
        WalletLocalization.string(titleKey)
    }

    var walletNameTitleKey: String {
        switch self {
        case .evm:
            "network.ethereum"
        default:
            titleKey
        }
    }

    var localizedWalletNameTitle: String {
        WalletLocalization.string(walletNameTitleKey)
    }

    var blockchain: WalletBlockchain {
        switch self {
        case .aptos:
            .aptos
        case .stellar:
            .stellar
        case .evm:
            .ethereum
        case .bitcoin:
            .bitcoin
        case .litecoin:
            .litecoin
        case .dogecoin:
            .dogecoin
        case .bitcoinCash:
            .bitcoincash
        case .tron:
            .tron
        case .solana:
            .solana
        case .ton:
            .ton
        case .sui:
            .sui
        case .xrp:
            .xrp
        case .near:
            .near
        }
    }

    var networkID: String {
        switch self {
        case .aptos:
            AptosConstants.networkID
        case .stellar:
            StellarConstants.networkID
        case .evm:
            "eth"
        case .bitcoin:
            BitcoinFamilyChain.bitcoin.networkID
        case .litecoin:
            BitcoinFamilyChain.litecoin.networkID
        case .dogecoin:
            BitcoinFamilyChain.dogecoin.networkID
        case .bitcoinCash:
            BitcoinFamilyChain.bitcoinCash.networkID
        case .tron:
            TronConstants.networkID
        case .solana:
            SolanaConstants.networkID
        case .ton:
            TONConstants.networkID
        case .sui:
            SuiConstants.networkID
        case .xrp:
            XRPConstants.networkID
        case .near:
            NEARConstants.networkID
        }
    }

    var bitcoinFamilyChain: BitcoinFamilyChain? {
        switch self {
        case .bitcoin:
            .bitcoin
        case .litecoin:
            .litecoin
        case .dogecoin:
            .dogecoin
        case .bitcoinCash:
            .bitcoinCash
        case .aptos, .stellar, .evm, .tron, .solana, .ton, .sui, .xrp, .near:
            nil
        }
    }

    var supportsMultipleNetworks: Bool {
        self == .evm
    }

    var supportsMultipleAssets: Bool {
        switch self {
        case .aptos, .stellar, .evm, .tron, .solana, .ton, .sui, .xrp, .near:
            true
        case .bitcoin, .litecoin, .dogecoin, .bitcoinCash:
            false
        }
    }
}

enum PrivateKeyImportFormat: String, Hashable, Sendable {
    case rawSecp256k1
    case wifCompressed
    case wifUncompressed
    case extendedLegacy
    case extendedNestedSegwit
    case extendedNativeSegwit
    case solanaSeed
    case solanaKeypair
    case rawEd25519

    var accountMarker: String {
        "private-key:\(rawValue)"
    }

    init?(accountMarker: String?) {
        guard let accountMarker,
              accountMarker.hasPrefix("private-key:")
        else {
            return nil
        }
        self.init(
            rawValue: String(
                accountMarker.dropFirst("private-key:".count)
            )
        )
    }
}

struct WalletCapabilities: Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        case fullWallet
        case privateKey(PrivateKeyImportNetwork)
    }

    let scope: Scope

    static let fullWallet = WalletCapabilities(scope: .fullWallet)

    var privateKeyNetwork: PrivateKeyImportNetwork? {
        guard case let .privateKey(network) = scope else {
            return nil
        }
        return network
    }

    var showsNetworkSelector: Bool {
        switch scope {
        case .fullWallet:
            true
        case let .privateKey(network):
            network.supportsMultipleNetworks
        }
    }

    var showsAssetManagement: Bool {
        switch scope {
        case .fullWallet:
            true
        case let .privateKey(network):
            network.supportsMultipleAssets
        }
    }

    var usesEVMWalletAddress: Bool {
        switch scope {
        case .fullWallet, .privateKey(.evm):
            true
        case .privateKey:
            false
        }
    }

    var allowedNetworkIDs: Set<String>? {
        switch scope {
        case .fullWallet:
            nil
        case .privateKey(.evm):
            Set(
                ReceiveNetworkCatalog.all
                    .filter { $0.blockchain.isEVM }
                    .map(\.id)
            )
        case let .privateKey(network):
            [network.networkID]
        }
    }

    func permits(networkID: String) -> Bool {
        // A family chip is permitted exactly when its network is.
        let networkID = AssetFamily.selectorFamily(for: networkID)?.networkID
            ?? networkID
        return allowedNetworkIDs?.contains(networkID) ?? true
    }

    func permits(blockchain: WalletBlockchain?) -> Bool {
        guard let blockchain else { return false }
        guard let allowedNetworkIDs else { return true }
        return AssetNetworkSelectorOption.networkID(
            for: blockchain
        ).map(allowedNetworkIDs.contains) ?? false
    }

    func filteredAssets(_ assets: [WalletAsset]) -> [WalletAsset] {
        guard allowedNetworkIDs != nil else { return assets }
        return assets.filter { permits(blockchain: $0.network) }
    }

    func filteredTransactions(
        _ transactions: [WalletTransaction]
    ) -> [WalletTransaction] {
        guard let allowedNetworkIDs else { return transactions }
        return transactions.filter { transaction in
            guard
                let networkID =
                    transaction.metadata.blockchainIdentifier
            else {
                return false
            }
            return allowedNetworkIDs.contains(networkID)
        }
    }

    func scopedSnapshot(
        _ snapshot: WalletHomeSnapshot
    ) -> WalletHomeSnapshot {
        guard allowedNetworkIDs != nil else { return snapshot }
        let assets = filteredAssets(snapshot.assets)
        return WalletHomeSnapshot(
            totalBalance: assets.reduce(Decimal.zero) {
                $0 + (
                    $1.isSpam || $1.requiresExplicitVisibility
                        ? 0 : $1.fiatValue
                )
            },
            assets: assets,
            transactions: filteredTransactions(snapshot.transactions),
            hasStoredActivity: snapshot.hasStoredActivity
        )
    }

    var selectorOptions: [AssetNetworkSelectorOption] {
        AssetNetworkSelectorOption.allSelectable.filter {
            permits(networkID: $0.id)
        }
    }

    var permitsBitcoinFamily: Bool {
        switch scope {
        case .fullWallet:
            true
        case .privateKey(.bitcoin),
             .privateKey(.bitcoinCash),
             .privateKey(.litecoin),
             .privateKey(.dogecoin):
            true
        case .privateKey(.evm),
             .privateKey(.aptos),
             .privateKey(.tron),
             .privateKey(.solana),
             .privateKey(.ton),
             .privateKey(.sui),
             .privateKey(.xrp),
             .privateKey(.near):
            false
        case .privateKey(.stellar):
            false
        }
    }

}
