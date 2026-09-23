import Foundation

/// A curated group of tokens the app presents as its own section next to the
/// networks — its own chip in the asset pickers and its own badge beside the
/// network badge on every row — while the tokens keep living on their real
/// chain. Membership comes from the remote asset catalog (`asset_family`), so
/// a family grows without an app update.
enum AssetFamily: String, CaseIterable, Codable, Hashable, Sendable {
    /// Binance's tokenized US equities and ETFs: BEP-20 tokens on BNB Smart
    /// Chain issued by BTECH Holdings, one token per share.
    case bStocks = "bstocks"

    /// Selector identifiers share the network chips' namespace, so a family
    /// chip carries a prefix no network identifier uses.
    static let selectorIDPrefix = "family:"

    /// The chain every member of the family lives on.
    var blockchain: WalletBlockchain {
        switch self {
        case .bStocks: .smartchain
        }
    }

    var networkID: String {
        switch self {
        case .bStocks: "bsc"
        }
    }

    var localizedName: String {
        switch self {
        case .bStocks: WalletLocalization.string("asset.family.bstocks")
        }
    }

    var logoAssetName: String {
        switch self {
        case .bStocks: "AssetFamilyLogoBStocks"
        }
    }

    var selectorID: String {
        Self.selectorIDPrefix + rawValue
    }

    var logoSource: AssetLogoSource {
        .family(self)
    }

    /// The family a selector identifier stands for, or nil for a network.
    static func selectorFamily(for selectorID: String?) -> AssetFamily? {
        guard let selectorID, selectorID.hasPrefix(selectorIDPrefix) else {
            return nil
        }
        return AssetFamily(
            rawValue: String(selectorID.dropFirst(selectorIDPrefix.count))
        )
    }

    /// True when `identifier` is a family selector rather than a network.
    static func isSelectorID(_ identifier: String?) -> Bool {
        identifier?.hasPrefix(selectorIDPrefix) == true
    }
}
