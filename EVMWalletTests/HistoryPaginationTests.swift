import Foundation
import GRDB
import Testing
@testable import Aperture

struct HistoryPaginationTests {
    private static let maximumUInt256At18Decimals =
        "115792089237316195423570985008687907853269984665640564039457.584007913129639935"

    private enum FixtureError: Error, Equatable {
        case laterPageFailed
    }

    private actor FixtureCounter {
        private var value = 0

        func increment() {
            value += 1
        }

        func currentValue() -> Int {
            value
        }
    }

    @Test
    func paginatorCollectsEveryPageInProviderOrder() async throws {
        let result: HistoryPaginationResult<Int> =
            try await HistoryPaginator.collect(
                service: "test",
                stream: "three_pages",
                initialCursor: 0
            ) { cursor in
                switch cursor {
                case 0:
                    HistoryPage(
                        items: Array(0..<100),
                        nextCursor: 100
                    )
                case 100:
                    HistoryPage(
                        items: Array(100..<200),
                        nextCursor: 200
                    )
                case 200:
                    HistoryPage(
                        items: Array(200..<250),
                        nextCursor: nil
                    )
                default:
                    throw FixtureError.laterPageFailed
                }
            }

        #expect(result.pageCount == 3)
        #expect(result.reportedItemCount == 250)
        #expect(result.items == Array(0..<250))
    }

    @Test
    func paginatorStopsAtBoundedItemCountWithoutFetchingAnotherPage()
        async throws
    {
        let fetchedPageCount = FixtureCounter()
        let result: HistoryPaginationResult<Int> =
            try await HistoryPaginator.collect(
                service: "test",
                stream: "bounded_items",
                initialCursor: 0,
                maximumItems: 150
            ) { cursor in
                await fetchedPageCount.increment()
                return switch cursor {
                case 0:
                    HistoryPage(
                        items: Array(0..<100),
                        nextCursor: 100
                    )
                case 100:
                    HistoryPage(
                        items: Array(100..<200),
                        nextCursor: 200
                    )
                default:
                    throw FixtureError.laterPageFailed
                }
            }

        #expect(await fetchedPageCount.currentValue() == 2)
        #expect(result.pageCount == 2)
        #expect(result.reportedItemCount == 150)
        #expect(result.items == Array(0..<150))
    }

