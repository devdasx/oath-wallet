import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct TronUInt256Tests {
    private static let maximum =
        "115792089237316195423570985008687907853269984665640564039457584007913129639935"
    private static let maximumHex = String(repeating: "f", count: 64)
    private static let maximumWithSixDecimals =
        "115792089237316195423570985008687907853269984665640564039457584007913129.639935"
    private static let overflow =
        "115792089237316195423570985008687907853269984665640564039457584007913129639936"
    private static let walletID = "tron-uint256-wallet"
    private static let accountAddress =
        "TQn9Y2khEsLJW1ChVWFMSMeRDow5KcbLSE"
    private static let senderAddress =
        "TPYmHEhy5n8TCEfYGqW2rPxsghSfzghPDn"
    private static let contractAddress =
        "TXLAQ63Xg1NAzckPwKHvzw7CSEmLMEqcdj"
    private static let screenshotRecipient =
        "TPSovt4buv51PZXEN15zLosbk2ajEdW7G4"

    @Test
    func convertsChecksummedTronContractToEVMHexAddress() {
        #expect(
            TronValueParser.hexAddress(Self.contractAddress)
                == "0xea51342dabbb928ae1e576bd39eff8aaf070a8c6"
        )
        #expect(
            TronValueParser.hexAddress("not-a-tron-contract") == nil
        )
    }

    @Test
    func malformedNativeBalanceCanNeverBecomeAnAuthoritativeZero() throws {
        #expect(try TronValueParser.hexQuantity("0x0") == 0)
        #expect(try TronValueParser.hexQuantity("0x01") == 1)
        #expect(throws: TronUInt256Error.invalidHex) {
            try TronValueParser.hexQuantity("provider unavailable")
        }
        #expect(throws: TronUInt256Error.empty) {
            try TronValueParser.hexQuantity("0x")
        }
        #expect(throws: TronUInt256Error.outOfRange) {
            try TronValueParser.hexQuantity(
                "0x1" + String(repeating: "0", count: 16)
            )
        }
    }

    @Test
    func decodesTRC20DynamicAndBytes32MetadataWithoutLoss() {
        let dynamicName =
            "0x0000000000000000000000000000000000000000000000000000000000000020"
            + "000000000000000000000000000000000000000000000000000000000000000a"
            + "5465746865722055534400000000000000000000000000000000000000000000"
        let bytes32Symbol =
            "0x5553445400000000000000000000000000000000000000000000000000000000"
        let decimals =
            "0x0000000000000000000000000000000000000000000000000000000000000006"

        #expect(
            TronValueParser.abiText(dynamicName, maximumLength: 80)
                == "Tether USD"
        )
        #expect(
            TronValueParser.abiText(bytes32Symbol, maximumLength: 24)
                == "USDT"
        )
        #expect(TronValueParser.abiUInt8(decimals) == 6)
        #expect(TronValueParser.abiText("0x", maximumLength: 80) == nil)
        #expect(TronValueParser.abiUInt8("0x0102") == nil)
    }

    @Test
    func customTokenAddressExtractionRequiresTRONChecksum() {
        let contract = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"

        #expect(
            CustomTokenAddress.extracted(
                from: "https://tronscan.org/#/token20/\(contract)",
                networkID: TronConstants.networkID
            ) == contract
        )
        #expect(
            CustomTokenAddress.normalized(
                String(contract.dropLast()) + "u",
                networkID: TronConstants.networkID
            ) == nil
        )
    }

    @Test
    func customTRC20LookupUsesExactReadOnlyABISelectors() async throws {
        let endpoint = URL(string: "https://tron.example/jsonrpc")!
        let response = Data(
            """
            [
              {"jsonrpc":"2.0","id":1,"result":"0x0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000a5465746865722055534400000000000000000000000000000000000000000000"},
              {"jsonrpc":"2.0","id":2,"result":"0x000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000045553445400000000000000000000000000000000000000000000000000000000"},
              {"jsonrpc":"2.0","id":3,"result":"0x0000000000000000000000000000000000000000000000000000000000000006"}
            ]
            """.utf8
        )
        let transport = TronAPITransport(
            jsonRPCEndpoints: [endpoint],
            requestExecutor: { request in
                let body = try #require(request.httpBody)
                let requests = try #require(
                    JSONSerialization.jsonObject(with: body)
                        as? [[String: Any]]
                )
                let selectors: Set<String> = Set(requests.compactMap { request -> String? in
                    guard
                        let params = request["params"] as? [Any],
                        let call = params.first as? [String: Any]
                    else {
                        return nil
                    }
                    return call["data"] as? String
                })
                #expect(
                    selectors == ["0x06fdde03", "0x95d89b41", "0x313ce567"]
                )
                return (
                    response,
                    HTTPURLResponse(
                        url: endpoint,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )
        let network = try #require(
            ReceiveNetworkCatalog.network(for: TronConstants.networkID)
        )
        let token = try await TronAPIClient(transport: transport).lookupToken(
            network: network,
            contractAddress: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
        )

        #expect(token.name == "Tether USD")
        #expect(token.symbol == "USDT")
        #expect(token.decimals == 6)
    }

    @Test
    func convertsChecksummedTronAccountToPrefixedHexAddress() {
        let hexAddress = TronValueParser.accountHexAddress(
            Self.accountAddress
        )

        #expect(hexAddress?.count == 42)
        #expect(hexAddress?.hasPrefix("41") == true)
        #expect(
            hexAddress?
                .dropFirst(2)
                .allSatisfy(\.isHexDigit) == true
        )
        #expect(
            TronValueParser.accountHexAddress(
                "not-a-tron-account"
            ) == nil
        )
    }

    @Test
    func acceptsTheChecksummedMainnetRecipientFromTheReportedSendFailure() {
        #expect(
            TronValueParser.isValidMainnetAddress(
                Self.screenshotRecipient
            )
        )
        #expect(
            TronValueParser.accountHexAddress(
                Self.screenshotRecipient
            ) == "4193d205c6556c055eddaa206e44435ac4ce18ec9e"
        )
        #expect(
            SendAddressValidator.isValid(
                Self.screenshotRecipient,
                for: TronConstants.networkID
            )
        )
    }

    @Test
    func tronAddressValidationRequiresTheBase58CheckChecksum() {
        let checksumCorrupted = String(
            Self.screenshotRecipient.dropLast()
        ) + "5"

        #expect(
            !TronValueParser.isValidMainnetAddress(checksumCorrupted)
        )
        #expect(
            TronValueParser.accountHexAddress(checksumCorrupted) == nil
        )
    }

    @Test
    func tronAddressValidationNormalizesOnlySurroundingWhitespace() {
        #expect(
            TronValueParser.accountHexAddress(
                " \n\(Self.screenshotRecipient)\t"
            ) == "4193d205c6556c055eddaa206e44435ac4ce18ec9e"
        )
        #expect(
            !TronValueParser.isValidMainnetAddress(
                "TPSovt4buv51PZXEN15zLosbk2ajEdW7G 4"
            )
        )
    }

    @Test
    func treatsOnlyTheExactUnactivatedAccountResponseAsEmptyHistory() {
        #expect(
            TronAPIClient.isUnactivatedAccountHistoryResponse(
                AnkrAPIError.httpFailure(
                    statusCode: 400,
                    message: "A valid account address is required."
                )
            )
        )
        #expect(
            !TronAPIClient.isUnactivatedAccountHistoryResponse(
                AnkrAPIError.httpFailure(
                    statusCode: 400,
                    message: "invalid_query"
                )
            )
        )
        #expect(
            !TronAPIClient.isUnactivatedAccountHistoryResponse(
                AnkrAPIError.httpFailure(
                    statusCode: 429,
                    message: "A valid account address is required."
                )
            )
        )
    }

    @Test
    func parsesCompleteUInt256DomainWithoutRounding() throws {
        #expect(
            try TronUInt256(hexQuantity: "0x0").decimalText == "0"
        )
        #expect(
            try TronUInt256(hexQuantity: "0X000f").decimalText == "15"
        )
        #expect(
            try TronUInt256(
                hexQuantity: "0x\(Self.maximumHex)"
            ).decimalText == Self.maximum
        )
        #expect(
            try TronUInt256(
                decimalText: "000\(Self.maximum)"
            ).decimalText == Self.maximum
        )
    }

    @Test
    func rejectsMalformedAndOutOfRangeQuantities() {
        #expect(throws: TronUInt256Error.self) {
            try TronUInt256(hexQuantity: "")
        }
        #expect(throws: TronUInt256Error.self) {
            try TronUInt256(hexQuantity: "0x")
        }
        #expect(throws: TronUInt256Error.self) {
            try TronUInt256(hexQuantity: "0x12xz")
        }
        #expect(throws: TronUInt256Error.self) {
            try TronUInt256(
                hexQuantity: "0x1\(String(repeating: "0", count: 64))"
            )
        }
        #expect(throws: TronUInt256Error.self) {
            try TronUInt256(decimalText: Self.overflow)
        }
        #expect(throws: TronUInt256Error.self) {
            try TronUInt256(decimalText: "-1")
        }
        #expect(throws: TronUInt256Error.self) {
            try TronUInt256(decimalText: " 1")
        }
    }

    @Test
    func scalesAtomicTextByDecimalPointPlacement() throws {
        let maximum = try TronUInt256(decimalText: Self.maximum)
        #expect(
            try maximum.userUnits(decimals: 6)
                == Self.maximumWithSixDecimals
        )
        #expect(
            try TronUInt256(decimalText: "1000000")
                .userUnits(decimals: 6) == "1"
        )
        #expect(
            try TronUInt256(decimalText: "1000001")
                .userUnits(decimals: 6) == "1.000001"
        )
        #expect(
            try TronUInt256(decimalText: "1")
                .userUnits(decimals: 6) == "0.000001"
        )
        #expect(
            try TronUInt256(decimalText: "1")
                .userUnits(decimals: 255)
                == "0.\(String(repeating: "0", count: 254))1"
        )
        #expect(throws: TronUInt256Error.self) {
            try maximum.userUnits(decimals: -1)
        }
        #expect(throws: TronUInt256Error.self) {
            try maximum.userUnits(decimals: 256)
        }
    }

    @Test
    func mapsTronGridHistoryWithoutFoundationDecimal() throws {
        let transfer = TronGridTokenTransfer(
            transactionID: "uint256-history-transaction",
            tokenInfo: TronGridTokenTransfer.TokenInfo(
                symbol: "MAX",
                address: Self.contractAddress,
                decimals: 6,
                name: "Maximum Token"
            ),
            blockTimestamp: 1_725_000_000_000,
            from: Self.senderAddress,
            to: Self.accountAddress,
            type: "Transfer",
            value: Self.maximum
        )

        let items = try TronHistoryMapper.tokenTransfers(
            from: [transfer]
        )
        let item = try #require(items.first)

        #expect(items.count == 1)
        #expect(item.rawAmount == Self.maximum)
        #expect(item.amountText == Self.maximumWithSixDecimals)
        #expect(item.decimals == 6)
    }

    @Test
    func malformedTronGridTokenMetadataIsDroppedAtBoundary()
        throws
    {
        let data = Data(
            """
            {
              "transaction_id": "malformed-token-metadata",
              "token_info": {},
              "block_timestamp": 1725000000000,
              "from": "\(Self.senderAddress)",
              "to": "\(Self.accountAddress)",
              "type": "Transfer",
              "value": "1"
            }
            """.utf8
        )
        let transfer = try JSONDecoder().decode(
            TronGridTokenTransfer.self,
            from: data
        )

        #expect(
            try TronHistoryMapper.tokenTransfers(from: [transfer])
                .isEmpty
        )
    }

    @Test
    func invalidTronGridContractIsNotPromotedToBalanceQuery()
        throws
    {
        let transfer = TronGridTokenTransfer(
            transactionID: "invalid-contract-history",
            tokenInfo: TronGridTokenTransfer.TokenInfo(
                symbol: "BAD",
                address: "not-a-tron-contract",
                decimals: 6,
                name: "Invalid Contract"
            ),
            blockTimestamp: 1_725_000_000_000,
            from: Self.senderAddress,
            to: Self.accountAddress,
            type: "Transfer",
            value: "1"
        )

        #expect(
            try TronHistoryMapper.tokenTransfers(from: [transfer])
                .isEmpty
        )
    }

    @Test
    func rejectsOutOfRangeTronGridHistoryInsteadOfDroppingIt() {
        let transfer = TronGridTokenTransfer(
            transactionID: "overflow-history-transaction",
            tokenInfo: TronGridTokenTransfer.TokenInfo(
                symbol: "MAX",
                address: Self.contractAddress,
                decimals: 6,
                name: "Maximum Token"
            ),
            blockTimestamp: 1_725_000_000_000,
            from: Self.senderAddress,
            to: Self.accountAddress,
            type: "transfer",
            value: Self.overflow
        )

        #expect(throws: TronUInt256Error.self) {
            try TronHistoryMapper.tokenTransfers(from: [transfer])
        }
    }

    @Test
    func persistsBalanceAndHistoryQuantitiesLosslessly() async throws {
        let database = try WalletDatabase.temporary()
        try await seedWallet(database)
        let amountText = try TronUInt256(decimalText: Self.maximum)
            .userUnits(decimals: 6)
        let transactionID = "uint256-persistence-transaction"
        let accountID = "\(Self.walletID):tron:0"
        let assetID = "tron:\(Self.contractAddress)"
        let recordID = "\(accountID):\(transactionID):\(assetID)"
        let snapshot = TronWalletSnapshot(
            material: TronAccountMaterial(
                address: Self.accountAddress,
                hexAddress:
                    "0x1111111111111111111111111111111111111111",
                publicKey: "uint256-test-public-key"
            ),
            trxBalance: 0,
            tokens: [
                TronTokenBalance(
                    identity: Self.contractAddress,
                    type: "trc20",
                    name: "Maximum Token",
                    symbol: "MAX",
                    decimals: 6,
                    amountText: amountText,
                    rawAmount: Self.maximum
                )
            ],
            history: [
                TronHistoryItem(
                    transactionID: transactionID,
                    timestamp: 1_725_000_000,
                    blockNumber: 64,
                    from: Self.senderAddress,
                    to: Self.accountAddress,
                    amountText: amountText,
                    rawAmount: Self.maximum,
                    assetIdentity: Self.contractAddress,
                    assetSymbol: "MAX",
                    assetName: "Maximum Token",
                    decimals: 6,
                    fee: nil,
                    failed: false
                )
            ],
            queriedTRC20Identities: [Self.contractAddress]
        )

        try await database.saveTronSnapshot(
            snapshot,
            walletID: Self.walletID,
            resolvedPrices: [assetID: 1]
        )

        let stored = try await database.pool.read { database in
            (
                holding: try DBAccountAssetRecord.fetchOne(
                    database,
                    key: [
                        "accountID": accountID,
                        "assetID": assetID
                    ]
                ),
                transaction: try DBTransactionRecord.fetchOne(
                    database,
                    key: recordID
                ),
                transfer: try DBTransactionTransferRecord.fetchOne(
                    database,
                    key: "\(recordID)|primary"
                )
            )
        }
        let holding = try #require(stored.holding)
        let transaction = try #require(stored.transaction)
        let transfer = try #require(stored.transfer)

        #expect(holding.balance == Self.maximumWithSixDecimals)
        #expect(holding.balanceAtomic == Self.maximum)
        #expect(transaction.assetAmount == Self.maximumWithSixDecimals)
        #expect(transfer.amount == Self.maximumWithSixDecimals)
        #expect(transfer.amountAtomic == Self.maximum)

        let cached = try #require(
            try await database.cachedWalletSnapshot(walletID: Self.walletID)
        )
        let cachedAsset = try #require(
            cached.assets.first { $0.id == assetID }
        )
        let cachedTransaction = try #require(
            cached.transactions.first { $0.id == recordID }
        )
        #expect(cachedAsset.balanceText == Self.maximumWithSixDecimals)
        #expect(cachedAsset.displayBalanceText == Self.maximumWithSixDecimals)
        #expect(
            cachedTransaction.assetAmountText
                == Self.maximumWithSixDecimals
        )
        #expect(
            cachedTransaction.displayAssetAmountText
                == "+\(Self.maximumWithSixDecimals)"
        )
    }

    @Test
    func cachedSnapshotRetainsAmountBelowDecimalExponentRange() async throws {
        let database = try WalletDatabase.temporary()
        try await seedWallet(database)
        let decimals = 255
        let amountText = try TronUInt256(decimalText: "1")
            .userUnits(decimals: decimals)
        let assetID = "tron:\(Self.contractAddress)"
        let snapshot = TronWalletSnapshot(
            material: TronAccountMaterial(
                address: Self.accountAddress,
                hexAddress:
                    "0x1111111111111111111111111111111111111111",
                publicKey: "uint256-test-public-key"
            ),
            trxBalance: 0,
            tokens: [
                TronTokenBalance(
                    identity: Self.contractAddress,
                    type: "trc20",
                    name: "Tiny Token",
                    symbol: "TINY",
                    decimals: decimals,
                    amountText: amountText,
                    rawAmount: "1"
                )
            ],
            history: [],
            queriedTRC20Identities: [Self.contractAddress]
        )

        try await database.saveTronSnapshot(
            snapshot,
            walletID: Self.walletID,
            resolvedPrices: [:]
        )

        let cached = try #require(
            try await database.cachedWalletSnapshot(walletID: Self.walletID)
        )
        let asset = try #require(
            cached.assets.first { $0.id == assetID }
        )
        #expect(asset.balance == 0)
        #expect(asset.balanceText == amountText)
        #expect(asset.balanceAtomic == "1")
        #expect(asset.displayBalanceText == amountText)
    }

    private func seedWallet(_ walletDatabase: WalletDatabase) async throws {
        try await walletDatabase.pool.write { database in
            let now = Date().timeIntervalSince1970
            try DBWalletRecord(
                id: Self.walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Uint256 Test Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: nil,
                isSelected: false,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: nil,
                archivedAt: nil
            ).insert(database)
            try DBWalletAccountRecord(
                id: "\(Self.walletID):tron:0",
                walletID: Self.walletID,
                networkID: TronConstants.networkID,
                address: Self.accountAddress,
                normalizedAddress: Self.accountAddress,
                label: nil,
                derivationPath: nil,
                accountIndex: 0,
                publicKey: "uint256-test-public-key",
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(database)
        }
    }
}

