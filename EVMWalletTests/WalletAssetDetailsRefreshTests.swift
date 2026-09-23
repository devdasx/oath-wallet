import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import Aperture

struct WalletAssetDetailsRefreshTests {
    private let walletID = "asset-details-wallet"
    private let accountID = "asset-details-eth-account"
    private let owner = "0x1111111111111111111111111111111111111111"
    private let selectedContract =
        "0x2222222222222222222222222222222222222222"
    private let retainedContract =
        "0x3333333333333333333333333333333333333333"

    @Test
    @MainActor
    func assetDetailsInstallsNativePullToRefreshControl() async throws {
        let database = try WalletDatabase.temporary()
        let host = try NativeListTestHost {
            NavigationStack {
                WalletAssetDetailsView(
                    database: database,
                    asset: WalletAsset(
                        id: "unsupported:test",
                        name: "Test Asset",
                        symbol: "TST",
                        logoSource: .unavailable,
                        network: nil,
                        balance: 0,
                        fiatValue: 0
                    ),
                    transactions: [],
                    isBalanceHidden: false,
                    onSend: { _ in },
                    onReceive: {},
                    onScan: { _ in },
                    onPaste: { _, _ in }
                )
            }
        }
        defer { host.close() }

        let list = try await host.list()
        #expect(list.refreshControl != nil)
        #expect(list.refreshControl?.isEnabled == true)
    }

    @Test
    @MainActor
    func assetDetailsDoesNotRepeatHeroBalancesInHoldingsSection() async throws {
        let database = try WalletDatabase.temporary()
        let host = try NativeListTestHost {
            NavigationStack {
                WalletAssetDetailsView(
                    database: database,
                    asset: WalletAsset(
                        id: "unsupported:holdings-layout",
                        name: "Test Asset",
                        symbol: "TST",
                        logoSource: .unavailable,
                        network: nil,
                        balance: 2,
                        fiatValue: 10
                    ),
                    transactions: [],
                    isBalanceHidden: false,
                    onSend: { _ in },
                    onReceive: {},
                    onScan: { _ in },
                    onPaste: { _, _ in }
                )
            }
        }
        defer { host.close() }

        let list = try await host.list {
            $0.numberOfSections == 3
                && $0.numberOfItems(inSection: 1) == 1
        }

        #expect(list.numberOfItems(inSection: 0) == 1)
        #expect(list.numberOfItems(inSection: 1) == 1)
    }

