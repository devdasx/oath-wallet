import Foundation

extension OathImportChain {
    /// Mainnet explorers only, matching the network identities in the database.
    /// One route is shared by Open in Explorer and Share Link.
    func transactionExplorerURL(hash: String) -> URL? {
        guard !hash.isEmpty, hash.count <= 256,
              hash.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-=+/").contains($0) }) else { return nil }
        let route: String
        switch self {
        case .bitcoin: route = "https://mempool.space/tx/"
        case .bitcoincash: route = "https://blockchair.com/bitcoin-cash/transaction/"
        case .dogecoin: route = "https://blockchair.com/dogecoin/transaction/"
        case .litecoin: route = "https://blockchair.com/litecoin/transaction/"
        case .ethereum: route = "https://etherscan.io/tx/"
        case .arbitrum: route = "https://arbiscan.io/tx/"
        case .arc: route = "https://explorer.arc.io/tx/"
        case .avalanche: route = "https://snowscan.xyz/tx/"
        case .base: route = "https://basescan.org/tx/"
        case .bnb: route = "https://bscscan.com/tx/"
        case .fantom: route = "https://explorer.fantom.network/transactions/"
        case .flare: route = "https://flare-explorer.flare.network/tx/"
        case .gnosis: route = "https://gnosisscan.io/tx/"
        case .linea: route = "https://lineascan.build/tx/"
        case .optimism: route = "https://optimistic.etherscan.io/tx/"
        case .polygon: route = "https://polygonscan.com/tx/"
        case .monad: route = "https://monadscan.com/tx/"
        case .unichain: route = "https://uniscan.xyz/tx/"
        case .hyperevm: route = "https://hyperevmscan.io/tx/"
        case .robinhood: route = "https://robinhoodchain.blockscout.com/tx/"
        case .scroll: route = "https://scrollscan.com/tx/"
        case .somnia: route = "https://explorer.somnia.network/tx/"
        case .story: route = "https://www.datanetscan.io/tx/"
        case .taiko: route = "https://taikoscan.io/tx/"
        case .telos: route = "https://www.teloscan.io/tx/"
        case .xlayer: route = "https://www.oklink.com/xlayer/tx/"
        case .aptos: route = "https://explorer.aptoslabs.com/txn/"
        case .thorchain: route = "https://runescan.io/tx/"
        case .near: route = "https://nearblocks.io/txns/"
        case .solana: route = "https://solscan.io/tx/"
        case .stellar: route = "https://stellar.expert/explorer/public/tx/"
        case .sui: route = "https://suiscan.xyz/mainnet/tx/"
        case .ton: route = "https://tonviewer.com/transaction/"
        case .tron: route = "https://tronscan.org/#/transaction/"
        case .xrpl: route = "https://livenet.xrpl.org/transactions/"
        }
        // TON APIs may return a base64 hash. Use its hex representation so a
        // slash cannot become a second path component in the explorer URL.
        var identifier = hash
        if self == .ton, hash.count != 64 {
            var base64 = hash.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            guard let bytes = Data(base64Encoded: base64), bytes.count == 32 else { return nil }
            identifier = bytes.map { String(format: "%02x", $0) }.joined()
        }
        guard let component = identifier.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: route + component + (self == .aptos ? "?network=mainnet" : ""))
    }
}
