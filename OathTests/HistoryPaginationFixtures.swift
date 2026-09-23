import Foundation
import GRDB
import Testing
@testable import Aperture

extension HistoryPaginationTests {
    func makeAnkrTransaction(
        index: Int,
        senderAddress: String,
        walletAddress: String
    ) -> AnkrRawTransaction {
        let blockNumber = String(format: "0x%x", index + 1)
        let transactionHash = String(
            format: "0x%064llx",
            UInt64(index + 1)
        )
        let timestamp = String(
            format: "0x%llx",
            UInt64(1_700_000_000 + index)
        )
        return AnkrRawTransaction(
            blockHash: nil,
            blockNumber: blockNumber,
            from: senderAddress,
            gas: nil,
            gasPrice: nil,
            gasUsed: nil,
            to: walletAddress,
            value: "0xde0b6b3a7640000",
            hash: transactionHash,
            input: "0x",
            nonce: nil,
            status: "0x1",
            blockchain: "eth",
            timestamp: timestamp,
            transactionIndex: nil,
            type: nil
        )
    }

    func makeAnkrTokenSnapshot(
        rawInteger: String?,
        normalizedValue: String?,
        walletAddress: String =
            "0x1111111111111111111111111111111111111111"
    ) -> WalletHomeSnapshot {
        let contractAddress =
            "0x3333333333333333333333333333333333333333"
        let asset = AnkrBalanceAsset(
            blockchain: "eth",
            tokenName: "Raw Token",
            tokenSymbol: "RAW",
            tokenDecimals: 18,
            tokenType: "ERC20",
            contractAddress: contractAddress,
            balance: "1",
            balanceRawInteger: "1000000000000000000",
            balanceUsd: "1",
            tokenPrice: "1",
            thumbnail: ""
        )
        let transfer = AnkrTokenTransfer(
            blockHeight: 100,
            fromAddress:
                "0x2222222222222222222222222222222222222222",
            toAddress: walletAddress,
            contractAddress: contractAddress,
            value: normalizedValue,
            valueRawInteger: rawInteger,
            blockchain: "eth",
            tokenName: "Raw Token",
            tokenSymbol: "RAW",
            tokenDecimals: 18,
            thumbnail: nil,
            transactionHash:
                "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            logIndex: 0,
            timestamp: 1_700_000_000,
            direction: "in"
        )
        return try! AnkrAPIClient.makeSnapshot(
            address: walletAddress,
            balanceResult: AnkrBalanceResult(
                totalBalanceUsd: "1",
                assets: [asset],
                nextPageToken: nil
            ),
            transfers: [transfer],
            rawTransactions: [],
            historicalTokenPrices: [asset.blockchain + ":" + asset.contractAddress.lowercased(): 1]
        )
    }

