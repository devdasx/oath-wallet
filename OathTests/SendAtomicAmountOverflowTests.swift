import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct SendAtomicAmountOverflowTests {
    @Test
    func multiplicationRejectsEveryUInt64OverflowStage() throws {
        #expect(
            try SendAtomicAmount.multiply(
                "1",
                by: UInt64.max
            ) == String(UInt64.max)
        )
        #expect(
            throws: SendTransactionSubmissionError.amountOutOfRange
        ) {
            try SendAtomicAmount.multiply(
                "2",
                by: UInt64.max
            )
        }
        #expect(
            throws: SendTransactionSubmissionError.amountOutOfRange
        ) {
            try SendAtomicAmount.multiply(
                "99",
                by: UInt64.max / 9
            )
        }
        #expect(
            throws: SendTransactionSubmissionError.invalidAmount
        ) {
            try SendAtomicAmount.multiply(
                "1x",
                by: 21_000
            )
        }
        #expect(
            throws: SendTransactionSubmissionError.amountOutOfRange
        ) {
            try SendAtomicAmount.multiply(
                String(repeating: "9", count: 200),
                by: 10
            )
        }
    }

    @Test
    func evmMaximumFeeOverflowReturnsAmountOutOfRange() throws {
        #expect(
            try SendEVMTransactionService.maximumFeeAtomic(
                feePerGas: "1",
                gasLimit: UInt64.max,
                networkID: "eth"
            ) == String(UInt64.max)
        )
        #expect(
            throws: SendTransactionSubmissionError.amountOutOfRange
        ) {
            try SendEVMTransactionService.maximumFeeAtomic(
                feePerGas: "2",
                gasLimit: UInt64.max,
                networkID: "eth"
            )
        }
    }

    @Test
    func nativeMaximumAlwaysPaysUnavailableAmountFromTransfer() throws {
        #expect(
            try SendNativeTransferAmountResolver.resolve(
                requestedAtomic: "100000000",
                balanceAtomic: "100000000",
                unavailableAtomic: "226000",
                usesMaximumBalance: true
            ) == "99774000"
        )

        #expect(try SendNativeTransferAmountResolver.resolve(
            requestedAtomic: "100000000", balanceAtomic: "100000000",
            unavailableAtomic: "226000", usesMaximumBalance: false) == "99774000")
    }

    @Test(arguments: [false, true])
    func nativeFeesRequireAPositiveRecipientAmount(maximum: Bool) throws {
        for balance in ["0", "99", "100"] {
            #expect(throws: SendTransactionSubmissionError.insufficientNetworkFeeBalance) {
                try SendNativeTransferAmountResolver.resolve(requestedAtomic: "100",
                    balanceAtomic: balance, unavailableAtomic: "100", usesMaximumBalance: maximum)
            }
        }
    }

    @Test(arguments: ["700", "850", "900", "1000"])
    func manualNativeAmountDeductsOnlyTheFeeShortfall(requested: String) throws {
        let result = try SendNativeTransferAmountResolver.resolve(requestedAtomic: requested,
            balanceAtomic: "1000", unavailableAtomic: "150", usesMaximumBalance: false)
        #expect(result == (requested == "700" ? "700" : "850"))
    }

    @Test
    func everyAccountBasedMainnetUsesLosslessMaximumResolution()
        throws
    {
        let supported = Set(
            AssetNetworkSelectorOption.allSupported.map(\.id)
        )
        let bitcoinFamily = Set(
            BitcoinFamilyChain.allCases.map(\.networkID)
        )
        let accountBased = supported.subtracting(bitcoinFamily)

        #expect(supported.count == 26)
        #expect(bitcoinFamily.count == 4)
        #expect(accountBased.count == 22)

        for networkID in accountBased {
            let amount = try SendNativeTransferAmountResolver.resolve(
                requestedAtomic: "900719925474099300000",
                balanceAtomic: "900719925474099300000",
                unavailableAtomic: "123456789",
                usesMaximumBalance: true
            )
            #expect(
                amount == "900719925473975843211",
                "Incorrect max amount for \(networkID)"
            )
        }
    }

    @Test
    func maximumResolutionRemainsExactAtTwoHundredDigits() throws {
        let balance = "1" + String(repeating: "0", count: 199)
        let expected = String(repeating: "9", count: 199)

        #expect(
            try SendNativeTransferAmountResolver.resolve(
                requestedAtomic: balance,
                balanceAtomic: balance,
                unavailableAtomic: "1",
                usesMaximumBalance: true
            ) == expected
        )
    }
}

