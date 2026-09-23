import Foundation
import SwiftUI

struct ReceiveNetworkPresentation: Hashable, Sendable {
    let blockchain: WalletBlockchain
    let nameKey: String

    init?(asset: WalletAsset) {
        self.init(blockchain: asset.network)
    }

    init?(blockchain: WalletBlockchain?) {
        guard let blockchain else { return nil }

        if let network = ReceiveNetworkCatalog.network(
            for: blockchain
        ) {
            self.blockchain = blockchain
            nameKey = network.nameKey
            return
        }

        guard let chain = BitcoinFamilyChain.allCases.first(where: {
            $0.blockchain == blockchain
        }) else {
            return nil
        }
        self.blockchain = blockchain
        nameKey = chain.nameKey
    }

    var localizedName: String {
        WalletLocalization.string(nameKey)
    }

    var logoSource: AssetLogoSource {
        .network(blockchain: blockchain)
    }
}

enum ReceiveNetworkLabelText {
    static func localized(
        networkName: String,
        blockchain: WalletBlockchain?
    ) -> String {
        if blockchain == .ton {
            return WalletLocalization.string(
                "receive.details.network.badge.ton"
            )
        }
        return EnglishNumbers.localized(
            "receive.details.network.badge",
            networkName
        )
    }
}

struct ReceiveNetworkLabel: View {
    let networkName: String
    let logoSource: AssetLogoSource
    var logoSize: CGFloat = 20
    var spacing: CGFloat = 8
    var animatesLogoChanges = true

    var body: some View {
        HStack(spacing: spacing) {
            Text(verbatim: text.leading)

            AssetLogoView(
                source: logoSource,
                size: logoSize,
                animatesChanges: animatesLogoChanges
            )
            .accessibilityHidden(true)

            Text(verbatim: text.trailing)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.accessibilityLabel)
    }

    private var text: (
        leading: String,
        trailing: String,
        accessibilityLabel: String
    ) {
        let logoMarker = "{logo}"
        let localizedText = ReceiveNetworkLabelText.localized(
            networkName: networkName,
            blockchain: logoSource.blockchain
        )
        let components = localizedText.components(
            separatedBy: logoMarker
        )

        guard components.count == 2 else {
            return (
                leading: "",
                trailing: localizedText,
                accessibilityLabel: localizedText
            )
        }

        return (
            leading: components[0].trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            trailing: components[1].trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            accessibilityLabel: localizedText.replacingOccurrences(
                of: logoMarker,
                with: ""
            )
        )
    }
}