@Suite(.serialized)
struct CustomNonEVMTokenPersistenceTests {
    private let walletID = "custom-non-evm-token-wallet"
    private let solanaMint =
        "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    private let tronContract =
        "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"

    @Test
    func savesPinnedSolanaAndTronTokensForAuthoritativeSync()
        async throws
    {
        let database = try WalletDatabase.temporary()
        try await seedSelectedWallet(database)
        let now = Date().timeIntervalSince1970
        let solanaNetwork = try #require(
            ReceiveNetworkCatalog.network(for: SolanaConstants.networkID)
        )
        let tronNetwork = try #require(
            ReceiveNetworkCatalog.network(for: TronConstants.networkID)
        )
        let solana = CustomSolanaToken(
            network: solanaNetwork,
            mintAddress: solanaMint,
            name: "USD Coin",
            symbol: "USDC",
            decimals: 6,
            logoSource: .unavailable,
            eligibility: SolanaTokenEligibility(
                mint: solanaMint,
                name: "USD Coin",
                symbol: "USDC",
                decimals: 6,
                isVerified: true,
                liquidityUSD: 1,
                isSuspicious: false,
                reason: .eligible,
                provider: SolanaTokenEligibilityClient.providerIdentifier,
                observedAt: now,
                expiresAt: now + 3_600
            )
        )
        let tron = CustomTronToken(
            network: tronNetwork,
            contractAddress: tronContract,
            name: "Tether USD",
            symbol: "USDT",
            decimals: 6,
            logoSource: .unavailable
        )

        let savedSolana = try await database.saveCustomToken(.solana(solana))
        let savedTron = try await database.saveCustomToken(.tron(tron))
        let solanaMaterial = SolanaAccountMaterial(
            kind: .phantom,
            address: solanaMint,
            publicKey: "solana-public-key",
            derivationPath: SolanaDerivationKind.phantom.derivationPath
        )
        let solanaSnapshot = try SolanaWalletSnapshot(
            accounts: SolanaAccountSet(
                primary: solanaMaterial,
                alternatives: []
            ),
            addressSnapshots: [
                SolanaAddressSnapshot(
                    material: solanaMaterial,
                    solBalance: 0,
                    solAtomicBalance: "0",
                    tokenBalances: [
                        SolanaTokenBalance(
                            mint: solanaMint,
                            tokenAccountAddresses: ["token-account"],
                            name: "USD Coin",
                            symbol: "USDC",
                            decimals: 6,
                            amount: 1,
                            atomicAmount: "1000000",
                            catalogRank: nil
                        )
                    ],
                    balanceAuthority: .complete
                )
            ],
            history: [],
            historyCursors: []
        )
        try await database.saveSolanaSnapshot(
            solanaSnapshot,
            walletID: walletID,
            eligibilityByMint: [solanaMint: solana.eligibility],
            resolvedPriceByIDOverride: [:]
        )
        let solanaAccountID = WalletDatabase.solanaAccountID(
            walletID: walletID,
            kind: .phantom
        )
        let stored = try await database.pool.read { database in
            (
                solanaHolding: try DBAccountAssetRecord.fetchOne(
                    database,
                    key: [
                        "accountID": solanaAccountID,
                        "assetID": savedSolana.id
                    ]
                ),
                tronHolding: try DBAccountAssetRecord.fetchOne(
                    database,
                    key: [
                        "accountID": "\(walletID):tron:0",
                        "assetID": savedTron.id
                    ]
                ),
                eligibility: try DBSolanaTokenEligibilityRecord.fetchOne(
                    database,
                    key: solanaMint
                )
            )
        }
        let trackedTron = try await database.trackedTronTokens(
            walletID: walletID
        )

        #expect(savedSolana.id == "solana:\(solanaMint)")
        #expect(savedTron.id == "tron:\(tronContract)")
        #expect(stored.solanaHolding?.isPinned == true)
        #expect(stored.solanaHolding?.balanceAtomic == "1000000")
        #expect(stored.tronHolding?.isPinned == true)
        #expect(stored.tronHolding?.balanceAtomic == "0")
        #expect(stored.eligibility?.isEligible == true)
        #expect(trackedTron.map(\.identity) == [tronContract])
    }

    private func seedSelectedWallet(
        _ walletDatabase: WalletDatabase
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await walletDatabase.pool.write { database in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Custom Token Fixture",
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
                id: WalletDatabase.solanaAccountID(
                    walletID: walletID,
                    kind: .phantom
                ),
                walletID: walletID,
                networkID: SolanaConstants.networkID,
                address: solanaMint,
                normalizedAddress: solanaMint,
                label: SolanaDerivationKind.phantom.rawValue,
                derivationPath: SolanaDerivationKind.phantom.derivationPath,
                accountIndex: 0,
                publicKey: "solana-public-key",
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(database)
            let tronAddress = "TQn9Y2khEsLJW1ChVWFMSMeRDow5KcbLSE"
            try DBWalletAccountRecord(
                id: "\(walletID):tron:0",
                walletID: walletID,
                networkID: TronConstants.networkID,
                address: tronAddress,
                normalizedAddress: tronAddress,
                label: nil,
                derivationPath: nil,
                accountIndex: 0,
                publicKey: "tron-public-key",
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(database)
        }
    }
}
