import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct BitcoinFamilyAtomicIntegerTests {
    private static let dogecoinAtomic =
        "13267076429999999999"
    private static let maximumUInt256 =
        "115792089237316195423570985008687907853269984665640564039457584007913129639935"

    @Test
    func selfTransfersIncludeMiningFeesButNotExternalRecipientsOrUnknownInputs() throws {
        func direction(sent: String, received: String, totalInput: String = "100000",
                       totalOutput: String = "99000", hasEveryInput: Bool = true) throws -> String {
            BitcoinFamilyHistoryEntry.transferDirection(
                sent: try .init(validating: sent), received: try .init(validating: received),
                totalInput: try .init(validating: totalInput), totalOutput: try .init(validating: totalOutput),
                hasEveryInput: hasEveryInput
            )
        }
        // A 1,000-sat mining fee is still a transfer entirely within this wallet.
        #expect(try direction(sent: "100000", received: "99000") == "self")
        // Owned change does not make an external payment a self-transfer.
        #expect(try direction(sent: "100000", received: "49000") == "outgoing")
        #expect(try direction(sent: "0", received: "99000") == "incoming")
        #expect(try direction(sent: "100000", received: "99000", hasEveryInput: false) == "outgoing")
        #expect(try direction(sent: "100000", received: "99000", totalInput: "150000") == "outgoing")
        // Net zero can also be a multi-party transaction; it is not ownership proof.
        #expect(try direction(sent: "50000", received: "50000") == "outgoing")
    }

    @Test
    func duplicateBroadcastResponsesAreAcceptedButNonceErrorsAreNot() {
        for message in [
            "txn-already-known",
            "Transaction already in block chain",
            "txn-already-in-mempool"
        ] {
            #expect(
                SendBitcoinFamilyHTTPAPIClient.isAlreadyKnownMessage(message)
            )
        }
        #expect(
            !SendBitcoinFamilyHTTPAPIClient.isAlreadyKnownMessage(
                "mandatory-script-verify-flag-failed"
            )
        )
    }

    @Test
    func failedElectrumPreflightIsNotAnAmbiguousBroadcast() {
        let error = BitcoinFamilyElectrumError.submissionNotAttempted(
            "provider_timeout"
        )

        #expect(
            error.diagnosticDescription
                == "submission_not_attempted_provider_timeout"
        )
        #expect(!error.submissionWasAttempted)
        #expect(!error.submissionWasCancelledBeforeAttempt)
        let cancellation = BitcoinFamilyElectrumError
            .submissionNotAttempted("cancelled")
        #expect(!cancellation.submissionWasAttempted)
        #expect(cancellation.submissionWasCancelledBeforeAttempt)
    }

    @Test
    func callerCancellationDoesNotInvalidateTheSharedElectrumSocket() {
        #expect(
            !BitcoinFamilyElectrumClient.shouldInvalidateSharedConnection(
                after: CancellationError()
            )
        )
        #expect(
            BitcoinFamilyElectrumClient.shouldInvalidateSharedConnection(
                after: BitcoinFamilyElectrumError.unavailable
            )
        )
    }

    @Test
    func canonicalParsingRejectsMalformedProviderQuantities() throws {
        #expect(
            try BitcoinFamilyAtomicInteger(
                validating: "00013267076429999999999"
            ).decimalText == Self.dogecoinAtomic
        )
        #expect(
            try BitcoinFamilyAtomicInteger(
                validating: "-00042"
            ).decimalText == "-42"
        )
        #expect(
            try BitcoinFamilyAtomicInteger(
                validating: "-0"
            ).decimalText == "0"
        )

        #expect(throws: BitcoinFamilyAtomicIntegerError.empty) {
            try BitcoinFamilyAtomicInteger(validating: "")
        }
        #expect(
            throws:
                BitcoinFamilyAtomicIntegerError.invalidDecimalInteger
        ) {
            try BitcoinFamilyAtomicInteger(validating: "1.0")
        }
        #expect(
            throws:
                BitcoinFamilyAtomicIntegerError.invalidDecimalInteger
        ) {
            try BitcoinFamilyAtomicInteger(validating: "١")
        }
        #expect(throws: BitcoinFamilyAtomicIntegerError.inputTooLong) {
            try BitcoinFamilyAtomicInteger(
                validating: String(repeating: "9", count: 513)
            )
        }
    }

    @Test
    func arithmeticIsExactBeyondUInt64AndInt64() throws {
        let maximum = try BitcoinFamilyAtomicInteger(
            validating: Self.maximumUInt256
        )
        let one = try BitcoinFamilyAtomicInteger(validating: "1")
        let sum = maximum.adding(one)

        #expect(
            sum.decimalText
                == "115792089237316195423570985008687907853269984665640564039457584007913129639936"
        )
        #expect(sum.subtracting(one) == maximum)
        #expect(one.subtracting(maximum).isNegative)
        #expect(
            one.subtracting(maximum).magnitude.decimalText
                == "115792089237316195423570985008687907853269984665640564039457584007913129639934"
        )
    }

    @Test
    func dogecoinAtomicSupplyFormatsWithoutRounding() throws {
        let amount = try BitcoinFamilyAtomicInteger(
            validating: Self.dogecoinAtomic
        )

        #expect(amount > BitcoinFamilyAtomicInteger(Int64.max))
        #expect(
            try amount.userUnits(decimals: 8)
                == "132670764299.99999999"
        )
        #expect(
            amount.decimalProjection(decimals: 8)
                == Decimal(
                    string: "132670764299.99999999",
                    locale: Locale(identifier: "en_US_POSIX")
                )
        )
    }

    @Test
    func uint256ProjectionCannotSilentlyRound() throws {
        let amount = try BitcoinFamilyAtomicInteger(
            validating: Self.maximumUInt256
        )

        #expect(
            try amount.userUnits(decimals: 8)
                == "1157920892373161954235709850086879078532699846656405640394575840079131.29639935"
        )
        #expect(amount.decimalProjection(decimals: 8) == nil)
    }

    @Test
    func losslessJSONPreservesUnquotedProviderNumbers() throws {
        let raw = Data(
            """
            {
              "data": {
                "DTest": {
                  "address": {
                    "balance": \(Self.maximumUInt256)
                  },
                  "transactions": [
                    {
                      "hash": "transaction-1",
                      "time": null,
                      "balance_change": -\(Self.maximumUInt256),
                      "block_id": 9223372036854775807
                    }
                  ]
                }
              }
            }
            """.utf8
        )
        let preserved =
            BitcoinFamilyLosslessJSON.preservingNumberLexemes(in: raw)
        let payload = try JSONDecoder().decode(
            BitcoinFamilyBlockchairResponse.self,
            from: preserved
        )
        let dashboard = try #require(payload.data["DTest"])
        let transaction = try #require(dashboard.transactions.first)

        #expect(
            dashboard.address.balance.decimalText
                == Self.maximumUInt256
        )
        #expect(
            transaction.balanceChange.decimalText
                == "-\(Self.maximumUInt256)"
        )
        #expect(transaction.blockID?.value == Int64.max)
    }

    @Test
    func losslessJSONDoesNotRewriteDigitsInsideStrings() throws {
        let raw = Data(
            """
            {
              "id": 7,
              "result": {
                "confirmed": \(Self.maximumUInt256),
                "unconfirmed": -1,
                "label": "wallet-123"
              },
              "error": null
            }
            """.utf8
        )
        let preserved =
            BitcoinFamilyLosslessJSON.preservingNumberLexemes(in: raw)
        let response = try JSONDecoder().decode(
            ElectrumResponse.self,
            from: preserved
        )
        let result = try #require(response.result?.object)

        #expect(response.id?.value == 7)
        #expect(
            result["confirmed"]?.atomicInteger?.decimalText
                == Self.maximumUInt256
        )
        #expect(
            result["unconfirmed"]?.atomicInteger?.decimalText == "-1"
        )
        #expect(result["label"]?.string == "wallet-123")
    }

    @Test
    func malformedElectrumBalanceIsNotCoercedToZero() throws {
        let malformed = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#""12.5""#.utf8)
        )

        #expect(malformed.atomicInteger == nil)
    }

    @Test
    func electrumSubscriptionNotificationDecodesWithoutResponseID() throws {
        let notification = try JSONDecoder().decode(
            ElectrumResponse.self,
            from: Data(
                #"{"method":"blockchain.scripthash.subscribe","params":["script-hash","status-hash"]}"#.utf8
            )
        )

        #expect(notification.id == nil)
        #expect(
            notification.method
                == "blockchain.scripthash.subscribe"
        )
        #expect(notification.params?.first?.string == "script-hash")
        #expect(notification.params?.last?.string == "status-hash")
    }

    @Test
    func electrumQuantityRequiresPreservedNumericLexeme() throws {
        let unpreservedNumber = try JSONDecoder().decode(
            JSONValue.self,
            from: Data("42".utf8)
        )
        let preservedNumber = try JSONDecoder().decode(
            JSONValue.self,
            from: BitcoinFamilyLosslessJSON.preservingNumberLexemes(
                in: Data("42".utf8)
            )
        )

        #expect(unpreservedNumber.atomicInteger == nil)
        #expect(preservedNumber.atomicInteger?.decimalText == "42")
    }

    @Test
    func electrumBalanceIncludesPendingIncomingExactly() throws {
        let confirmed = try BitcoinFamilyAtomicInteger(
            validating: "100000000"
        )
        let pendingIncoming = try BitcoinFamilyAtomicInteger(
            validating: "25000000"
        )

        let combined = try BitcoinFamilySyncService.combinedElectrumBalance(
            confirmed: confirmed,
            unconfirmed: pendingIncoming
        )

        #expect(combined.decimalText == "125000000")
        #expect(try combined.userUnits(decimals: 8) == "1.25")
    }

    @Test
    func electrumBalanceAppliesPendingOutgoingExactly() throws {
        let confirmed = try BitcoinFamilyAtomicInteger(
            validating: "100000000"
        )
        let pendingOutgoing = try BitcoinFamilyAtomicInteger(
            validating: "-25000000"
        )

        let combined = try BitcoinFamilySyncService.combinedElectrumBalance(
            confirmed: confirmed,
            unconfirmed: pendingOutgoing
        )

        #expect(combined.decimalText == "75000000")
        #expect(try combined.userUnits(decimals: 8) == "0.75")
    }

    @Test
    func electrumBalanceRejectsImpossibleNegativeSpendableValue() throws {
        let confirmed = try BitcoinFamilyAtomicInteger(
            validating: "100"
        )
        let pendingOutgoing = try BitcoinFamilyAtomicInteger(
            validating: "-101"
        )

        #expect(throws: BitcoinFamilyElectrumError.self) {
            try BitcoinFamilySyncService.combinedElectrumBalance(
                confirmed: confirmed,
                unconfirmed: pendingOutgoing
            )
        }
    }

    @Test
    func pendingHistoryIsRetainedAndDeduplicated() {
        let history = BitcoinFamilySyncService.completeIndexedHistory([
            ("pending-hash", 0),
            ("confirmed-hash", 840_000),
            ("pending-hash", 0)
        ])

        #expect(history.count == 2)
        #expect(history[0].0 == "pending-hash")
        #expect(history[0].1 == 0)
        #expect(history[1].0 == "confirmed-hash")
    }

    @Test
    func exactBalanceReadsUseTheShortCriticalPathDeadline() {
        #expect(
            BitcoinFamilyElectrumClient.readTimeoutSeconds(
                for: "blockchain.scripthash.get_balance"
            ) == 5
        )
        #expect(
            BitcoinFamilyElectrumClient.readTimeoutSeconds(
                for: "blockchain.scripthash.subscribe"
            ) == 5
        )
        #expect(
            BitcoinFamilyElectrumClient.readTimeoutSeconds(
                for: "blockchain.scripthash.get_history"
            ) == 9
        )
    }

    @Test
    func activeHistoryAllowsARealisticallyLargeBoundedResponse() {
        #expect(
            BitcoinFamilyElectrumClient.maximumHistoryResponseBytes
                == 8_388_608
        )
        #expect(
            BitcoinFamilyElectrumClient.maximumHistoryResponseBytes
                < 16_777_216
        )
    }

    @Test
    func electrumSeparatesBulkHistoryFromInteractiveBalanceTraffic() {
        #expect(
            BitcoinFamilyElectrumClient.usesBulkConnection(
                for: "blockchain.scripthash.get_history"
            )
        )
        #expect(
            BitcoinFamilyElectrumClient.usesBulkConnection(
                for: "blockchain.scripthash.listunspent"
            )
        )
        #expect(
            !BitcoinFamilyElectrumClient.usesBulkConnection(
                for: "blockchain.scripthash.get_balance"
            )
        )
        #expect(
            !BitcoinFamilyElectrumClient.usesBulkConnection(
                for: "blockchain.scripthash.subscribe"
            )
        )
    }

    @Test
    func rawTransactionRetainsFullUInt64Output() throws {
        let transaction = try #require(
            BitcoinRawTransaction(
                hex:
                    "01000000"
                    + "01"
                    + String(repeating: "00", count: 32)
                    + "ffffffff"
                    + "00"
                    + "ffffffff"
                    + "01"
                    + "ffffffffffffffff"
                    + "00"
                    + "00000000"
            )
        )

        #expect(transaction.outputs.count == 1)
        #expect(
            transaction.outputs[0].value.decimalText
                == "18446744073709551615"
        )
    }

    @Test
    func bitcoinPersistenceRecreatesACascadeDeletedHolding() async throws {
        let database = try WalletDatabase.temporary()
        let walletID = "bitcoin-missing-holding-wallet"
        let accountID = "\(walletID):bitcoin:0"
        let assetID = "bitcoin:native"
        let now = Date().timeIntervalSince1970
        let material = try BitcoinFamilyDerivationService().derive(
            privateKey: Data(repeating: 0x42, count: 32),
            chain: .bitcoin,
            format: .wifCompressed
        )

        try await database.pool.write { database in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Missing Holding Wallet",
                kind: DatabaseWalletKind.importedPrivateKey.rawValue,
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
                address: material.address,
                normalizedAddress: material.address.lowercased(),
                label: nil,
                derivationPath: material.derivationPath,
                accountIndex: 0,
                publicKey: material.publicKey,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(database)
            try DBAssetRecord(
                id: assetID,
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                assetType: DatabaseAssetType.native.rawValue,
                contractAddress: "",
                normalizedContractAddress: "",
                name: "Bitcoin",
                symbol: "BTC",
                decimals: 8,
                trustWalletBlockchain: WalletBlockchain.bitcoin.rawValue,
                trustWalletContractAddress: nil,
                isVerified: true,
                isSpam: false,
                createdAt: now,
                updatedAt: now,
                metadataUpdatedAt: now
            ).insert(database)
        }

        let funded = try BitcoinFamilyAtomicInteger(validating: "6281")
        try await database.saveBitcoinFamilyBalance(
            funded,
            material: material,
            walletID: walletID
        )
        #expect(
            try await database.bitcoinFamilyPersistedBalance(
                walletID: walletID
            )?.decimalText == "6281"
        )

        try await database.pool.write { database in
            _ = try DBAccountAssetRecord.deleteOne(
                database,
                key: ["accountID": accountID, "assetID": assetID]
            )
        }
        try await database.saveBitcoinFamilySnapshot(
            BitcoinFamilyChainSnapshot(
                material: material,
                balanceAtomic: funded,
                history: []
            ),
            walletID: walletID,
            preservingPersistedBalance: true
        )
        #expect(
            try await database.bitcoinFamilyPersistedBalance(
                walletID: walletID
            )?.decimalText == "6281"
        )
    }

    @Test
    func exactBalancePersistsAndPresentsAboveInt64() async throws {
        let database = try WalletDatabase.temporary()
        let walletID = "bitcoin-family-exact-wallet"
        let accountID = "\(walletID):dogecoin:0"
        let assetID = "dogecoin:native"
        let now = Date().timeIntervalSince1970

        try await database.pool.write { database in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Exact Wallet",
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
                networkID: "dogecoin",
                address: "DTestAddress",
                normalizedAddress: "dtestaddress",
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
            try DBAssetRecord(
                id: assetID,
                networkID: "dogecoin",
                assetType: DatabaseAssetType.native.rawValue,
                contractAddress: "",
                normalizedContractAddress: "",
                name: "Dogecoin",
                symbol: "DOGE",
                decimals: 8,
                trustWalletBlockchain: WalletBlockchain.dogecoin.rawValue,
                trustWalletContractAddress: nil,
                isVerified: true,
                isSpam: false,
                createdAt: now,
                updatedAt: now,
                metadataUpdatedAt: now
            ).insert(database)
            try DBAccountAssetRecord(
                accountID: accountID,
                assetID: assetID,
                balance: "132670764299.99999999",
                balanceAtomic: Self.dogecoinAtomic,
                fiatUSDValue: nil,
                isEnabled: true,
                isPinned: false,
                isHidden: false,
                sortOrder: 0,
                firstSeenAt: now,
                lastSeenAt: now,
                updatedAt: now
            ).insert(database)
        }

        let snapshot = try #require(
            try await database.cachedWalletSnapshot(walletID: walletID)
        )
        let asset = try #require(snapshot.assets.first)

        #expect(asset.balanceAtomic == Self.dogecoinAtomic)
        #expect(asset.balanceText == "132670764299.99999999")
        #expect(asset.displayBalanceText == "132670764299.99999999")
    }

    @Test
    func dogecoinSyncRetainsSubmittedRecipientAndExactRepeatAmount()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let walletID = "dogecoin-repeat-wallet"
        let accountID = "\(walletID):dogecoin:0"
        let assetID = "dogecoin:native"
        let sender = "DBYQtyaLsuG3ypgFiBp7H7EnRM8mj5Pwow"
        let recipient = "DD4KSSuBJqcjuTcvUg1CgUKeurPUFeEZkE"
        let transactionHash = String(repeating: "a", count: 64)
        let amount = "10.88656764"
        let amountAtomic = "1088656764"
        let feeAtomic = "226000"
        let now = Date().timeIntervalSince1970

        try await database.pool.write { database in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Repeat Wallet",
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
                networkID: "dogecoin",
                address: sender,
                normalizedAddress: sender.lowercased(),
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
            try DBAssetRecord(
                id: assetID,
                networkID: "dogecoin",
                assetType: DatabaseAssetType.native.rawValue,
                contractAddress: "",
                normalizedContractAddress: "",
                name: "Dogecoin",
                symbol: "DOGE",
                decimals: 8,
                trustWalletBlockchain: WalletBlockchain.dogecoin.rawValue,
                trustWalletContractAddress: nil,
                isVerified: true,
                isSpam: false,
                createdAt: now,
                updatedAt: now,
                metadataUpdatedAt: now
            ).insert(database)
            try DBAccountAssetRecord(
                accountID: accountID,
                assetID: assetID,
                balance: "100",
                balanceAtomic: "10000000000",
                fiatUSDValue: "1",
                isEnabled: true,
                isPinned: false,
                isHidden: false,
                sortOrder: 0,
                firstSeenAt: now,
                lastSeenAt: now,
                updatedAt: now
            ).insert(database)
        }

        let choice = SendAssetChoice(
            id: assetID,
            name: "Dogecoin",
            symbol: "DOGE",
            networkID: "dogecoin",
            networkName: "Dogecoin",
            blockchain: .dogecoin,
            contractAddress: nil,
            decimals: 8,
            logoSource: .nativeCoin(blockchain: .dogecoin),
            networkLogoSource: .network(blockchain: .dogecoin),
            balance: 100,
            fiatValue: 1,
            balanceAtomic: "10000000000",
            sourceAddress: sender
        )
        let draft = SendDraft(
            request: .manualEntry(networkID: "dogecoin"),
            asset: choice,
            recipient: recipient,
            amount: amount,
            note: nil
        )
        let receipt = SendTransactionReceipt(
            transactionHash: transactionHash,
            accountID: accountID,
            networkID: "dogecoin",
            fromAddress: sender,
            toAddress: recipient,
            assetID: assetID,
            assetSymbol: "DOGE",
            amount: amount,
            amountAtomic: amountAtomic,
            networkFee: "0.00226",
            networkFeeAtomic: feeAtomic,
            networkFeeSymbol: "DOGE",
            submittedAt: Date(timeIntervalSince1970: now)
        )
        let recordID = try await database.recordSubmittedSend(
            receipt: receipt,
            draft: draft,
            outcome: .accepted
        )

        let material = BitcoinFamilyAccountMaterial(
            chain: .dogecoin,
            address: sender,
            derivationPath: "m/44'/3'/0'/0/0",
            publicKey: "02test",
            scriptPubKey: Data()
        )
        let synchronizedAmount = try BitcoinFamilyAtomicInteger(
            validating: "1088882764"
        )
        let synchronizedFee = try BitcoinFamilyAtomicInteger(
            validating: feeAtomic
        )
        try await database.saveBitcoinFamilySnapshot(
            BitcoinFamilyChainSnapshot(
                material: material,
                balanceAtomic: try BitcoinFamilyAtomicInteger(
                    validating: "10000000000"
                ),
                history: [
                    BitcoinFamilyHistoryEntry(
                        transactionHash: transactionHash,
                        height: 1,
                        amountAtomic: synchronizedAmount,
                        feeAtomic: synchronizedFee,
                        direction: "outgoing",
                        timestamp: now
                    )
                ]
            ),
            walletID: walletID
        )

        // A history request that finishes after a newer balance refresh must
        // not replace that balance with the request's older snapshot value.
        try await database.saveBitcoinFamilySnapshot(
            BitcoinFamilyChainSnapshot(
                material: material,
                balanceAtomic: .zero,
                history: []
            ),
            walletID: walletID,
            preservingPersistedBalance: true
        )
        let retainedBalance = try await database.bitcoinFamilyPersistedBalance(
            walletID: walletID,
            chain: .dogecoin
        )
        #expect(retainedBalance?.decimalText == "10000000000")

        let stored = try await database.pool.read { database in
            try DBTransactionRecord.fetchOne(database, key: recordID)
        }
        #expect(stored?.toAddress == recipient)
        #expect(stored?.counterpartyAddress == recipient)
        #expect(stored?.assetAmount == amount)

        // Recreate the row shape written by older Bitcoin-family refreshes.
        // The submitted primary transfer must repair it during the next read.
        try await database.pool.write { database in
            var overwritten = try #require(
                try DBTransactionRecord.fetchOne(database, key: recordID)
            )
            overwritten.toAddress = nil
            overwritten.counterpartyAddress = nil
            overwritten.assetAmount = "10.88882764"
            try overwritten.update(database)
        }

        let snapshot = try #require(
            try await database.cachedWalletSnapshot(walletID: walletID)
        )
        let transaction = try #require(
            snapshot.transactions.first { $0.id == recordID }
        )
        #expect(transaction.metadata.toAddress == recipient)
        #expect(transaction.assetAmountAtomic == amountAtomic)
        #expect(transaction.assetAmountText == "-\(amount)")

        let repeatPlan = try WalletTransactionRepeatPreparation.prepare(
            transaction: transaction,
            walletAssets: snapshot.assets,
            capabilities: .fullWallet
        ).get()
        #expect(repeatPlan.draft.recipient == recipient)
        #expect(repeatPlan.draft.amount == amount)

        let receivedHash = String(repeating: "b", count: 64)
        try await database.saveBitcoinFamilySnapshot(
            BitcoinFamilyChainSnapshot(
                material: material,
                balanceAtomic: try BitcoinFamilyAtomicInteger(
                    validating: "10000000000"
                ),
                history: [
                    BitcoinFamilyHistoryEntry(
                        transactionHash: receivedHash,
                        height: 2,
                        amountAtomic: try BitcoinFamilyAtomicInteger(
                            validating: "1088430764"
                        ),
                        feeAtomic: synchronizedFee,
                        direction: "incoming",
                        timestamp: now,
                        identity: BitcoinFamilyTransactionIdentity(
                            fromAddress: recipient,
                            toAddress: sender
                        )
                    )
                ]
            ),
            walletID: walletID
        )
        let received = try await database.pool.read { database in
            try DBTransactionRecord.fetchOne(
                database,
                key: "\(accountID):\(receivedHash)"
            )
        }
        #expect(received?.fromAddress == recipient)
        #expect(received?.toAddress == sender)
        #expect(received?.counterpartyAddress == recipient)
    }
}