    func seedAnkrWallet(
        address: String,
        database: WalletDatabase
    ) async throws {
        try await database.pool.write { database in
            let now = Date().timeIntervalSince1970
            try DBWalletRecord(
                id: "ankr-precision-wallet",
                profileID: WalletDatabase.defaultProfileID,
                name: "ANKR Precision Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: nil,
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil
            ).insert(database)
            try DBWalletAccountRecord(
                id: "ankr-precision-account",
                walletID: "ankr-precision-wallet",
                networkID: "eth",
                address: address,
                normalizedAddress: address.lowercased(),
                label: nil,
                derivationPath: "m/44'/60'/0'/0/0",
                accountIndex: 0,
                publicKey: nil,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(database)
        }
    }

    func seedTronVisibilityHistory(
        database: WalletDatabase
    ) async throws -> (
        walletID: String,
        address: String,
        thresholdTokenID: String,
        nativeTransactionIDs: [String]
    ) {
        let walletID = "tron-visible-history-wallet"
        let accountID = "\(walletID):tron:0"
        let address = "tqn9y2khesljw1chvwfmsmerdow5kcblse"
        let spamAssetID = "tron:spam-token"
        let thresholdAssetID = "tron:threshold-token"
        let thresholdTokenID = "legitimate-threshold-token"
        let nativeTransactionIDs = (0..<105).map {
            "legitimate-native-\($0)"
        }

        try await database.pool.write { database in
            let createdAt = 1_700_000_000.0
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Tron Visibility Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: nil,
                isSelected: false,
                sortOrder: 0,
                createdAt: createdAt,
                updatedAt: createdAt,
                lastOpenedAt: nil,
                archivedAt: nil
            ).insert(database)
            try DBWalletAccountRecord(
                id: accountID,
                walletID: walletID,
                networkID: TronConstants.networkID,
                address: address,
                normalizedAddress: address,
                label: nil,
                derivationPath: nil,
                accountIndex: 0,
                publicKey: nil,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: createdAt,
                updatedAt: createdAt,
                lastSyncedAt: nil
            ).insert(database)

            for asset in [
                DBAssetRecord(
                    id: "tron:native",
                    networkID: TronConstants.networkID,
                    assetType: DatabaseAssetType.native.rawValue,
                    contractAddress: "",
                    normalizedContractAddress: "",
                    name: "TRON",
                    symbol: "TRX",
                    decimals: 6,
                    trustWalletBlockchain: WalletBlockchain.tron.rawValue,
                    trustWalletContractAddress: nil,
                    isVerified: true,
                    isSpam: false,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    metadataUpdatedAt: createdAt
                ),
                DBAssetRecord(
                    id: spamAssetID,
                    networkID: TronConstants.networkID,
                    assetType: DatabaseAssetType.fungibleToken.rawValue,
                    contractAddress: "TSpamHistoryFixture",
                    normalizedContractAddress: "TSpamHistoryFixture",
                    name: "Spam Token",
                    symbol: "SPAM",
                    decimals: 6,
                    trustWalletBlockchain: WalletBlockchain.tron.rawValue,
                    trustWalletContractAddress: "TSpamHistoryFixture",
                    isVerified: false,
                    isSpam: true,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    metadataUpdatedAt: createdAt
                ),
                DBAssetRecord(
                    id: thresholdAssetID,
                    networkID: TronConstants.networkID,
                    assetType: DatabaseAssetType.fungibleToken.rawValue,
                    contractAddress: "TThresholdHistoryFixture",
                    normalizedContractAddress: "TThresholdHistoryFixture",
                    name: "Threshold Token",
                    symbol: "THR",
                    decimals: 6,
                    trustWalletBlockchain: WalletBlockchain.tron.rawValue,
                    trustWalletContractAddress: "TThresholdHistoryFixture",
                    isVerified: true,
                    isSpam: false,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    metadataUpdatedAt: createdAt
                )
            ] {
                try asset.save(database)
            }

            for index in 0..<370 {
                try historyRecord(
                    id: "newer-spam-\(index)",
                    accountID: accountID,
                    assetID: spamAssetID,
                    symbol: "SPAM",
                    fiatUSDValue: index.isMultiple(of: 2) ? nil : "0.09",
                    timestamp: 2_000 + Double(index)
                ).insert(database)
            }
            try historyRecord(
                id: thresholdTokenID,
                accountID: accountID,
                assetID: thresholdAssetID,
                symbol: "THR",
                fiatUSDValue: "0.10",
                timestamp: 1_900
            ).insert(database)
            for (index, transactionID) in
                nativeTransactionIDs.enumerated()
            {
                try historyRecord(
                    id: transactionID,
                    accountID: accountID,
                    assetID: "tron:native",
                    symbol: "TRX",
                    fiatUSDValue: nil,
                    timestamp: 1_800 - Double(index)
                ).insert(database)
            }
            try DBTransactionNoteRecord(
                transactionID: nativeTransactionIDs[0],
                note: "Legitimate native payment",
                createdAt: createdAt,
                updatedAt: createdAt
            ).insert(database)
        }

        return (
            walletID,
            address,
            thresholdTokenID,
            nativeTransactionIDs
        )
    }

    func historyRecord(
        id: String,
        accountID: String,
        assetID: String,
        symbol: String,
        fiatUSDValue: String?,
        timestamp: Double
    ) -> DBTransactionRecord {
        DBTransactionRecord(
            id: id,
            accountID: accountID,
            networkID: TronConstants.networkID,
            transactionHash: id,
            normalizedTransactionHash: id,
            kind: "received",
            status: "confirmed",
            direction: "incoming",
            fromAddress: nil,
            toAddress: nil,
            counterpartyAddress: nil,
            blockNumber: Int64(timestamp),
            blockHash: nil,
            transactionIndex: nil,
            nonce: nil,
            transactionType: nil,
            timestamp: timestamp,
            assetID: assetID,
            assetSymbol: symbol,
            secondaryAssetSymbol: nil,
            assetAmount: "1",
            fiatUSDValue: fiatUSDValue,
            networkFee: nil,
            networkFeeFiatUSDValue: nil,
            networkFeeSymbol: nil,
            gasPriceGwei: nil,
            gasLimit: nil,
            gasUsed: nil,
            inputData: nil,
            methodName: nil,
            displayDetail: "",
            displayTime: "",
            firstSeenAt: timestamp,
            updatedAt: timestamp
        )
    }

    func solanaSignatureRow(
        _ index: Int
    ) -> SolanaJSONValue {
        .object([
            "signature": .string("signature-\(index)"),
            "slot": .number(Decimal(index)),
            "blockTime": .number(Decimal(1_700_000_000 + index)),
            "err": .null
        ])
    }

    func blockCypherPayload(
        hasMore: Bool?,
        heights: [Int64]
    ) throws -> BitcoinFamilyBlockCypherResponse {
        var object: [String: Any] = [
            "final_balance": 1,
            "txrefs": heights.enumerated().map { index, height in
                [
                    "tx_hash": "transaction-\(index)",
                    "block_height": height,
                    "value": 1,
                    "tx_input_n": -1
                ] as [String: Any]
            }
        ]
        if let hasMore {
            object["hasMore"] = hasMore
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(
            BitcoinFamilyBlockCypherResponse.self,
            from: data
        )
    }

    func blockchairResponse(
        dashboards: [String: Int64]
    ) throws -> BitcoinFamilyBlockchairResponse {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "data": dashboards.mapValues { balance in
                    [
                        "address": [
                            "balance": balance
                        ],
                        "transactions": []
                    ] as [String: Any]
                }
            ]
        )
        return try JSONDecoder().decode(
            BitcoinFamilyBlockchairResponse.self,
            from: data
        )
    }
}
