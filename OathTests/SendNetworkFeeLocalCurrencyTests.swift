import Foundation
import GRDB
import Testing
import WalletCore
@testable import Aperture

struct SendNetworkFeeLocalCurrencyTests {
    @Test
    func customFeeFeedbackReportsBalanceShareAndThresholdsLosslessly()
        throws
    {
        let ordinary = try #require(
            SendCustomNetworkFeeEntryFeedback(
                input: "50",
                availableLocalBalance: 100,
                fastestLocalAmount: 20
            )
        )
        #expect(ordinary.balancePercentage == 50)
        #expect(ordinary.fastestMultiple == Decimal(string: "2.5"))
        #expect(!ordinary.exceedsAvailableBalance)
        #expect(!ordinary.exceedsHighFeeThreshold)

        let high = try #require(
            SendCustomNetworkFeeEntryFeedback(
                input: "30.00000001",
                availableLocalBalance: 100,
                fastestLocalAmount: 10
            )
        )
        #expect(high.exceedsHighFeeThreshold)
        #expect(!high.exceedsAvailableBalance)

        let unaffordable = try #require(
            SendCustomNetworkFeeEntryFeedback(
                input: "100.00000001",
                availableLocalBalance: 100,
                fastestLocalAmount: 10
            )
        )
        #expect(unaffordable.exceedsAvailableBalance)
        #expect(unaffordable.balancePercentage == Decimal(string: "100.00000001"))

        let noBalance = try #require(
            SendCustomNetworkFeeEntryFeedback(
                input: "0.01",
                availableLocalBalance: 0,
                fastestLocalAmount: 0.001
            )
        )
        #expect(noBalance.exceedsAvailableBalance)
        #expect(noBalance.balancePercentage == nil)
    }

    @Test
    func HTTPAPICoinPerKilobyteConversionIsLosslessAndRoundsUp()
        throws
    {
        #expect(
            try SendBitcoinFamilyHTTPAPIClient.atomicPerVByte(
                coinPerKilobyte: try Self.decimal("0.50451795")
            ) == 50_452
        )
        #expect(
            try SendBitcoinFamilyHTTPAPIClient.atomicPerVByte(
                coinPerKilobyte: try Self.decimal("0.00802253")
            ) == 803
        )
        #expect(throws: SendNetworkFeeAPIError.self) {
            try SendBitcoinFamilyHTTPAPIClient.atomicPerVByte(
                coinPerKilobyte: 0
            )
        }
    }

    @Test
    func dogecoinFeeIsAvailableBeforeAnAmountOrUTXOPlanExists()
        throws
    {
        let draft = try Self.draft(
            networkID: BitcoinFamilyChain.dogecoin.networkID,
            amount: nil
        )
        let estimate = try SendNetworkFeeEstimator.templateEstimate(
            draft: draft,
            fee: SendResolvedNetworkFee(
                model: .utxoPerVByte,
                primaryValue: "50452",
                secondaryValue: nil
            )
        )

        #expect(estimate.atomicAmount == "11402152")
        #expect(estimate.nativeDecimals == 8)
        switch estimate.source {
        case .transactionTemplate:
            break
        case .exact:
            Issue.record("Expected the pre-amount Dogecoin template.")
        }
    }

    @Test
    func localDogecoinFeeRoundTripsToItsExactRate() throws {
        let context = WalletCurrencyContext(
            code: "USD",
            ratePerUSD: 1
        )
        let target = try SendNetworkFeeCustomLocalConverter
            .targetAtomicAmount(
                from: "0.02850538",
                nativeDecimals: 8,
                nativeUnitUSDPrice: try Self.decimal("0.25"),
                currency: context
            )
        let custom = try SendNetworkFeeCustomLocalConverter.customValue(
            targetAtomicAmount: target,
            model: .utxoPerVByte,
            basis: .linear(units: 226, minimumRate: 1_000)
        )

        #expect(target == "11402152")
        #expect(custom.primaryValue == "50452")
        #expect(custom.secondaryValue == nil)
        #expect(custom.totalBudgetAtomic == target)
    }

    @Test
    func indivisibleCustomTotalNeverRoundsIntoALargerFee() throws {
        let custom = try SendNetworkFeeCustomLocalConverter.customValue(
            targetAtomicAmount: "1000",
            model: .utxoPerVByte,
            basis: .linear(units: 3, minimumRate: 1)
        )

        #expect(custom.primaryValue == "333")
        #expect(custom.totalBudgetAtomic == "1000")
        #expect(
            try SendAtomicAmount.multiply(
                custom.primaryValue,
                by: 3
            ) == "999"
        )

        let estimate = try SendNetworkFeeEstimator.templateEstimate(
            draft: try Self.draft(
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                amount: "0.001"
            ),
            fee: SendResolvedNetworkFee(
                model: .utxoPerVByte,
                primaryValue: custom.primaryValue,
                secondaryValue: nil,
                totalBudgetAtomic: custom.totalBudgetAtomic
            )
        )
        #expect(estimate.atomicAmount == "1000")
    }

    @Test
    func localCurrencyConversionRoundsDownToTheUserBudget() throws {
        let target = try SendNetworkFeeCustomLocalConverter
            .targetAtomicAmount(
                from: "1",
                nativeDecimals: 2,
                nativeUnitUSDPrice: 3,
                currency: WalletCurrencyContext(
                    code: "USD",
                    ratePerUSD: 1
                )
            )

        #expect(target == "33")
    }

    @Test
    func customDogecoinFeeCannotUndercutTheNetworkMinimum() throws {
        let target = try SendNetworkFeeCustomLocalConverter
            .targetAtomicAmount(
                from: "0.00000001",
                nativeDecimals: 8,
                nativeUnitUSDPrice: 1,
                currency: WalletCurrencyContext(
                    code: "USD",
                    ratePerUSD: 1
                )
            )

        #expect(throws: SendNetworkFeeInputError.belowNetworkMinimum) {
            try SendNetworkFeeCustomLocalConverter.customValue(
                targetAtomicAmount: target,
                model: .utxoPerVByte,
                basis: .linear(units: 226, minimumRate: 1_000)
            )
        }
    }

    @Test
    func everyCustomFeeFamilyRejectsATotalBelowItsNetworkMinimum()
        throws
    {
        #expect(throws: SendNetworkFeeInputError.belowNetworkMinimum) {
            try SendNetworkFeeCustomLocalConverter.customValue(
                targetAtomicAmount: "225",
                model: .utxoPerVByte,
                basis: .linear(units: 226, minimumRate: 1)
            )
        }
        #expect(throws: SendNetworkFeeInputError.belowNetworkMinimum) {
            try SendNetworkFeeCustomLocalConverter.customValue(
                targetAtomicAmount: "20",
                model: .evmLegacy,
                basis: .linear(units: 21_000, minimumRate: 2)
            )
        }
        #expect(throws: SendNetworkFeeInputError.belowNetworkMinimum) {
            try SendNetworkFeeCustomLocalConverter.customValue(
                targetAtomicAmount: "41999",
                model: .evmEIP1559,
                basis: .eip1559(
                    units: 21_000,
                    minimumRate: 2,
                    suggestedPriorityRate: "1"
                )
            )
        }
        #expect(throws: SendNetworkFeeInputError.belowNetworkMinimum) {
            try SendNetworkFeeCustomLocalConverter.customValue(
                targetAtomicAmount: "4999",
                model: .solanaPriority,
                basis: .solana(
                    computeUnits: 200_000,
                    baseAtomic: 5_000
                )
            )
        }
        #expect(throws: SendNetworkFeeInputError.belowNetworkMinimum) {
            try SendNetworkFeeCustomLocalConverter.customValue(
                targetAtomicAmount: "999999",
                model: .tronFeeLimit,
                basis: .direct(minimumAtomic: "1000000")
            )
        }
    }

    @Test
    func finalBitcoinFamilyBuilderRejectsRatesBelowProtocolMinimum()
        throws
    {
        let belowBitcoin = SendResolvedNetworkFee(
            model: .utxoPerVByte,
            primaryValue: "0",
            secondaryValue: nil
        )
        let belowDogecoin = SendResolvedNetworkFee(
            model: .utxoPerVByte,
            primaryValue: "999",
            secondaryValue: nil
        )
        let validDogecoin = SendResolvedNetworkFee(
            model: .utxoPerVByte,
            primaryValue: "1000",
            secondaryValue: nil
        )

        #expect(throws: SendTransactionSubmissionError.self) {
            try SendBitcoinTransactionService.validatedByteFee(
                belowBitcoin,
                networkID: BitcoinFamilyChain.bitcoin.networkID
            )
        }
        #expect(throws: SendTransactionSubmissionError.self) {
            try SendBitcoinTransactionService.validatedByteFee(
                belowDogecoin,
                networkID: BitcoinFamilyChain.dogecoin.networkID
            )
        }
        #expect(
            try SendBitcoinTransactionService.validatedByteFee(
                validDogecoin,
                networkID: BitcoinFamilyChain.dogecoin.networkID
            ) == 1_000
        )
    }

    @Test
    func finalBuildersNeverExceedTheCustomTotalBudget() throws {
        let fee = SendResolvedNetworkFee(
            model: .utxoPerVByte,
            primaryValue: "1",
            secondaryValue: nil,
            totalBudgetAtomic: "100"
        )
        let ordinaryPlan = BitcoinTransactionPlan.with {
            $0.availableAmount = 1_000
            $0.amount = 500
            $0.fee = 10
            $0.change = 490
        }
        let ordinary = try SendBitcoinTransactionService
            .applyingCustomFeeBudget(
                fee,
                to: ordinaryPlan,
                usesMaximumBalance: false
            )
        #expect(ordinary.amount == 500)
        #expect(ordinary.fee == 100)
        #expect(ordinary.change == 400)

        let maximumPlan = BitcoinTransactionPlan.with {
            $0.availableAmount = 1_000
            $0.amount = 990
            $0.fee = 10
            $0.change = 0
        }
        let maximum = try SendBitcoinTransactionService
            .applyingCustomFeeBudget(
                fee,
                to: maximumPlan,
                usesMaximumBalance: true
            )
        #expect(maximum.amount == 900)
        #expect(maximum.fee == 100)
        #expect(maximum.change == 0)

        let insufficient = SendResolvedNetworkFee(
            model: .utxoPerVByte,
            primaryValue: "1",
            secondaryValue: nil,
            totalBudgetAtomic: "9"
        )
        #expect(throws: SendTransactionSubmissionError.self) {
            try SendBitcoinTransactionService.applyingCustomFeeBudget(
                insufficient,
                to: ordinaryPlan,
                usesMaximumBalance: false
            )
        }

        let capped = SendResolvedNetworkFee(
            model: .evmLegacy,
            primaryValue: "1",
            secondaryValue: nil,
            totalBudgetAtomic: "100"
        )
        try SendEVMTransactionService.validateCustomFeeBudget(
            capped,
            maximumFeeAtomic: "100"
        )
        #expect(throws: SendTransactionSubmissionError.self) {
            try SendEVMTransactionService.validateCustomFeeBudget(
                capped,
                maximumFeeAtomic: "101"
            )
        }
        try SendSolanaTransactionService.validateCustomFeeBudget(
            capped,
            networkFeeAtomic: 100
        )
        #expect(throws: SendTransactionSubmissionError.self) {
            try SendSolanaTransactionService.validateCustomFeeBudget(
                capped,
                networkFeeAtomic: 101
            )
        }
        try SendTronTransactionService.validateCustomFeeBudget(
            capped,
            estimatedFeeAtomic: 100
        )
        #expect(throws: SendTransactionSubmissionError.self) {
            try SendTronTransactionService.validateCustomFeeBudget(
                capped,
                estimatedFeeAtomic: 101
            )
        }
    }

    @Test
    func localSolanaTotalSubtractsBaseFeeBeforeSettingPriority()
        throws
    {
        let target = try SendNetworkFeeCustomLocalConverter
            .targetAtomicAmount(
                from: "0.001",
                nativeDecimals: 9,
                nativeUnitUSDPrice: 100,
                currency: WalletCurrencyContext(
                    code: "USD",
                    ratePerUSD: 1
                )
            )
        let custom = try SendNetworkFeeCustomLocalConverter.customValue(
            targetAtomicAmount: target,
            model: .solanaPriority,
            basis: .solana(
                computeUnits: 200_000,
                baseAtomic: 5_000
            )
        )

        #expect(target == "10000")
        #expect(custom.primaryValue == "25000")
        #expect(custom.totalBudgetAtomic == target)
    }

    @Test
    func localEIP1559TotalKeepsPriorityBoundedByMaximumFee()
        throws
    {
        let custom = try SendNetworkFeeCustomLocalConverter.customValue(
            targetAtomicAmount: "1000",
            model: .evmEIP1559,
            basis: .eip1559(
                units: 10,
                minimumRate: 1,
                suggestedPriorityRate: "20"
            )
        )
        let capped = try SendNetworkFeeCustomLocalConverter.customValue(
            targetAtomicAmount: "100",
            model: .evmEIP1559,
            basis: .eip1559(
                units: 10,
                minimumRate: 1,
                suggestedPriorityRate: "20"
            )
        )

        #expect(custom.primaryValue == "100")
        #expect(custom.secondaryValue == "20")
        #expect(capped.primaryValue == "10")
        #expect(capped.secondaryValue == "10")
    }

    @Test
    func everySupportedMainnetHasAPositivePreAmountLocalFeeBasis()
        throws
    {
        for networkID in SendNetworkFeeAPIClient
            .supportedQuoteNetworkIDs.sorted() {
            let quote = try SendNetworkFeeAPIClient.defaultQuote(
                for: networkID
            )
            let draft = try Self.draft(
                networkID: networkID,
                amount: nil
            )
            for preset in [
                SendNetworkFeePreset.fastest,
                .standard,
                .economy
            ] {
                let tier = try #require(quote.tier(for: preset))
                let estimate = try SendNetworkFeeEstimator
                    .templateEstimate(
                        draft: draft,
                        fee: SendResolvedNetworkFee(
                            model: tier.model,
                            primaryValue: tier.primaryValue,
                            secondaryValue: tier.secondaryValue
                        )
                    )
                #expect(
                    SendAtomicAmount.isCanonical(estimate.atomicAmount),
                    "Invalid template fee for \(networkID)."
                )
                #expect(
                    estimate.atomicAmount != "0",
                    "Zero template fee for \(networkID)."
                )
                #expect(
                    estimate.usdValue(unitUSDPrice: 1) ?? 0 > 0,
                    "No local fee value for \(networkID)."
                )
            }
        }
    }

    @Test
    func silentPaymentFeeEstimateLoadsTheBoundHDWalletInsteadOfOneAddress()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let walletID = UUID().uuidString.lowercased()
        let credential = try WalletRecoveryCredential(
            mnemonic:
                "abandon abandon abandon abandon abandon abandon "
                + "abandon abandon abandon abandon abandon about"
        )
        let wallet = try #require(credential.makeHDWallet())
        let owner = try BitcoinHDDerivationService().deriveAddress(
            wallet: wallet,
            addressType: .bip84,
            branch: .external,
            index: 7
        )
        let currentAccountOwner = try BitcoinHDDerivationService()
            .deriveAddress(
                wallet: wallet,
                addressType: .bip84,
                branch: .external,
                index: 8
            )
        let descriptor = try #require(
            BitcoinHDDerivationService()
                .accountDescriptors(wallet: wallet)
                .first { $0.addressType == .bip84 }
        )
        let now = Date().timeIntervalSince1970
        try await database.pool.write { rawDatabase in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Silent Payment Fee Test",
                kind: DatabaseWalletKind.importedRecoveryPhrase.rawValue,
                secretKeyReference: nil,
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil
            ).insert(rawDatabase)
            try DBWalletAccountRecord(
                id: "\(walletID):bitcoin:0",
                walletID: walletID,
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                address: currentAccountOwner.address,
                normalizedAddress: currentAccountOwner.address.lowercased(),
                label: nil,
                derivationPath: currentAccountOwner.derivationPath,
                accountIndex: 0,
                publicKey: currentAccountOwner.publicKey.hexString,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(rawDatabase)
            try DBBitcoinHDAccountRecord(
                walletID: walletID,
                addressType: descriptor.addressType.rawValue,
                accountIndex: descriptor.accountIndex,
                accountPath: descriptor.accountPath,
                extendedPublicKey: descriptor.extendedPublicKey,
                createdAt: now,
                updatedAt: now
            ).insert(rawDatabase)
            try DBBitcoinHDAddressRecord(
                walletID: walletID,
                addressType: owner.addressType.rawValue,
                accountIndex: 0,
                branch: owner.branch.rawValue,
                addressIndex: owner.index,
                derivationPath: owner.derivationPath,
                address: owner.address,
                publicKey: owner.publicKey,
                scriptPubKey: owner.scriptPubKey,
                scriptHash: owner.scriptHash,
                isUsed: true,
                isReserved: false,
                confirmedBalanceAtomic: "50000",
                unconfirmedBalanceAtomic: "0",
                lastCheckedAt: now,
                createdAt: now,
                updatedAt: now
            ).insert(rawDatabase)
        }

        let output = SendBitcoinUTXO(
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            outpoint: SendBitcoinOutpoint(
                transactionHash: String(repeating: "11", count: 32),
                outputIndex: 0
            ),
            valueAtomic: "50000",
            blockHeight: 800_000,
            confirmations: 10,
            owner: owner
        )
        let probe = BitcoinFeeOutputLoaderProbe()
        let estimator = SendNetworkFeeEstimator(
            database: database,
            bitcoinOutputLoader: {
                chain,
                accountAddress,
                loadedWalletID,
                minimumExpectedValue,
                requiredOutpointIDs in
                await probe.record(
                    chain: chain,
                    accountAddress: accountAddress,
                    walletID: loadedWalletID,
                    minimumExpectedValue: minimumExpectedValue,
                    requiredOutpointIDs: requiredOutpointIDs
                )
                return [output]
            }
        )
        let silentAddress =
            "sp1qqvtmgkffyptnzpksadwgy9cnzmav6lj6ut5ukvqsfyg02ca3nupkcq3euzr"
            + "jdat44jmvsdnvefurd8vpwxrgyln0z37tlljsfqllt7w7kcq6mng2"
        let draft = SendDraft(
            request: .manualEntry(
                networkID: BitcoinFamilyChain.bitcoin.networkID
            ),
            asset: SendAssetChoice(
                id: "bitcoin:native",
                name: "Bitcoin",
                symbol: "BTC",
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                networkName: "Bitcoin",
                blockchain: .bitcoin,
                contractAddress: nil,
                decimals: 8,
                logoSource: .nativeCoin(blockchain: .bitcoin),
                networkLogoSource: .nativeCoin(blockchain: .bitcoin),
                balance: 0.0005,
                fiatValue: 5,
                balanceAtomic: "50000",
                sourceAddress: owner.address
            ),
            recipient: silentAddress,
            amount: "0.0001",
            note: nil
        )
        let estimate = try await estimator.estimate(
            draft: draft,
            fee: SendResolvedNetworkFee(
                model: .utxoPerVByte,
                primaryValue: "2",
                secondaryValue: nil
            )
        )
        let request = await probe.request()

        #expect(Int64(estimate.atomicAmount) ?? 0 > 0)
        #expect(request?.chain == .bitcoin)
        #expect(request?.accountAddress == currentAccountOwner.address)
        #expect(request?.walletID == walletID)
        #expect(request?.minimumExpectedValue == "50000")
        #expect(request?.requiredOutpointIDs.isEmpty == true)

        // A custom total used to return immediately without loading any UTXOs.
        // Verify the actual estimator rejects an inadequate saved budget, then
        // sign the sufficient budget using the same mainnet fixture inputs.
        let insufficient = SendResolvedNetworkFee(model: .utxoPerVByte,
            primaryValue: "5", secondaryValue: nil, totalBudgetAtomic: "1")
        await #expect(throws: SendTransactionSubmissionError.feeQuoteUnavailable("custom_fee_budget_below_required")) {
            try await estimator.estimate(draft: draft, fee: insufficient)
        }
        let sufficient = SendResolvedNetworkFee(model: .utxoPerVByte,
            primaryValue: "5", secondaryValue: nil, totalBudgetAtomic: "2000")
        let verified = try await estimator.estimate(draft: draft, fee: sufficient)
        #expect(verified.atomicAmount == "2000")
        guard case .exact = verified.source else {
            Issue.record("A custom UTXO budget requires a real plan")
            return
        }
        let signed = try BitcoinSilentPaymentTransactionSigner.sign(
            draft: draft, credential: credential, outputs: [output],
            silentPaymentPrivateKeys: [:], requestedAtomic: 10_000, byteFee: 5,
            fee: sufficient, options: draft.bitcoinFamilyOptions,
            changeAddress: currentAccountOwner.address, recipientAddress: silentAddress
        )
        #expect(signed.feeAtomic == verified.atomicAmount)
        let finalized = try SendBitcoinNestedSegwitTransaction.finalize(
            encoded: signed.encoded, nestedPublicKeysByOutpointID: [:])
        #expect(try #require(Int64(signed.feeAtomic)) >= finalized.virtualSize * 5)
    }

    @Test
    func nearGasPriceReadFailsOverWithinTheFeeQuoteBudget()
        async throws
    {
        let slow = try #require(
            URL(string: "https://slow-near-fee.example.test")
        )
        let fast = try #require(
            URL(string: "https://fast-near-fee.example.test")
        )
        let probe = NEARGasPriceDeadlineProbe(
            slowHost: try #require(slow.host)
        )
        let transport = try NEARJSONRPCTransport(
            endpoints: [slow, fast],
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            try await probe.response(for: request)
        }
        let client = NEARAPIClient(transport: transport)

        let gasPrice = try await client.gasPrice()

        #expect(gasPrice == "200000000")
        #expect(await probe.requestedHosts() == [
            "slow-near-fee.example.test",
            "fast-near-fee.example.test"
        ])
    }

    private static func draft(
        networkID: String,
        amount: String?
    ) throws -> SendDraft {
        let network = ReceiveNetworkCatalog.all.first {
            $0.id == networkID
        }
        let bitcoinFamily = BitcoinFamilyChain(rawValue: networkID)
        let blockchain = try #require(
            network?.blockchain ?? bitcoinFamily?.blockchain
        )
        let quote = try SendNetworkFeeAPIClient.defaultQuote(
            for: networkID
        )
        let model = try #require(
            quote.tier(for: .fastest)?.model
        )
        return SendDraft(
            request: .manualEntry(networkID: networkID),
            asset: SendAssetChoice(
                id: "\(networkID):native",
                name: network?.localizedName
                    ?? bitcoinFamily?.name
                    ?? "Native Asset",
                symbol: network?.symbol
                    ?? bitcoinFamily?.symbol
                    ?? "COIN",
                networkID: networkID,
                networkName: network?.localizedName
                    ?? bitcoinFamily?.name
                    ?? "Mainnet",
                blockchain: blockchain,
                contractAddress: nil,
                decimals: SendNetworkFeeEstimator.nativeDecimals(
                    for: model
                ),
                logoSource: .nativeCoin(blockchain: blockchain),
                networkLogoSource: .network(blockchain: blockchain),
                balance: 1,
                fiatValue: 1,
                sourceAddress: bitcoinFamily == nil
                    ? nil : "source"
            ),
            recipient: bitcoinFamily == nil ? "recipient" : "destination",
            amount: amount,
            note: nil
        )
    }

    private static func decimal(_ value: String) throws -> Decimal {
        try #require(
            Decimal(
                string: value,
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
    }
}