@Suite(.serialized)
struct SendAmountPresentationTests {
    private let localCurrency = WalletCurrencyContext(
        code: "EUR",
        ratePerUSD: Decimal(string: "0.8")!
    )

    @Test
    func everySupportedNativeNetworkUsesLocalCurrency() {
        #expect(AssetNetworkSelectorOption.allSupported.count == 26)

        for network in AssetNetworkSelectorOption.allSupported {
            let asset = makeAsset(
                id: "\(network.id):native",
                networkID: network.id,
                blockchain: network.blockchain,
                contractAddress: nil,
                balance: 2,
                fiatValue: 50
            )
            let presented = SendAmountPresentation.formatted(
                amount: "1.25",
                asset: asset,
                currency: localCurrency
            )

            #expect(
                presented == EnglishNumbers.currency(
                    Decimal(string: "31.25")!,
                    using: localCurrency
                )
            )
        }
    }

    @Test
    func tokenUsesItsExactCachedPriceAndNeverNativePrice() {
        let asset = makeAsset(
            id: "eth:0x0000000000000000000000000000000000000001",
            networkID: "eth",
            blockchain: .ethereum,
            contractAddress:
                "0x0000000000000000000000000000000000000001",
            balance: 10,
            fiatValue: 0
        )
        let presented = SendAmountPresentation.formatted(
            amount: "3",
            asset: asset,
            currency: localCurrency,
            nativeUnitUSDPrice: 4_000,
            cachedAssetUnitUSDPrice: 2
        )

        #expect(
            presented == EnglishNumbers.currency(
                6,
                using: localCurrency
            )
        )
        #expect(
            SendAmountPresentation.formatted(
                amount: "3",
                asset: asset,
                currency: localCurrency,
                nativeUnitUSDPrice: 4_000
            ) == EnglishNumbers.localized(
                "wallet.format.asset_amount",
                "3",
                asset.symbol
            )
        )
    }

    @Test
    func holdingValuationTakesPrecedenceOverFallbackPrices() {
        let asset = makeAsset(
            id: "solana:mint",
            networkID: "solana",
            blockchain: .solana,
            contractAddress: "mint",
            balance: 4,
            fiatValue: 20
        )
        let presented = SendAmountPresentation.formatted(
            amount: "2",
            asset: asset,
            currency: localCurrency,
            nativeUnitUSDPrice: 4_000,
            cachedAssetUnitUSDPrice: 99
        )

        #expect(
            presented == EnglishNumbers.currency(
                10,
                using: localCurrency
            )
        )
    }

    @Test
    func nativeAssetCanUseNetworkPriceWhenHoldingPriceIsUnavailable() {
        let asset = makeAsset(
            id: "solana:native",
            networkID: "solana",
            blockchain: .solana,
            contractAddress: nil,
            balance: 0,
            fiatValue: 0
        )
        let presented = SendAmountPresentation.formatted(
            amount: "0.5",
            asset: asset,
            currency: localCurrency,
            nativeUnitUSDPrice: 100
        )

        #expect(
            presented == EnglishNumbers.currency(
                50,
                using: localCurrency
            )
        )
    }

    @Test
    func scannerReviewUsesTheSameSelectedCurrencyPresentation() throws {
        let asset = makeAsset(
            id: "bitcoin:native",
            networkID: "bitcoin",
            blockchain: .bitcoin,
            contractAddress: nil,
            balance: 2,
            fiatValue: 50
        )
        let request = SendPaymentRequest.manualEntry(
            networkID: asset.networkID
        )
        let draft = SendDraft(
            request: request,
            asset: asset,
            recipient: "recipient",
            amount: "1.25",
            note: nil
        )
        let amountRow = try #require(
            SendScannerReview(
                request: request,
                route: .review(draft),
                currencyContext: localCurrency
            ).presentation.rows.first(where: { $0.id == "amount" })
        )

        #expect(
            amountRow.value == EnglishNumbers.currency(
                Decimal(string: "31.25")!,
                using: localCurrency
            )
        )
        #expect(amountRow.valueStyle == .standard)
    }

    @Test
    func unavailableOrInvalidPricePreservesExactAssetAmount() {
        let asset = makeAsset(
            id: "solana:mint",
            networkID: "solana",
            blockchain: .solana,
            contractAddress: "mint",
            balance: 10,
            fiatValue: 0
        )
        let expected = EnglishNumbers.localized(
            "wallet.format.asset_amount",
            "1.23456789",
            asset.symbol
        )

        #expect(
            SendAmountPresentation.formatted(
                amount: "1.23456789",
                asset: asset,
                currency: localCurrency
            ) == expected
        )
        #expect(
            SendAmountPresentation.formatted(
                amount: "1.23456789",
                asset: asset,
                currency: localCurrency,
                cachedAssetUnitUSDPrice: 0
            ) == expected
        )
        #expect(
            SendAmountPresentation.formatted(
                amount: "1.23456789",
                asset: asset,
                currency: localCurrency,
                cachedAssetUnitUSDPrice: -1
            ) == expected
        )
    }

    @Test
    func unrepresentableAmountFallsBackWithoutLosingDigits() {
        let amount = String(repeating: "9", count: 200)
        let asset = makeAsset(
            id: "eth:native",
            networkID: "eth",
            blockchain: .ethereum,
            contractAddress: nil,
            balance: 1,
            fiatValue: 1
        )

        #expect(
            SendAmountPresentation.formatted(
                amount: amount,
                asset: asset,
                currency: localCurrency
            ) == EnglishNumbers.localized(
                "wallet.format.asset_amount",
                amount,
                asset.symbol
            )
        )
    }

    @Test
    func evmTokenDecimalsUsesExactOnChainABIValue() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            EVMTokenDecimalsURLProtocol.self
        ]
        let session = URLSession(configuration: configuration)
        let contract =
            "0xdac17f958d2ee523a2206206994597c13d831ec7"
        let validEndpoint = try #require(
            URL(string: "https://six-decimals.invalid")
        )
        let validClient = try SendEVMRPCClient(
            networkID: "eth",
            session: session,
            endpoints: [validEndpoint]
        )

        #expect(
            try await validClient.tokenDecimals(
                contractAddress: contract
            ) == 6
        )

        let invalidEndpoint = try #require(
            URL(string: "https://invalid-decimals.invalid")
        )
        let invalidClient = try SendEVMRPCClient(
            networkID: "polygon",
            session: session,
            endpoints: [invalidEndpoint]
        )
        await #expect(throws: SendTransactionSubmissionError.self) {
            try await invalidClient.tokenDecimals(
                contractAddress: contract
            )
        }
    }

    @Test
    func evmTokenFeeEstimationRejectsTheContractAsRecipient()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let contract =
            "0xc2132d05d31c914a87c6611c10748aeb04b58e8f"
        let asset = SendAssetChoice(
            id: "polygon:\(contract)",
            name: "USDT0",
            symbol: "USDT0",
            networkID: "polygon",
            networkName: "Polygon",
            blockchain: .polygon,
            contractAddress: contract,
            decimals: 6,
            logoSource: .unavailable,
            networkLogoSource: .unavailable,
            balance: 10,
            fiatValue: 10,
            balanceAtomic: "10000000",
            sourceAddress:
                "0xb8aecc0000000000000000000000000000c86b89"
        )
        let draft = SendDraft(
            request: .manualEntry(networkID: "polygon"),
            asset: asset,
            recipient: contract.uppercased(),
            amount: "1",
            note: nil
        )
        let fee = SendResolvedNetworkFee(
            model: .evmEIP1559,
            primaryValue: "30000000000",
            secondaryValue: "1000000000",
            provider: "unit-test",
            expiresAt: Date().addingTimeInterval(60)
        )

        do {
            _ = try await SendNetworkFeeEstimator(
                database: database
            ).estimate(draft: draft, fee: fee)
            Issue.record("A token transfer accepted its contract as recipient.")
        } catch let error as SendTransactionSubmissionError {
            #expect(error == .invalidRecipient)
        }
    }

    @Test
    func sendingBannerUsesTheTransferValueOnEveryNativeNetwork() {
        for network in AssetNetworkSelectorOption.allSupported {
            let asset = makeAsset(id: "\(network.id):native", networkID: network.id,
                                  blockchain: network.blockchain, contractAddress: nil,
                                  balance: 100, fiatValue: 200)
            #expect(SendAmountPresentation.activityAmount(
                amount: "2", asset: asset,
                currency: .init(code: "USD", ratePerUSD: 1), nativeUnitUSDPrice: 9_000
            ) == "$4.00")
            #expect(SendAmountPresentation.activityAmount(
                amount: "2", asset: asset, currency: localCurrency
            ) == "€3.20")
        }
    }

    @Test(arguments: [
        ("1.123456789", "1.12345678 TST"),
        ("9.999999999", "9.99999999 TST"),
        ("0.000000009", "0.00000000 TST"),
        ("12.340000000", "12.34 TST"),
        ("42", "42 TST"),
        ("123456789012345678901234567890123456789012.123456789", "123456789012345678901234567890123456789012.12345678 TST")
    ])
    func unpricedSendingAmountsTruncateWithoutLosingIntegerPrecision(example: (String, String)) {
        let asset = makeAsset(id: "base:0x1", networkID: "base", blockchain: .ethereum,
                              contractAddress: "0x1", balance: 100, fiatValue: 0)
        #expect(SendAmountPresentation.activityAmount(
            amount: example.0, asset: asset, currency: localCurrency,
            nativeUnitUSDPrice: 4_000
        ) == example.1)
    }

    @Test
    func sendingTokenUsesItsOwnCachedQuoteAndKeepsTinyFiatValues() {
        let asset = makeAsset(id: "base:0x1", networkID: "base", blockchain: .ethereum,
                              contractAddress: "0x1", balance: 100, fiatValue: 0)
        let currency = WalletCurrencyContext(code: "USD", ratePerUSD: 1)
        #expect(SendAmountPresentation.activityAmount(
            amount: "2", asset: asset, currency: currency,
            nativeUnitUSDPrice: 4_000, cachedAssetUnitUSDPrice: 2
        ) == "$4.00")
        #expect(SendAmountPresentation.activityAmount(
            amount: "0.000000019", asset: asset, currency: currency,
            cachedAssetUnitUSDPrice: 1
        ) == "$0.00000001")
        #expect(SendAmountPresentation.activityAmount(
            amount: nil, asset: asset, currency: currency
        ) == nil)
        #expect(SendAmountPresentation.activityAmount(
            amount: "invalid", asset: asset, currency: currency
        ) == nil)
    }

    private func makeAsset(
        id: String,
        networkID: String,
        blockchain: WalletBlockchain,
        contractAddress: String?,
        balance: Decimal,
        fiatValue: Decimal
    ) -> SendAssetChoice {
        SendAssetChoice(
            id: id,
            name: "Test Asset",
            symbol: "TST",
            networkID: networkID,
            networkName: "Test Network",
            blockchain: blockchain,
            contractAddress: contractAddress,
            decimals: 18,
            logoSource: .unavailable,
            networkLogoSource: .unavailable,
            balance: balance,
            fiatValue: fiatValue
        )
    }
}

private final class EVMTokenDecimalsURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let body = request.httpBody
                ?? Self.readBodyStream(request.httpBodyStream),
              let object = try? JSONSerialization.jsonObject(with: body)
                as? [String: Any],
              let identifier = object["id"] as? Int,
              object["method"] as? String == "eth_call",
              let params = object["params"] as? [Any],
              let call = params.first as? [String: Any],
              call["data"] as? String == "0x313ce567"
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.cannotParseResponse)
            )
            return
        }
        let result = url.host == "six-decimals.invalid"
            ? "0x" + String(repeating: "0", count: 63) + "6"
            : "0x100"
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = try! JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": identifier,
                "result": result
            ]
        )
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}