    @Test(arguments: [
        NativeListTestLayout.phone,
        .phoneLandscape,
        .pad,
        .padLandscape
    ])
    @MainActor
    func assetDetailActionsStayInTheSharedHorizontalRow(
        layout: NativeListTestLayout
    ) async throws {
        let database = try WalletDatabase.temporary()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                WalletAssetDetailsView(
                    database: database,
                    asset: WalletAsset(
                        id: "unsupported:action-layout",
                        name: "Test Asset",
                        symbol: "TST",
                        logoSource: .unavailable,
                        network: nil,
                        balance: 0,
                        fiatValue: 0
                    ),
                    transactions: [],
                    isBalanceHidden: false,
                    onSend: { _ in },
                    onReceive: {},
                    onScan: { _ in },
                    onPaste: { _, _ in }
                )
            }
        }
        defer { host.close() }

        let list = try await host.list()
        let english = WalletAppLanguage.localizedBundle(for: "en")
        let sendTitle = english.localizedString(
            forKey: "wallet.home.action.send",
            value: nil,
            table: nil
        )
        let receiveTitle = english.localizedString(
            forKey: "wallet.home.action.receive",
            value: nil,
            table: nil
        )
        #expect(sendTitle == "Send")
        #expect(receiveTitle == "Receive")
        #expect(
            english.localizedString(
                forKey: "send.title",
                value: nil,
                table: nil
            ) == "Send"
        )
        #expect(
            english.localizedString(
                forKey: "receive.title",
                value: nil,
                table: nil
            ) == "Receive"
        )
        let send = try #require(host.accessibilityAction(
            label: sendTitle,
            in: host.rootView
        ))
        let receive = try #require(host.accessibilityAction(
            label: receiveTitle,
            in: host.rootView
        ))
        let more = try #require(host.accessibilityAction(
            label: english.localizedString(
                forKey: "wallet.home.action.more",
                value: nil,
                table: nil
            ),
            in: host.rootView
        ))

        let sendFrame = send.accessibilityFrame
        let receiveFrame = receive.accessibilityFrame
        let moreFrame = more.accessibilityFrame
        let headerCell = try #require(
            list.cellForItem(at: IndexPath(item: 0, section: 0))
        )
        // Native section margins differ before iOS 26. The action padding
        // belongs to the header row, not the screen's safe-area boundary.
        let rowFrame = UIAccessibility.convertToScreenCoordinates(
            headerCell.contentView.bounds,
            in: headerCell.contentView
        )

        #expect(sendFrame.width > 0)
        #expect(receiveFrame.width > 0)
        #expect(moreFrame.width > 0)
        #expect(abs(sendFrame.midY - receiveFrame.midY) <= 1)
        #expect(abs(receiveFrame.midY - moreFrame.midY) <= 1)
        #expect(sendFrame.maxX <= receiveFrame.minX)
        #expect(receiveFrame.maxX <= moreFrame.minX)
        #expect(abs(sendFrame.minX - rowFrame.minX - 20) <= 2)
        #expect(abs(rowFrame.maxX - moreFrame.maxX - 20) <= 2)
    }

    @Test
    func everySupportedBlockchainRoutesToItsProductionProviderFamily() {
        let expectations: [(WalletBlockchain, WalletSyncSource)] = [
            (.aptos, .aptos),
            (.stellar, .stellar),
            (.near, .near),
            (.xrp, .xrp),
            (.sui, .sui),
            (.ton, .ton),
            (.tron, .tron),
            (.solana, .solana),
            (.bitcoin, .bitcoinFamily),
            (.bitcoincash, .bitcoinFamily),
            (.litecoin, .bitcoinFamily),
            (.dogecoin, .bitcoinFamily),
            (.ethereum, .evm),
            (.smartchain, .evm),
            (.polygon, .evm),
            (.arbitrum, .evm),
            (.avalanchec, .evm),
            (.optimism, .evm),
            (.base, .evm),
            (.xdai, .evm),
            (.scroll, .evm),
            (.linea, .evm),
            (.taiko, .evm),
            (.telos, .evm),
            (.xlayer, .evm),
            (.arc, .evm)
        ]

        for (blockchain, expectedSource) in expectations {
            #expect(
                WalletAssetDetailsRefreshService.source(for: blockchain)
                    == expectedSource
            )
        }
        #expect(WalletAssetDetailsRefreshService.source(for: nil) == nil)
    }

    @Test
    func assetDetailHeadingsUseConciseEnglishCopy() {
        let english = WalletAppLanguage.localizedBundle(for: "en")
        #expect(
            english.localizedString(
                forKey: "wallet.asset.details.network",
                value: nil,
                table: nil
            ) == "Network"
        )
        #expect(
            english.localizedString(
                forKey: "wallet.home.activity.title",
                value: nil,
                table: nil
            ) == "Recent Activity"
        )
        let removedKey = "wallet.asset.details.holdings.section"
        #expect(
            english.localizedString(
                forKey: removedKey,
                value: nil,
                table: nil
            ) == removedKey
        )
    }

    @Test
    func transactionSelectionUsesNetworkAndContractNotTickerAlone() {
        let selected = tokenAsset(
            network: .ethereum,
            contract: selectedContract
        )
        let matching = tokenTransaction(
            id: "matching",
            network: .ethereum,
            contract: selectedContract,
            fiatValue: 1
        )
        let otherContract = tokenTransaction(
            id: "other-contract",
            network: .ethereum,
            contract: retainedContract,
            fiatValue: 1
        )
        let otherNetwork = tokenTransaction(
            id: "other-network",
            network: .smartchain,
            contract: selectedContract,
            fiatValue: 1
        )
        let unpriced = tokenTransaction(
            id: "unpriced",
            network: .ethereum,
            contract: selectedContract,
            fiatValue: nil
        )
        let belowThreshold = tokenTransaction(
            id: "below-threshold",
            network: .ethereum,
            contract: selectedContract,
            fiatValue: Decimal(string: "0.09")
        )

        #expect(
            WalletAssetDetailsSelection.matches(matching, asset: selected)
        )
        #expect(
            !WalletAssetDetailsSelection.matches(
                otherContract,
                asset: selected
            )
        )
        #expect(
            !WalletAssetDetailsSelection.matches(
                otherNetwork,
                asset: selected
            )
        )
        #expect(
            !WalletAssetDetailsSelection.matches(unpriced, asset: selected)
        )
        #expect(
            !WalletAssetDetailsSelection.matches(
                belowThreshold,
                asset: selected
            )
        )
    }

    @Test
    func nativeSelectionCannotConsumeTokenHistoryWithSameTicker() {
        let native = WalletAsset(
            id: "eth:0x0000000000000000000000000000000000000000",
            name: "Ether",
            symbol: "ETH",
            logoSource: .nativeCoin(blockchain: .ethereum),
            network: .ethereum,
            balance: 0,
            fiatValue: 0
        )
        let token = tokenTransaction(
            id: "token-named-eth",
            network: .ethereum,
            contract: selectedContract,
            symbol: "ETH",
            fiatValue: 1
        )
        let nativeTransaction = WalletTransaction(
            id: "native-eth",
            kind: .received(assetSymbol: "ETH"),
            detail: "",
            time: "",
            assetLogoSource: .nativeCoin(blockchain: .ethereum),
            assetAmount: 1,
            assetSymbol: "ETH",
            fiatValue: 1,
            status: .confirmed
        )

        #expect(
            !WalletAssetDetailsSelection.matches(token, asset: native)
        )
        #expect(
            WalletAssetDetailsSelection.matches(
                nativeTransaction,
                asset: native
            )
        )
    }

    @Test
    func selectedEVMMergePreservesEveryUnrelatedHolding() async throws {
        let database = try WalletDatabase.temporary()
        try await seedTwoHoldings(database)
        let selectedAsset = WalletAsset(
            id: AssetIdentityKey.make(
                networkID: "eth",
                contractAddress: selectedContract
            ),
            name: "Selected Token",
            symbol: "SEL",
            logoSource: .catalogToken(
                blockchain: .ethereum,
                contractAddress: selectedContract,
                logoURL: nil
            ),
            network: .ethereum,
            balance: 5,
            fiatValue: 10,
            balanceText: "5",
            balanceAtomic: "5000000",
            decimals: 6,
            receiveAddress: owner,
            isPinned: false
        )
        let snapshot = WalletHomeSnapshot(
            totalBalance: 10,
            assets: [selectedAsset],
            transactions: [],
            evmBalanceAuthority: EVMBalanceSnapshotAuthority(
                providerAssetCount: 1,
                mappedAssetCount: 1,
                unavailableFiatAssetCount: 0,
                hasMorePages: false,
                authoritativeNetworkIDs: ["eth"]
            )
        )

        try await database.saveEVMAssetDetailsSnapshot(
            snapshot,
            walletID: walletID
        )

        let holdings = try await database.pool.read { db in
            try DBAccountAssetRecord
                .filter(Column("accountID") == accountID)
                .fetchAll(db)
        }
        let byAsset = Dictionary(
            uniqueKeysWithValues: holdings.map { ($0.assetID, $0) }
        )
        let selectedID = AssetIdentityKey.make(
            networkID: "eth",
            contractAddress: selectedContract
        )
        let retainedID = AssetIdentityKey.make(
            networkID: "eth",
            contractAddress: retainedContract
        )
        let updated = try #require(byAsset[selectedID])
        let retained = try #require(byAsset[retainedID])

        #expect(updated.balance == "5")
        #expect(updated.balanceAtomic == "5000000")
        #expect(updated.fiatUSDValue == "10")
        #expect(updated.isPinned)
        #expect(updated.isHidden)
        #expect(updated.sortOrder == 7)
        #expect(retained.balance == "9")
        #expect(retained.balanceAtomic == "9000000")
        #expect(retained.fiatUSDValue == "27")
        #expect(!retained.isPinned)
        #expect(!retained.isHidden)
        #expect(retained.sortOrder == 8)
    }

    private func tokenAsset(
        network: WalletBlockchain,
        contract: String
    ) -> WalletAsset {
        WalletAsset(
            id: AssetIdentityKey.make(
                networkID: network == .smartchain ? "bsc" : "eth",
                contractAddress: contract
            ),
            name: "Selected Token",
            symbol: "SEL",
            logoSource: .catalogToken(
                blockchain: network,
                contractAddress: contract,
                logoURL: nil
            ),
            network: network,
            balance: 0,
            fiatValue: 0
        )
    }

    private func tokenTransaction(
        id: String,
        network: WalletBlockchain,
        contract: String,
        symbol: String = "SEL",
        fiatValue: Decimal?
    ) -> WalletTransaction {
        WalletTransaction(
            id: id,
            kind: .received(assetSymbol: symbol),
            detail: "",
            time: "",
            assetLogoSource: .catalogToken(
                blockchain: network,
                contractAddress: contract,
                logoURL: nil
            ),
            assetAmount: 1,
            assetSymbol: symbol,
            fiatValue: fiatValue,
            status: .confirmed
        )
    }

    private func seedTwoHoldings(
        _ database: WalletDatabase
    ) async throws {
        try await database.pool.write { db in
            let now = Date().timeIntervalSince1970
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Asset Details Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: "opaque-keychain-reference",
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil
            ).insert(db)
            try DBWalletAccountRecord(
                id: accountID,
                walletID: walletID,
                networkID: "eth",
                address: owner,
                normalizedAddress: owner.lowercased(),
                label: nil,
                derivationPath: nil,
                accountIndex: 0,
                publicKey: nil,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(db)
            try seedHolding(
                db,
                contract: selectedContract,
                symbol: "SEL",
                balance: "1",
                atomic: "1000000",
                fiat: "2",
                isPinned: true,
                isHidden: true,
                sortOrder: 7,
                now: now
            )
            try seedHolding(
                db,
                contract: retainedContract,
                symbol: "RET",
                balance: "9",
                atomic: "9000000",
                fiat: "27",
                isPinned: false,
                isHidden: false,
                sortOrder: 8,
                now: now
            )
        }
    }

    private func seedHolding(
        _ db: Database,
        contract: String,
        symbol: String,
        balance: String,
        atomic: String,
        fiat: String,
        isPinned: Bool,
        isHidden: Bool,
        sortOrder: Int,
        now: Double
    ) throws {
        let assetID = AssetIdentityKey.make(
            networkID: "eth",
            contractAddress: contract
        )
        try DBAssetRecord(
            id: assetID,
            networkID: "eth",
            assetType: DatabaseAssetType.fungibleToken.rawValue,
            contractAddress: contract,
            normalizedContractAddress: contract.lowercased(),
            name: "\(symbol) Token",
            symbol: symbol,
            decimals: 6,
            trustWalletBlockchain: "eth",
            trustWalletContractAddress: contract,
            isVerified: true,
            isSpam: false,
            createdAt: now,
            updatedAt: now,
            metadataUpdatedAt: nil
        ).insert(db)
        try DBAccountAssetRecord(
            accountID: accountID,
            assetID: assetID,
            balance: balance,
            balanceAtomic: atomic,
            fiatUSDValue: fiat,
            isEnabled: true,
            isPinned: isPinned,
            isHidden: isHidden,
            sortOrder: sortOrder,
            firstSeenAt: now,
            lastSeenAt: now,
            updatedAt: now
        ).insert(db)
    }
}