private actor BitcoinFeeOutputLoaderProbe {
    struct Request: Sendable {
        let chain: BitcoinFamilyChain
        let accountAddress: String
        let walletID: String?
        let minimumExpectedValue: String
        let requiredOutpointIDs: Set<String>
    }

    private var recordedRequest: Request?

    func record(
        chain: BitcoinFamilyChain,
        accountAddress: String,
        walletID: String?,
        minimumExpectedValue: String,
        requiredOutpointIDs: Set<String>
    ) {
        recordedRequest = Request(
            chain: chain,
            accountAddress: accountAddress,
            walletID: walletID,
            minimumExpectedValue: minimumExpectedValue,
            requiredOutpointIDs: requiredOutpointIDs
        )
    }

    func request() -> Request? {
        recordedRequest
    }
}

private actor NEARGasPriceDeadlineProbe {
    private let slowHost: String
    private var hosts: [String] = []

    init(slowHost: String) {
        self.slowHost = slowHost
    }

    func response(for request: URLRequest) async throws
        -> (Data, URLResponse) {
        let host = request.url?.host ?? ""
        hosts.append(host)
        if host == slowHost {
            try await Task.sleep(for: .seconds(2))
        }
        let value = host == slowHost ? "100000000" : "200000000"
        let data = Data(
            """
            {"jsonrpc":"2.0","id":"aperture","result":{"gas_price":"\(value)"}}
            """.utf8
        )
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else { throw URLError(.badServerResponse) }
        return (data, response)
    }

    func requestedHosts() -> [String] {
        hosts
    }
}
