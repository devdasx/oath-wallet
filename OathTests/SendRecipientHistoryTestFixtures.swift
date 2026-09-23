import Foundation
import GRDB
import Testing
@testable import Aperture

enum SendRecipientHistoryTestFixtures {
    static let walletID = "recipient-history-wallet"
    static let recipient = "0x8ba1f109551bD432803012645Ac136ddd64DBA72"
    static let anotherRecipient = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"

    static func asset(networkID: String) throws -> SendAssetChoice {
        try SendEntryTestFixtures.nativeChoice(for: #require(
            AssetNetworkSelectorOption.allSupported.first { $0.id == networkID }
        ))
    }

    static func seed(
        _ database: WalletDatabase,
        asset: SendAssetChoice = SendEntryTestFixtures.ethereum,
        walletID: String = walletID,
        selected: Bool = true
    ) async throws -> SendRecipientHistoryScope {
        try await database.pool.write { db in
            if try DBWalletRecord.fetchOne(db, key: walletID) == nil {
                try DBWalletRecord(
                    id: walletID, profileID: WalletDatabase.defaultProfileID,
                    name: "Recipient history fixture", kind: DatabaseWalletKind.created.rawValue,
                    secretKeyReference: nil, isSelected: selected, sortOrder: 0,
                    createdAt: 1, updatedAt: 1, lastOpenedAt: nil, archivedAt: nil
                ).insert(db)
            }
            let assetID = AssetIdentityKey.make(networkID: asset.networkID, contractAddress: asset.contractAddress)
            if try DBAssetRecord.fetchOne(db, key: assetID) == nil {
                try DBAssetRecord(
                    id: assetID, networkID: asset.networkID,
                    assetType: asset.contractAddress == nil
                        ? DatabaseAssetType.native.rawValue : DatabaseAssetType.fungibleToken.rawValue,
                    contractAddress: asset.contractAddress ?? "",
                    normalizedContractAddress: asset.contractAddress?.lowercased() ?? "",
                    name: asset.name, symbol: asset.symbol, decimals: asset.decimals,
                    trustWalletBlockchain: asset.blockchain.rawValue, trustWalletContractAddress: nil,
                    isVerified: true, isSpam: false, createdAt: 1, updatedAt: 1, metadataUpdatedAt: nil
                ).insert(db)
            }
            try DBWalletAccountRecord(
                id: accountID(walletID: walletID, networkID: asset.networkID),
                walletID: walletID, networkID: asset.networkID,
                address: asset.sourceAddress ?? SendEntryTestFixtures.address(for: asset.blockchain),
                normalizedAddress: asset.sourceAddress ?? SendEntryTestFixtures.address(for: asset.blockchain),
                label: nil, derivationPath: nil, accountIndex: 0, publicKey: nil,
                isWatchOnly: false, isEnabled: true, createdAt: 1, updatedAt: 1, lastSyncedAt: 1
            ).save(db)
        }
        return SendRecipientHistoryScope(walletID: walletID, networkID: asset.networkID)
    }

    static func accountID(walletID: String = walletID, networkID: String = "eth") -> String {
        "\(walletID):\(networkID):0"
    }

    static func receipt(
        asset: SendAssetChoice = SendEntryTestFixtures.ethereum,
        walletID: String = walletID,
        accountID: String? = nil,
        hash: String = UUID().uuidString,
        address: String? = nil,
        amount: String = "1",
        amountAtomic: String? = nil,
        date: Double = 100
    ) -> SendTransactionReceipt {
        SendTransactionReceipt(
            transactionHash: hash,
            accountID: accountID ?? Self.accountID(walletID: walletID, networkID: asset.networkID),
            networkID: asset.networkID,
            fromAddress: asset.sourceAddress ?? SendEntryTestFixtures.address(for: asset.blockchain),
            toAddress: address ?? (asset.networkID == "eth" ? recipient : SendEntryTestFixtures.address(for: asset.blockchain)),
            assetID: AssetIdentityKey.make(networkID: asset.networkID, contractAddress: asset.contractAddress),
            assetSymbol: asset.symbol, amount: amount,
            amountAtomic: amountAtomic ?? "1" + String(repeating: "0", count: asset.decimals),
            networkFee: nil, networkFeeAtomic: nil, networkFeeSymbol: asset.symbol,
            submittedAt: Date(timeIntervalSince1970: date)
        )
    }

    /// Exercises the actual accepted/unknown/failed receipt persistence, not a
    /// direct test insert into the recipient registry. Never broadcasts funds.
    @discardableResult
    static func broadcast(
        in database: WalletDatabase,
        asset: SendAssetChoice = SendEntryTestFixtures.ethereum,
        walletID: String = walletID,
        accountID: String? = nil,
        hash: String = UUID().uuidString,
        address: String? = nil,
        memo: String? = nil,
        date: Double = 100,
        outcome: SendRecordedBroadcastOutcome = .accepted
    ) async throws -> String {
        let receipt = receipt(
            asset: asset, walletID: walletID, accountID: accountID,
            hash: hash, address: address, date: date
        )
        return try await database.recordSubmittedSend(
            receipt: receipt,
            draft: SendEntryTestFixtures.draft(
                asset: asset, recipient: receipt.toAddress, amount: receipt.amount, memo: memo
            ),
            outcome: outcome
        )
    }

    static func recent(
        address: String, networkID: String = "eth", memo: String? = nil, memoRecorded: Bool = true
    ) throws -> SendRecentRecipient {
        SendRecentRecipient(
            id: try #require(SendRecipientIdentity(
                address: address, networkID: networkID, memo: memo, memoRecorded: memoRecorded
            )),
            address: address, sendCount: 1, lastSentAt: Date(timeIntervalSince1970: 100)
        )
    }

    static func transaction(
        id: String = UUID().uuidString,
        hash: String = UUID().uuidString,
        scope: SendRecipientHistoryScope = .init(walletID: walletID, networkID: "eth"),
        accountID: String? = nil,
        address: String? = recipient,
        counterparty: String? = nil,
        kind: String = "sent",
        direction: String = "outgoing",
        status: String = "confirmed",
        amount: String = "1",
        assetID: String? = nil,
        usdValue: String? = nil,
        date: Double = 100,
        updatedAt: Double = 100
    ) -> DBTransactionRecord {
        DBTransactionRecord(
            id: id, accountID: accountID ?? Self.accountID(walletID: scope.walletID, networkID: scope.networkID),
            networkID: scope.networkID, transactionHash: hash, normalizedTransactionHash: hash.lowercased(),
            kind: kind, status: status, direction: direction,
            fromAddress: SendEntryTestFixtures.address(for: .ethereum),
            toAddress: address, counterpartyAddress: counterparty,
            blockNumber: nil, blockHash: nil, transactionIndex: nil, nonce: nil, transactionType: nil,
            timestamp: date, assetID: assetID ?? AssetIdentityKey.make(networkID: scope.networkID, contractAddress: nil),
            assetSymbol: "FIXTURE", secondaryAssetSymbol: nil, assetAmount: amount, fiatUSDValue: usdValue,
            networkFee: nil, networkFeeFiatUSDValue: nil, networkFeeSymbol: nil,
            gasPriceGwei: nil, gasLimit: nil, gasUsed: nil, inputData: nil, methodName: nil,
            displayDetail: "", displayTime: "", firstSeenAt: date, updatedAt: updatedAt
        )
    }

    static func save(_ records: [DBTransactionRecord], in database: WalletDatabase) async throws {
        try await database.pool.write { db in
            for record in records { try record.save(db) }
        }
    }
}
