import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite("Bitcoin-family transaction identity")
struct BitcoinFamilyTransactionIdentityTests {
    private let transactionHash =
        "5745023316cb753e531266a83eeb036f21d9e1526e7a575e992b8b02f28353b2"
    private let sender = "DBYQtyaLsuG3ypgFiBp7H7EnRM8mj5Pwow"
    private let wallet = "D9w9pVxGhTirG4CTgo1uK25UR2xRStUp3m"

    @Test
    func standardMainnetScriptsResolveForEverySupportedFamily() throws {
        let fixtures: [(BitcoinFamilyChain, String, String)] = [
            (
                .bitcoin,
                "0014751e76e8199196d454941c45d1b3a323f1433bd6",
                "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
            ),
            (
                .bitcoinCash,
                "76a91476a04053bda0a88bda5177b86a15c3b29f55987388ac",
                "bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a"
            ),
            (
                .litecoin,
                "76a914558dbca7118cd5894502767c7b2ffc21a22f54db88ac",
                "LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA"
            ),
            (
                .dogecoin,
                "76a9144639a5490867c74131fae745b8a8f0cdafd82c4888ac",
                sender
            ),
        ]
        for (chain, scriptHex, expectedAddress) in fixtures {
            let script = try #require(Data(bitcoinHex: scriptHex))
            #expect(
                BitcoinFamilyScriptAddress.address(
                    from: script,
                    chain: chain
                ) == expectedAddress
            )
        }
    }

    @Test
    func incomingIdentityUsesExternalInputBeforeWalletOutput() {
        let identity = BitcoinFamilyTransactionIdentityMapper.identity(
            chain: .dogecoin,
            walletAddress: wallet,
            direction: "incoming",
            inputAddresses: [sender],
            outputAddresses: [wallet, sender]
        )

        #expect(identity.fromAddress == sender)
        #expect(identity.toAddress == wallet)
    }

    @Test
    func blockchairResponseRetainsTheRealDogecoinSender() throws {
        let payload = try JSONDecoder().decode(
            BitcoinFamilyBlockchairTransactionIdentityResponse.self,
            from: Data(
                """
                {
                  "data": {
                    "\(transactionHash)": {
                      "transaction": {"hash": "\(transactionHash)"},
                      "inputs": [{"recipient": "\(sender)"}],
                      "outputs": [
                        {"recipient": "\(wallet)"},
                        {"recipient": "\(sender)"}
                      ]
                    }
                  }
                }
                """.utf8
            )
        )

        let identity = try BitcoinFamilyIndexedAPIClient
            .transactionIdentity(
                blockchair: payload,
                chain: .dogecoin,
                transactionHash: transactionHash,
                walletAddress: wallet,
                direction: "incoming"
            )
        #expect(identity.fromAddress == sender)
        #expect(identity.toAddress == wallet)
    }

    @Test
    func blockCypherFallbackRetainsTheRealDogecoinSender() throws {
        let payload = try JSONDecoder().decode(
            BitcoinFamilyBlockCypherTransactionDetails.self,
            from: Data(
                """
                {
                  "hash": "\(transactionHash)",
                  "inputs": [{"addresses": ["\(sender)"]}],
                  "outputs": [
                    {"addresses": ["\(wallet)"]},
                    {"addresses": ["\(sender)"]}
                  ]
                }
                """.utf8
            )
        )

        let identity = try BitcoinFamilyIndexedAPIClient
            .transactionIdentity(
                blockCypher: payload,
                chain: .dogecoin,
                transactionHash: transactionHash,
                walletAddress: wallet,
                direction: "incoming"
            )
        #expect(identity.fromAddress == sender)
        #expect(identity.toAddress == wallet)
    }

    @Test
    func cachedReceivedTransactionIsRepairedWithoutOverwritingToAddress()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let walletID = "identity-repair-wallet"
        let accountID = "\(walletID):dogecoin:0"
        let now = Date().timeIntervalSince1970
        try await database.pool.write { database in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Identity Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: "test-keychain-reference",
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil
            ).insert(database)
            try DBWalletAccountRecord(
                id: accountID,
                walletID: walletID,
                networkID: BitcoinFamilyChain.dogecoin.networkID,
                address: wallet,
                normalizedAddress: wallet.lowercased(),
                label: nil,
                derivationPath: "m/44'/3'/0'/0/0",
                accountIndex: 0,
                publicKey: "02test",
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: now
            ).insert(database)
            try transactionRecord(
                accountID: accountID,
                timestamp: now
            ).insert(database)
        }

        let context = try #require(
            try await database.bitcoinFamilyTransactionIdentityContext(
                transactionID: "\(accountID):\(transactionHash)"
            )
        )
        let repaired = try await database
            .repairBitcoinFamilyTransactionIdentity(
                context: context,
                resolved: BitcoinFamilyTransactionIdentity(
                    fromAddress: sender,
                    toAddress: "DD4KSSuBJqcjuTcvUg1CgUKeurPUFeEZkE"
                )
            )
        #expect(repaired.fromAddress == sender)
        #expect(repaired.toAddress == wallet)

        let stored = try await database.pool.read { database in
            try DBTransactionRecord.fetchOne(
                database,
                key: context.transactionID
            )
        }
        #expect(stored?.fromAddress == sender)
        #expect(stored?.toAddress == wallet)
        #expect(stored?.counterpartyAddress == sender)
        #expect(stored?.displayDetail == sender)
    }

    @Test
    func staleImportedBitcoinActivityUsesPersistedRecipientForRepeat()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let walletID = "imported-repeat-wallet"
        let accountID = "\(walletID):bitcoin:0"
        let walletAddress =
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        let recipient = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
        let hash = String(repeating: "c", count: 64)
        let transactionID = "\(accountID):\(hash)"
        let now = Date().timeIntervalSince1970

        try await database.pool.write { database in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Imported Wallet",
                kind: DatabaseWalletKind.importedRecoveryPhrase.rawValue,
                secretKeyReference: "test-keychain-reference",
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil
            ).insert(database)
            try DBWalletAccountRecord(
                id: accountID,
                walletID: walletID,
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                address: walletAddress,
                normalizedAddress: walletAddress.lowercased(),
                label: nil,
                derivationPath: "m/84'/0'/0'/0/0",
                accountIndex: 0,
                publicKey: "02test",
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: now
            ).insert(database)
            try DBTransactionRecord(
                id: transactionID,
                accountID: accountID,
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                transactionHash: hash,
                normalizedTransactionHash: hash,
                kind: "sent",
                status: "confirmed",
                direction: "outgoing",
                fromAddress: walletAddress,
                toAddress: recipient,
                counterpartyAddress: recipient,
                blockNumber: 900_000,
                blockHash: nil,
                transactionIndex: nil,
                nonce: nil,
                transactionType: nil,
                timestamp: now,
                assetID: nil,
                assetSymbol: "BTC",
                secondaryAssetSymbol: nil,
                assetAmount: "0.00001715",
                fiatUSDValue: nil,
                networkFee: "0.000001",
                networkFeeFiatUSDValue: nil,
                networkFeeSymbol: "BTC",
                gasPriceGwei: nil,
                gasLimit: nil,
                gasUsed: nil,
                inputData: nil,
                methodName: nil,
                displayDetail: recipient,
                displayTime: "Confirmed",
                firstSeenAt: now,
                updatedAt: now
            ).insert(database)
        }

        let amount = try #require(
            Decimal(
                string: "-0.00001715",
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
        let staleTransaction = WalletTransaction(
            id: transactionID,
            kind: .sent(assetSymbol: "BTC"),
            detail: recipient,
            time: "",
            assetLogoSource: .nativeCoin(blockchain: .bitcoin),
            assetAmount: amount,
            assetAmountText: "-0.00001715",
            assetAmountAtomic: "1715",
            assetSymbol: "BTC",
            fiatValue: nil,
            status: .confirmed,
            metadata: WalletTransactionMetadata(
                transactionHash: hash,
                blockchainIdentifier:
                    BitcoinFamilyChain.bitcoin.networkID,
                date: Date(timeIntervalSince1970: now),
                fromAddress: nil,
                toAddress: nil,
                blockNumber: 900_000,
                blockHash: nil,
                contractAddress: nil,
                tokenName: "Bitcoin",
                tokenDecimals: 8,
                logIndex: nil,
                networkFee: nil,
                networkFeeFiatValue: nil,
                networkFeeSymbol: "BTC",
                gasPriceGwei: nil,
                gasLimit: nil,
                gasUsed: nil,
                nonce: nil,
                transactionIndex: nil,
                transactionType: nil,
                inputData: nil,
                note: nil
            )
        )
        let asset = WalletAsset(
            id: "bitcoin:native",
            name: "Bitcoin",
            symbol: "BTC",
            logoSource: .nativeCoin(blockchain: .bitcoin),
            network: .bitcoin,
            balance: 1,
            fiatValue: 1,
            balanceText: "1",
            balanceAtomic: "100000000",
            decimals: 8,
            receiveAddress: walletAddress
        )

        guard case .failure(.missingTransactionDetails) =
            WalletTransactionRepeatPreparation.prepare(
                transaction: staleTransaction,
                walletAssets: [asset],
                capabilities: .fullWallet
            ) else {
            Issue.record("The stale fixture must reproduce the reported bug.")
            return
        }

        let hydrated = try await BitcoinFamilyTransactionIdentityResolver(
            database: database
        ).transactionByResolvingRepeatRecipient(staleTransaction)
        #expect(hydrated.metadata.fromAddress == walletAddress)
        #expect(hydrated.metadata.toAddress == recipient)

        let plan = try WalletTransactionRepeatPreparation.prepare(
            transaction: hydrated,
            walletAssets: [asset],
            capabilities: .fullWallet
        ).get()
        #expect(plan.draft.recipient == recipient)
        #expect(plan.draft.amount == "0.00001715")
        #expect(plan.draft.usesMaximumBalance == false)
    }

    private func transactionRecord(
        accountID: String,
        timestamp: Double
    ) -> DBTransactionRecord {
        DBTransactionRecord(
            id: "\(accountID):\(transactionHash)",
            accountID: accountID,
            networkID: BitcoinFamilyChain.dogecoin.networkID,
            transactionHash: transactionHash,
            normalizedTransactionHash: transactionHash,
            kind: "received",
            status: "confirmed",
            direction: "incoming",
            fromAddress: nil,
            toAddress: wallet,
            counterpartyAddress: nil,
            blockNumber: 6_344_993,
            blockHash: nil,
            transactionIndex: nil,
            nonce: nil,
            transactionType: nil,
            timestamp: timestamp,
            assetID: nil,
            assetSymbol: "DOGE",
            secondaryAssetSymbol: nil,
            assetAmount: "10.88430764",
            fiatUSDValue: "1",
            networkFee: "0.00226",
            networkFeeFiatUSDValue: nil,
            networkFeeSymbol: "DOGE",
            gasPriceGwei: nil,
            gasLimit: nil,
            gasUsed: nil,
            inputData: nil,
            methodName: nil,
            displayDetail: transactionHash,
            displayTime: "Confirmed",
            firstSeenAt: timestamp,
            updatedAt: timestamp
        )
    }
}
