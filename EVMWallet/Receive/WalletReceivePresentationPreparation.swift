import Foundation

struct WalletReceivePresentationToken: Equatable, Sendable {
    fileprivate let generation: UInt64
}

struct WalletReceivePresentationGate: Equatable, Sendable {
    private var generation: UInt64 = 0

    mutating func begin() -> WalletReceivePresentationToken {
        generation &+= 1
        return WalletReceivePresentationToken(generation: generation)
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func isCurrent(_ token: WalletReceivePresentationToken) -> Bool {
        token.generation == generation
    }

    func canPresent(
        for token: WalletReceivePresentationToken,
        isSceneActive: Bool,
        isWalletAccessRestricted: Bool,
        isTaskCancelled: Bool
    ) -> Bool {
        isCurrent(token)
            && isSceneActive
            && !isWalletAccessRestricted
            && !isTaskCancelled
    }
}

enum WalletReceivePresentationPreparation {
    @MainActor
    static func bitcoinFamilyAsset(
        database: WalletDatabase,
        chain: BitcoinFamilyChain
    ) async -> WalletAsset? {
        guard
            let identity = try? await database.selectedWalletIdentity(),
            let index = try? await database.accountAddressIndex(
                walletID: identity.walletID
            ),
            let address = index.address(for: chain.blockchain)
        else {
            return nil
        }

        return WalletAsset(
            id: "\(chain.networkID):native",
            name: chain.name,
            symbol: chain.symbol,
            logoSource: .nativeCoin(
                blockchain: chain.blockchain
            ),
            network: chain.blockchain,
            balance: 0,
            fiatValue: 0,
            balanceText: "0",
            balanceAtomic: "0",
            decimals: 8,
            receiveAddress: address
        )
    }
}