    @Test
    func paginatorRejectsNonPositiveItemLimit() async {
        await #expect(throws: HistoryPaginationError.invalidItemLimit) {
            let _: HistoryPaginationResult<Int> =
                try await HistoryPaginator.collect(
                    service: "test",
                    stream: "invalid_item_limit",
                    maximumItems: 0
                ) { _ in
                    HistoryPage(items: [], nextCursor: nil as Int?)
                }
        }
    }

    @Test
    func paginatorBoundsDashboardPagesByProviderReportedCount()
        async throws
    {
        let fetchedPageCount = FixtureCounter()
        let result: HistoryPaginationResult<String> =
            try await HistoryPaginator.collect(
                service: "test",
                stream: "reported_items",
                initialCursor: 0,
                maximumReportedItems: 150
            ) { cursor in
                await fetchedPageCount.increment()
                return switch cursor {
                case 0:
                    HistoryPage(
                        items: ["dashboard-0"],
                        nextCursor: 100,
                        reportedItemCount: 100
                    )
                case 100:
                    HistoryPage(
                        items: ["dashboard-1"],
                        nextCursor: 200,
                        reportedItemCount: 100
                    )
                default:
                    throw FixtureError.laterPageFailed
                }
            }

        #expect(await fetchedPageCount.currentValue() == 2)
        #expect(result.items == ["dashboard-0", "dashboard-1"])
        #expect(result.reportedItemCount == 150)
    }

    @Test
    func paginatorRejectsNonPositiveReportedItemLimit() async {
        await #expect(
            throws: HistoryPaginationError.invalidReportedItemLimit
        ) {
            let _: HistoryPaginationResult<Int> =
                try await HistoryPaginator.collect(
                    service: "test",
                    stream: "invalid_reported_item_limit",
                    maximumReportedItems: 0
                ) { _ in
                    HistoryPage(items: [], nextCursor: nil as Int?)
                }
        }
    }

    @Test
    func paginatorRejectsRepeatedCursorWithoutReturningPartialData() async {
        await #expect(throws: HistoryPaginationError.repeatedCursor) {
            let _: HistoryPaginationResult<Int> =
                try await HistoryPaginator.collect(
                    service: "test",
                    stream: "repeated_cursor",
                    initialCursor: "cursor"
                ) { _ in
                    HistoryPage(
                        items: [1],
                        nextCursor: "cursor"
                    )
                }
        }
    }

    @Test
    func paginatorPropagatesLaterPageFailure() async {
        await #expect(throws: FixtureError.laterPageFailed) {
            let _: HistoryPaginationResult<Int> =
                try await HistoryPaginator.collect(
                    service: "test",
                    stream: "later_failure",
                    initialCursor: 0
                ) { cursor in
                    guard cursor == 0 else {
                        throw FixtureError.laterPageFailed
                    }
                    return HistoryPage(
                        items: Array(0..<100),
                        nextCursor: 100
                    )
                }
        }
    }

    @Test
    func tronGridFingerprintDecodesAsOpaqueCursor() throws {
        let data = Data(
            """
            {
              "data": [],
              "success": true,
              "meta": {
                "fingerprint": "opaque-next-page-token"
              }
            }
            """.utf8
        )
        let envelope = try JSONDecoder().decode(
            TronGridEnvelope<TronGridTokenTransfer>.self,
            from: data
        )

        #expect(envelope.success)
        #expect(envelope.meta?.fingerprint == "opaque-next-page-token")
    }

    @Test
    func blockchairOffsetAdvancesByEntireReturnedPage() {
        #expect(
            BitcoinFamilyIndexedAPIClient.nextBlockchairOffset(
                transactionCount: 100,
                currentOffset: 200,
                pageSize: 100
            ) == 300
        )
        #expect(
            BitcoinFamilyIndexedAPIClient.nextBlockchairOffset(
                transactionCount: 99,
                currentOffset: 200,
                pageSize: 100
            ) == nil
        )
    }

    @Test
    func blockchairUsesSeparateTransactionLimitAndOffset() {
        let values = Dictionary(
            uniqueKeysWithValues:
                BitcoinFamilyIndexedAPIClient
                    .blockchairPaginationQueryItems(offset: 300)
                    .compactMap { item in
                        item.value.map { (item.name, $0) }
                    }
        )

        #expect(values["limit"] == "100,0")
        #expect(values["offset"] == "300,0")
    }

    @Test
    func blockchairAcceptsExactRequestedAddress() throws {
        let requestedAddress =
            "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
        let payload = try blockchairResponse(
            dashboards: [
                requestedAddress: 42
            ]
        )

        let dashboard = try BitcoinFamilyIndexedAPIClient
            .exactBlockchairDashboard(
                in: payload,
                requestedAddress: requestedAddress
            )

        #expect(dashboard.address.balance.decimalText == "42")
    }

    @Test
    func blockchairSelectsExactAddressAmongMultipleDashboards() throws {
        let requestedAddress =
            "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
        let unrelatedAddress =
            "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
        let payload = try blockchairResponse(
            dashboards: [
                unrelatedAddress: 99,
                requestedAddress: 42
            ]
        )

        let dashboard = try BitcoinFamilyIndexedAPIClient
            .exactBlockchairDashboard(
                in: payload,
                requestedAddress: requestedAddress
            )

        #expect(dashboard.address.balance.decimalText == "42")
    }

    @Test
    func blockchairRejectsUnrelatedDashboard() throws {
        let requestedAddress =
            "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
        let unrelatedAddress =
            "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
        let payload = try blockchairResponse(
            dashboards: [
                unrelatedAddress: 99
            ]
        )

        #expect(
            throws: BitcoinFamilyAPIError.blockchairAddressMismatch
        ) {
            try BitcoinFamilyIndexedAPIClient
                .exactBlockchairDashboard(
                    in: payload,
                    requestedAddress: requestedAddress
                )
        }
    }

    @Test
    func blockchairRejectsEmptyDashboardMap() throws {
        let payload = try blockchairResponse(dashboards: [:])

        #expect(throws: BitcoinFamilyAPIError.invalidResponse) {
            try BitcoinFamilyIndexedAPIClient
                .exactBlockchairDashboard(
                    in: payload,
                    requestedAddress:
                        "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
                )
        }
    }

    @Test
    func blockchairRejectsCaseChangedBase58Address() throws {
        let requestedAddress =
            "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
        let caseChangedAddress =
            "1a1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
        let payload = try blockchairResponse(
            dashboards: [
                caseChangedAddress: 99
            ]
        )

        #expect(
            throws: BitcoinFamilyAPIError.blockchairAddressMismatch
        ) {
            try BitcoinFamilyIndexedAPIClient
                .exactBlockchairDashboard(
                    in: payload,
                    requestedAddress: requestedAddress
                )
        }
    }

    @Test
    func blockCypherCursorUsesOldestConfirmedBlock() throws {
        let payload = try blockCypherPayload(
            hasMore: true,
            heights: [900, 850, 850]
        )

        #expect(
            try BitcoinFamilyIndexedAPIClient.nextBlockCypherCursor(
                payload: payload
            ) == 850
        )
    }

    @Test
    func blockCypherTreatsMissingHasMoreAsTerminalPage() throws {
        let payload = try blockCypherPayload(
            hasMore: nil,
            heights: [900]
        )

        #expect(
            try BitcoinFamilyIndexedAPIClient.nextBlockCypherCursor(
                payload: payload
            ) == nil
        )
    }

    @Test
    func electrumHistoryRetainsNewestBoundedEntries() {
        let source = (0..<450).map {
            ("transaction-\($0)", Int64($0 + 1))
        }
        let result = BitcoinFamilySyncService.completeIndexedHistory(
            source + [source[0]]
        )

        #expect(result.count == 400)
        #expect(result.first?.0 == "transaction-449")
        #expect(result.last?.0 == "transaction-50")
    }

    @Test
    func electrumHistoryPublishesPendingBeforeConfirmedHistory() {
        let result = BitcoinFamilySyncService.completeIndexedHistory([
            ("confirmed-newer", 200),
            ("pending", 0),
            ("confirmed-older", 100),
        ])

        #expect(result.map(\.0) == [
            "pending",
            "confirmed-newer",
            "confirmed-older",
        ])
    }

    @Test
    func ankrMapperRetainsMoreThanOneHundredTransactions() throws {
        let walletAddress =
            "0x1111111111111111111111111111111111111111"
        let senderAddress =
            "0x2222222222222222222222222222222222222222"
        let nativeAsset = AnkrBalanceAsset(
            blockchain: "eth",
            tokenName: "Ether",
            tokenSymbol: "ETH",
            tokenDecimals: 18,
            tokenType: "NATIVE",
            contractAddress:
                "0x0000000000000000000000000000000000000000",
            balance: "150",
            balanceRawInteger: "150000000000000000000",
            balanceUsd: "150",
            tokenPrice: "1",
            thumbnail: ""
        )
        let transactions = (0..<150).map {
            makeAnkrTransaction(
                index: $0,
                senderAddress: senderAddress,
                walletAddress: walletAddress
            )
        }

        let snapshot = try AnkrAPIClient.makeSnapshot(
            address: walletAddress,
            balanceResult: AnkrBalanceResult(
                totalBalanceUsd: "150",
                assets: [nativeAsset],
                nextPageToken: nil
            ),
            transfers: [],
            rawTransactions: transactions
        )

        #expect(snapshot.transactions.count == 150)
    }

    @Test
    func ankrTransferDecodingRetainsMaximumRawUInt256() throws {
        let transfer = try JSONDecoder().decode(
            AnkrTokenTransfer.self,
            from: Data(
                """
                {
                  "value": "1",
                  "valueRawInteger": "\(AnkrTokenAmount.maximumUInt256)"
                }
                """.utf8
            )
        )

        #expect(transfer.value == "1")
        #expect(
            transfer.valueRawInteger
                == AnkrTokenAmount.maximumUInt256
        )
    }

    @Test
    func ankrRawUInt256ProducesExactUserUnitText() throws {
        let amount = try AnkrTokenAmount(
            rawInteger: AnkrTokenAmount.maximumUInt256,
            normalizedValue: "1",
            decimals: 18
        )

        #expect(
            amount.exactMagnitudeText
                == Self.maximumUInt256At18Decimals
        )
        #expect(amount.atomicText == AnkrTokenAmount.maximumUInt256)
        #expect(amount.source == .rawInteger)
        #expect(amount.projectionWasBounded)
        #expect(amount.normalizedMatchesRaw == false)
    }

    @Test
    func ankrRawValueIsAuthoritativeOverRoundedNormalizedValue() {
        let snapshot = makeAnkrTokenSnapshot(
            rawInteger: AnkrTokenAmount.maximumUInt256,
            normalizedValue: "1"
        )

        #expect(snapshot.transactions.count == 1)
        #expect(
            snapshot.transactions.first?.assetAmountText
                == Self.maximumUInt256At18Decimals
        )
        #expect(
            snapshot.transactions.first?.assetAmountAtomic
                == AnkrTokenAmount.maximumUInt256
        )
    }

    @Test
    func ankrMalformedRawValueFailsClosedInsteadOfUsingNormalizedValue() {
        let snapshot = makeAnkrTokenSnapshot(
            rawInteger: "123-not-an-integer",
            normalizedValue: "123.5"
        )

        #expect(snapshot.transactions.isEmpty)
    }

    @Test
    func ankrRawValueAboveUInt256RangeIsRejected() {
        #expect(throws: AnkrTokenAmountError.rawIntegerOutOfRange) {
            try AnkrTokenAmount(
                rawInteger:
                    "115792089237316195423570985008687907853269984665640564039457584007913129639936",
                normalizedValue: "1",
                decimals: 18
            )
        }
    }

    @Test
    func ankrNormalizedFallbackRemainsExactWhenRawValueIsAbsent() {
        let exact = "123.456789012345678901234567890123456789"
        let snapshot = makeAnkrTokenSnapshot(
            rawInteger: nil,
            normalizedValue: exact
        )

        #expect(snapshot.transactions.count == 1)
        #expect(snapshot.transactions.first?.assetAmountText == exact)
        #expect(snapshot.transactions.first?.assetAmountAtomic == nil)
    }

    @Test
    func ankrExactRawAmountSurvivesGRDBAndCacheRoundTrip() async throws {
        let database = try WalletDatabase.temporary()
        let walletAddress =
            "0x1111111111111111111111111111111111111111"
        try await seedAnkrWallet(
            address: walletAddress,
            database: database
        )
        let snapshot = makeAnkrTokenSnapshot(
            rawInteger: AnkrTokenAmount.maximumUInt256,
            normalizedValue: "1",
            walletAddress: walletAddress
        )

        try await database.saveWalletSnapshot(
            snapshot,
            address: walletAddress
        )

        let persisted = try await database.pool.read { database in
            guard
                let transaction = try DBTransactionRecord
                    .filter(Column("assetSymbol") == "RAW")
                    .fetchOne(database),
                let transfer = try DBTransactionTransferRecord.fetchOne(
                    database,
                    key: "\(transaction.id)|primary"
                )
            else {
                return (transaction: String?.none, atomic: String?.none)
            }
            return (
                transaction: Optional(transaction.assetAmount),
                atomic: transfer.amountAtomic
            )
        }
        let cached = try await database.cachedWalletSnapshot(
            address: walletAddress
        )

        #expect(
            persisted.transaction
                == Self.maximumUInt256At18Decimals
        )
        #expect(persisted.atomic == AnkrTokenAmount.maximumUInt256)
        #expect(
            cached?.transactions.first?.assetAmountText
                == persisted.transaction
        )
        #expect(
            cached?.transactions.first?.assetAmountAtomic
                == AnkrTokenAmount.maximumUInt256
        )
    }

    @Test
    func solanaPaginationUsesRawPageSizeWhenOneRowIsMalformed() async throws {
        let firstPage: [SolanaJSONValue] = (0..<1_000).map { index in
            if index == 400 {
                return .object([
                    "signature": .string("signature-400"),
                    "err": .null
                ])
            }
            return solanaSignatureRow(index)
        }
        let secondPage = [
            solanaSignatureRow(1_000),
            solanaSignatureRow(1_001)
        ]

        let result = try await SolanaAPIClient.collectSignatures(
            until: "existing-newest-signature"
        ) { before, until, pageLimit in
            guard pageLimit == 1_000 else {
                throw FixtureError.laterPageFailed
            }
            guard until == "existing-newest-signature" else {
                throw FixtureError.laterPageFailed
            }
            switch before {
            case nil:
                return .array(firstPage)
            case "signature-999":
                return .array(secondPage)
            default:
                throw FixtureError.laterPageFailed
            }
        }

        #expect(result.count == 1_001)
        #expect(result.first?.signature == "signature-0")
        #expect(result.last?.signature == "signature-1001")
        #expect(!result.contains(where: {
            $0.signature == "signature-400"
        }))
    }

    @Test
    func solanaPaginationRejectsProviderThatRepeatsAFullPage() async {
        let repeatedPage = (0..<4).map(solanaSignatureRow)

        await #expect(throws: HistoryPaginationError.repeatedCursor) {
            try await SolanaAPIClient.collectSignatures(
                until: nil,
                pageLimit: 4,
                maximumPages: 10
            ) { _, _, _ in
                .array(repeatedPage)
            }
        }
    }

    @Test
    func solanaPaginationReturnsBoundedRecentHistoryForActiveAccount() async throws {
        let firstPage = (0..<100).map(solanaSignatureRow)

        let result = try await SolanaAPIClient.collectSignatures(
            until: nil,
            pageLimit: 100,
            maximumPages: 5,
            maximumItems: 100
        ) { before, _, _ in
            guard before == nil else {
                throw FixtureError.laterPageFailed
            }
            return .array(firstPage)
        }

        #expect(result.count == 100)
        #expect(result.first?.signature == "signature-0")
        #expect(result.last?.signature == "signature-99")
    }

    @Test
    func cachedHistoryCountsOnlyVisibleRowsBeforeApplyingItsLimit() async throws {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedTronVisibilityHistory(database: database)
        let walletSnapshot = try #require(
            try await database.cachedWalletSnapshot(walletID: fixture.walletID)
        )
        let addressSnapshot = try #require(
            try await database.cachedWalletSnapshot(address: fixture.address)
        )
        for snapshot in [walletSnapshot, addressSnapshot] {
            let transactionIDs = snapshot.transactions.map(\.id)
            #expect(transactionIDs.count == 100)
            #expect(transactionIDs.first == fixture.thresholdTokenID)
            #expect(snapshot.transactions.allSatisfy { $0.status == .confirmed })
            #expect(
                transactionIDs.last == fixture.nativeTransactionIDs[98]
            )
            #expect(
                !transactionIDs.contains { $0.hasPrefix("newer-spam-") }
            )
            #expect(
                snapshot.transactions.first {
                    $0.id == fixture.nativeTransactionIDs[0]
                }?.metadata.note == "Legitimate native payment"
            )
            #expect(
                snapshot.transactions.first {
                    $0.id == fixture.thresholdTokenID
                }?.fiatValue == Decimal(string: "0.10")
            )
        }
    }

    @Test
    func solanaPaginationRejectsFullPageWithoutSafeCursor() async {
        let page: [SolanaJSONValue] = [
            solanaSignatureRow(0),
            .object([
                "slot": .number(1),
                "err": .null
            ])
        ]

        await #expect(throws: SolanaProviderError.self) {
            try await SolanaAPIClient.collectSignatures(
                until: nil,
                pageLimit: 2
            ) { _, _, _ in
                .array(page)
            }
        }
    }

    @Test
    func solanaPaginationStopsAtMaximumPageLimitWithUniqueCursors() async {
        await #expect(throws: HistoryPaginationError.pageLimitExceeded(2)) {
            try await SolanaAPIClient.collectSignatures(
                until: nil,
                pageLimit: 1,
                maximumPages: 2
            ) { before, _, _ in
                let nextIndex: Int
                if let before,
                   let currentIndex = Int(
                       before.replacingOccurrences(
                           of: "signature-",
                           with: ""
                       )
                   ) {
                    nextIndex = currentIndex + 1
                } else {
                    nextIndex = 0
                }

                return .array([
                    .object([
                        "signature": .string("signature-\(nextIndex)"),
                        "slot": .number(Decimal(nextIndex)),
                        "err": .null
                    ])
                ])
            }
        }
    }
}
