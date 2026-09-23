import Foundation

enum WalletTransactionExplorer {
    static func url(
        transactionHash: String?,
        networkID: String?
    ) -> URL? {
        guard
            let hash = normalizedHash(transactionHash),
            let canonicalNetworkID =
                WalletNetworkSelectionOrdering.canonicalNetworkID(networkID),
            let blockchain = AssetNetworkSelectorOption.blockchain(
                for: canonicalNetworkID
            )
        else {
            return nil
        }

        switch blockchain {
        case .aptos:
            return transactionURL(
                prefix: "https://explorer.aptoslabs.com/txn/",
                hash: hash,
                queryItems: [URLQueryItem(name: "network", value: "mainnet")]
            )
        case .stellar:
            return transactionURL(
                prefix: "https://stellar.expert/explorer/public/tx/",
                hash: hash
            )
        case .near:
            return transactionURL(
                prefix: "https://nearblocks.io/txns/",
                hash: hash
            )
        case .xrp:
            return transactionURL(
                prefix: "https://livenet.xrpl.org/transactions/",
                hash: hash
            )
        case .sui:
            return transactionURL(
                prefix: "https://suiscan.xyz/mainnet/tx/",
                hash: hash
            )
        case .ton:
            return transactionURL(
                prefix: "https://tonviewer.com/transaction/",
                hash: hash
            )
        case .tron:
            return transactionURL(
                prefix: "https://tronscan.org/#/transaction/",
                hash: hash
            )
        case .solana:
            return transactionURL(
                prefix: "https://explorer.solana.com/tx/",
                hash: hash
            )
        case .bitcoin:
            return transactionURL(
                prefix: "https://mempool.space/tx/",
                hash: hash
            )
        case .bitcoincash:
            return transactionURL(
                prefix: "https://blockchair.com/bitcoin-cash/transaction/",
                hash: hash
            )
        case .litecoin:
            return transactionURL(
                prefix: "https://litecoinspace.org/tx/",
                hash: hash
            )
        case .dogecoin:
            return transactionURL(
                prefix: "https://dogechain.info/tx/",
                hash: hash
            )
        case .ethereum:
            return transactionURL(
                prefix: "https://etherscan.io/tx/",
                hash: hash
            )
        case .smartchain:
            return transactionURL(
                prefix: "https://bscscan.com/tx/",
                hash: hash
            )
        case .polygon:
            return transactionURL(
                prefix: "https://polygonscan.com/tx/",
                hash: hash
            )
        case .arbitrum:
            return transactionURL(
                prefix: "https://arbiscan.io/tx/",
                hash: hash
            )
        case .avalanchec:
            return transactionURL(
                prefix: "https://snowtrace.io/tx/",
                hash: hash,
                queryItems: [URLQueryItem(name: "chainid", value: "43114")]
            )
        case .optimism:
            return transactionURL(
                prefix: "https://optimistic.etherscan.io/tx/",
                hash: hash
            )
        case .base:
            return transactionURL(
                prefix: "https://basescan.org/tx/",
                hash: hash
            )
        case .xdai:
            return transactionURL(
                prefix: "https://gnosisscan.io/tx/",
                hash: hash
            )
        case .scroll:
            return transactionURL(
                prefix: "https://scrollscan.com/tx/",
                hash: hash
            )
        case .linea:
            return transactionURL(
                prefix: "https://lineascan.build/tx/",
                hash: hash
            )
        case .taiko:
            return transactionURL(
                prefix: "https://taikoscan.io/tx/",
                hash: hash
            )
        case .telos:
            return transactionURL(
                prefix: "https://www.teloscan.io/tx/",
                hash: hash
            )
        case .arc:
            return transactionURL(
                prefix: "https://explorer.arc.io/tx/",
                hash: hash
            )
        case .xlayer:
            return transactionURL(
                prefix: "https://www.oklink.com/xlayer/tx/",
                hash: hash
            )
        }
    }

    static func copyPayload(
        transactionHash: String?,
        networkID: String?
    ) -> String? {
        guard
            let hash = normalizedHash(transactionHash),
            let url = url(
                transactionHash: hash,
                networkID: networkID
            )
        else {
            return nil
        }
        return "\(hash)\n\(url.absoluteString)"
    }

    private static func normalizedHash(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty,
              normalized.utf8.count <= 512,
              normalized.utf8.allSatisfy(isPermittedHashByte) else {
            return nil
        }
        return normalized
    }

    private static func isPermittedHashByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
            || (65...90).contains(byte)
            || (97...122).contains(byte)
            || byte == 43
            || byte == 45
            || byte == 46
            || byte == 47
            || byte == 61
            || byte == 95
            || byte == 126
    }

    private static func transactionURL(
        prefix: String,
        hash: String,
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        var pathComponentCharacters = CharacterSet.alphanumerics
        pathComponentCharacters.insert(charactersIn: "-._~")
        guard let encodedHash = hash.addingPercentEncoding(
            withAllowedCharacters: pathComponentCharacters
        ),
              let baseURL = URL(string: prefix + encodedHash),
              baseURL.scheme == "https",
              baseURL.host?.isEmpty == false else {
            return nil
        }
        guard !queryItems.isEmpty else { return baseURL }
        var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems
        return components?.url
    }
}
