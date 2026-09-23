import Foundation

enum WalletHomeHoldingProjection {
    static func unifiedHoldings(
        _ holdings: [DBAccountAssetRecord],
        accountByID: [String: DBWalletAccountRecord]
    ) -> [DBAccountAssetRecord] {
        let grouped = Dictionary(grouping: holdings, by: \.assetID)
        return grouped.keys.sorted().flatMap { assetID in
            let candidates = grouped[assetID, default: []].sorted {
                $0.accountID < $1.accountID
            }
            let solanaCandidates = candidates.filter {
                accountByID[$0.accountID]?.networkID
                    == SolanaConstants.networkID
            }
            guard !solanaCandidates.isEmpty else {
                return candidates
            }

            // Only the primary derivation account is spendable by Send.
            // Alternative Solana holding rows intentionally remain persisted
            // with zero values for account/history continuity, but they must
            // never escape as separate assets with the same unified ID.
            let primary = solanaCandidates.first(where: {
                isPrimarySolanaAccount(
                    accountByID[$0.accountID],
                    accountID: $0.accountID
                )
            }) ?? solanaCandidates[0]
            return [primary]
        }
    }

    private static func isPrimarySolanaAccount(
        _ account: DBWalletAccountRecord?,
        accountID: String
    ) -> Bool {
        guard let account else { return false }
        return account.label == SolanaDerivationKind.phantom.rawValue
            || account.derivationPath
                == SolanaDerivationKind.phantom.derivationPath
            || accountID.contains(
                ":\(SolanaConstants.networkID):"
                    + "\(SolanaDerivationKind.phantom.rawValue):"
            )
    }
}
