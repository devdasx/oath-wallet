import CryptoKit
import Foundation
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct StellarSupportTests {
    private static let mnemonic =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private static let usdcIssuer =
        "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN"

    @Test
    func submissionClassifierDoesNotRetryAmbiguousBadSequence() {
        #expect(
            !StellarSubmissionErrorClassifier
                .isDefinitivePreSubmission(
                    .http(status: 400, code: "tx_bad_seq")
                )
        )
        #expect(
            StellarSubmissionErrorClassifier
                .isDefinitivePreSubmission(
                    .http(status: 400, code: "tx_bad_auth")
                )
        )
        #expect(
            !StellarSubmissionErrorClassifier
                .isDefinitivePreSubmission(
                    .http(status: 504, code: "timeout")
                )
        )
    }

    @Test
    func walletCoreDerivesCanonicalMainnetAccount() throws {
        let material = try Self.material(index: 0)

        #expect(StellarAddress.validated(material.address) == material.address)
        #expect(CoinType.stellar.validate(address: material.address))
        #expect(material.derivationPath == "m/44'/148'/0'")
        #expect(StellarAddress.validated(material.address.lowercased()) == nil)
        #expect(StellarAddress.validated("GINVALID") == nil)
    }

    @Test
    func amountMemoAndAssetIdentityAreStrictAndLossless() throws {
        #expect(try StellarAmount.atomicUnits(userUnits: "1.2345678") == "12345678")
        #expect(try StellarAmount.userUnits(atomic: "12345678") == "1.2345678")
        #expect(try StellarAmount.atomicUnits(userUnits: "0.0000001") == "1")
        #expect(throws: StellarProviderError.self) {
            try StellarAmount.atomicUnits(userUnits: "0.00000001")
        }
        #expect(StellarMemoTextValidator.validated(String(repeating: "a", count: 28)) != nil)
        #expect(StellarMemoTextValidator.validated(String(repeating: "a", count: 29)) == nil)
        #expect(StellarMemoTextValidator.validated("line\nbreak") == nil)

        let short = try #require(
            StellarAssetIdentity.validated(code: "usdc", issuer: Self.usdcIssuer)
        )
        let long = try #require(
            StellarAssetIdentity.validated(code: "LONGASSET12", issuer: Self.usdcIssuer)
        )
        #expect(short.contractAddress == "USDC:\(Self.usdcIssuer)")
        #expect(long.code == "LONGASSET12")
        #expect(StellarAssetIdentity.validated(code: "TOO-LONG-13!!", issuer: Self.usdcIssuer) == nil)
    }

    @Test
    func sepSevenPaymentURIParsesNativeAssetTokenAndMemo() throws {
        let destination = try Self.material(index: 1).address
        let native = try SendPaymentRequestParser.parse(
            "web+stellar:pay?destination=\(destination)&amount=1.25&memo=invoice-7&memo_type=MEMO_TEXT"
        )
        #expect(native.source == .stellarURI)
        #expect(native.recipient == destination)
        #expect(native.candidateNetworkIDs == [StellarConstants.networkID])
        #expect(native.requestedAsset == .native)
        #expect(native.requestedAmount == .userUnits("1.25"))
        #expect(native.memo == "invoice-7")

        let token = try SendPaymentRequestParser.parse(
            "web+stellar:pay?destination=\(destination)&asset_code=USDC&asset_issuer=\(Self.usdcIssuer)"
        )
        #expect(token.requestedAsset == .contract("USDC:\(Self.usdcIssuer)"))
        #expect(throws: SendPaymentRequestError.unsupportedParameter) {
            try SendPaymentRequestParser.parse(
                "web+stellar:pay?destination=\(destination)&memo=1&memo_type=MEMO_ID"
            )
        }
    }

    @Test
    func signedXDRSupportsActivationNativeAlphaFourAndAlphaTwelve() throws {
        let wallet = try #require(BIP39Mnemonic.hdWallet(mnemonic: Self.mnemonic))
        let key = try #require(
            wallet.getKey(
                coin: .stellar,
                derivationPath: StellarConstants.derivationPath
            )
        )
        let source = try StellarAddress.material(
            privateKey: key,
            derivationPath: StellarConstants.derivationPath
        ).address
        let destination = try Self.material(index: 1).address
        let short = try #require(
            StellarAssetIdentity.validated(code: "USDC", issuer: Self.usdcIssuer)
        )
        let long = try #require(
            StellarAssetIdentity.validated(code: "LONGASSET12", issuer: Self.usdcIssuer)
        )
        let operations: [StellarTransactionOperation] = [
            .createAccount(destination: destination, amountStroops: 10_000_000),
            .payment(destination: destination, asset: nil, amountStroops: 1),
            .payment(destination: destination, asset: short, amountStroops: 2),
            .payment(destination: destination, asset: long, amountStroops: 3)
        ]

        for operation in operations {
            let transaction = try StellarTransactionXDRBuilder.signedTransaction(
                source: source,
                sequence: 42,
                feeStroops: 100,
                memo: "Aperture",
                operation: operation,
                privateKeyData: key.data
            )
            #expect(Data(base64Encoded: transaction.envelopeXDR)?.isEmpty == false)
            #expect(transaction.transactionHash.count == 64)
            #expect(
                transaction.transactionHash.allSatisfy { character in
                    character.isASCII && character.isHexDigit
                }
            )
        }
        #expect(throws: StellarTransactionXDRBuilderError.sourceAccountMismatch) {
            try StellarTransactionXDRBuilder.signedEnvelope(
                source: destination,
                sequence: 42,
                feeStroops: 100,
                memo: nil,
                operation: operations[1],
                privateKeyData: key.data
            )
        }
    }

    @Test
    func nativePaymentMatchesTrustWalletCoreMainnetVector() throws {
        let key = try #require(Data(
            hexString:
                "3c0635f8638605aed6e461cf3fa2d508dd895df1a1655ff92c79bfbeaf88d4b9"
        ))
        let transaction = try StellarTransactionXDRBuilder.signedTransaction(
            source:
                "GDFEKJIFKUZP26SESUHZONAUJZMBSODVN2XBYN4KAGNHB7LX2OIXLPUL",
            sequence: 144_098_454_883_270_657,
            feeStroops: 1_000,
            memo: nil,
            operation: .payment(
                destination:
                    "GA3ISGYIE2ZTH3UAKEKBVHBPKUSL3LT4UQ6C5CUGP2IM5F467O267KI7",
                asset: nil,
                amountStroops: 1_000_000
            ),
            privateKeyData: key
        )

        // Trust Wallet Core 4.7.3
        // Stellar/TWAnySignerTests.cpp `Sign_Payment_66b5` emits the
        // TransactionV1Envelope body without the modern TransactionEnvelope
        // union discriminator. Compare the canonical transaction body rather
        // than the complete envelope because Ed25519 permits independently
        // randomized, valid signatures.
        let walletCoreEnvelope = try #require(Data(base64Encoded:
            "AAAAAMpFJQVVMv16RJUPlzQUTlgZOHVurhw3igGacP1305F1AAAD6AH/8MgAAAABAAAAAAAAAAAAAAABAAAAAAAAAAEAAAAANokbCCazM+6AURQanC9VJL2ufKQ8LoqGfpDOl577te8AAAAAAAAAAAAPQkAAAAAAAAAAAXfTkXUAAABAM9Nhzr8iWKzqnHknrxSVoa4b2qzbTzgyE2+WWxg6XHH50xiFfmvtRKVhzp0Jg8PfhatOb6KNheKRWEw4OvqEDw=="
        ))
        let apertureEnvelope = try #require(
            Data(base64Encoded: transaction.envelopeXDR)
        )
        let decoratedSignatureLength = 4 + 4 + 4 + 64
        #expect(apertureEnvelope.prefix(4) == Data([0, 0, 0, 2]))
        #expect(
            apertureEnvelope
                .dropFirst(4)
                .dropLast(decoratedSignatureLength)
                == walletCoreEnvelope.dropLast(decoratedSignatureLength)
        )
        #expect(
            transaction.transactionHash
                == "66b5bca4b4293bdd85a6a559b08918482774b76bcc170b4533411f1d6422ce24"
        )
        let transactionHash = try #require(
            Data(hexString: transaction.transactionHash)
        )
        let publicKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: key
        ).publicKey
        #expect(
            publicKey.isValidSignature(
                apertureEnvelope.suffix(64),
                for: transactionHash
            )
        )
    }

    @Test
    func horizonSubmissionPreservesReservedBase64Characters() async throws {
        let xdr = Data([0xFB, 0xFF, 0xFE, 0x00]).base64EncodedString()
        #expect(xdr == "+//+AA==")
        let encodedBody = try #require(
            StellarHorizonFormEncoder.transactionBody(xdr: xdr)
        )
        #expect(
            String(decoding: encodedBody, as: UTF8.self)
                == "tx=%2B%2F%2F%2BAA%3D%3D"
        )

        let sender = try Self.material(index: 0).address
        StellarFixtureURLProtocol.install(
            sender: sender,
            recipient: try Self.material(index: 1).address,
            issuer: Self.usdcIssuer,
            accountExists: true
        )
        let result = try await Self.client().submit(xdr: xdr)
        #expect(result.successful)
        #expect(result.ledger == 99)
        let request = try #require(
            StellarFixtureURLProtocol.submittedRequest()
        )
        #expect(request.method == "POST")
        #expect(request.contentType == "application/x-www-form-urlencoded")
        #expect(request.body == "tx=%2B%2F%2F%2BAA%3D%3D")
    }

    @Test
    func horizonSubmissionRejectsInvalidBase64BeforeTransport() async throws {
        let sender = try Self.material(index: 0).address
        StellarFixtureURLProtocol.install(
            sender: sender,
            recipient: try Self.material(index: 1).address,
            issuer: Self.usdcIssuer,
            accountExists: true
        )

        await #expect(throws: StellarProviderError.self) {
            _ = try await Self.client().submit(xdr: "not base64")
        }
        #expect(StellarFixtureURLProtocol.submittedRequest() == nil)
    }

    @Test
    func horizonLoadsBalancesPathHistoryFeesAndIgnoresPoolShares() async throws {
        let sender = try Self.material(index: 0).address
        let recipient = try Self.material(index: 1).address
        StellarFixtureURLProtocol.install(
            sender: sender,
            recipient: recipient,
            issuer: Self.usdcIssuer,
            accountExists: true
        )
        let client = Self.client()
        let probe = StellarBalanceProbe()
        let snapshot = try await client.loadSnapshot(
            material: StellarAccountMaterial(
                address: sender,
                publicKey: "fixture",
                derivationPath: StellarConstants.derivationPath
            )
        ) { partial in
            await probe.record(partial)
        }

        #expect(await probe.count == 1)
        #expect(await probe.historyCount == 0)
        #expect(snapshot.balancesAreAuthoritative)
        #expect(snapshot.historyIsAuthoritative)
        #expect(snapshot.providerFailureCodes.isEmpty)
        #expect(snapshot.balances.count == 2)
        #expect(snapshot.balances[0].amountText == "50")
        #expect(snapshot.balances[0].atomicAmount == "500000000")
        let token = try #require(snapshot.balances.first { $0.metadata != nil })
        #expect(token.metadata?.symbol == "USDC")
        #expect(token.atomicAmount == "12500000")
        #expect(snapshot.history.count == 2)
        #expect(snapshot.history.contains { $0.signedAmountText == "-1" })
        #expect(snapshot.history.contains { $0.metadata?.symbol == "USDC" })

        let state = try #require(try await client.accountState(address: sender))
        #expect(state.sequence == 41)
        #expect(state.trustlines.count == 1)
        #expect(state.trustlines[0].authorized)
        #expect(state.trustlines[0].buyingLiabilitiesStroops == "0")
        #expect(state.trustlines[0].limitStroops == "1000000000")
        let network = try await client.networkState()
        #expect(network.baseReserveStroops == "5000000")
        #expect(network.recommendedFeeStroops == 200)
    }

    @Test
    func reserveChecksReuseSavedFeesWithoutRequestingFeeStatistics() async throws {
        StellarFixtureURLProtocol.install(sender: try Self.material(index: 0).address,
            recipient: try Self.material(index: 1).address, issuer: Self.usdcIssuer, accountExists: true)
        let client = Self.client()
        #expect(try await client.baseReserveStroops() == "5000000")
        let state = try await client.networkState(usingSavedFee: "350")
        #expect(state.baseReserveStroops == "5000000")
        #expect(state.recommendedFeeStroops == 350)
        #expect(StellarFixtureURLProtocol.feeReadCount() == 0)
        _ = try await client.networkState()
        #expect(StellarFixtureURLProtocol.feeReadCount() == 1)
    }

    @Test
    func unfundedAccountProducesAuthoritativeNativeZero() async throws {
        let sender = try Self.material(index: 0).address
        StellarFixtureURLProtocol.install(
            sender: sender,
            recipient: try Self.material(index: 1).address,
            issuer: Self.usdcIssuer,
            accountExists: false
        )
        let snapshot = try await Self.client().loadSnapshot(
            material: StellarAccountMaterial(
                address: sender,
                publicKey: "fixture",
                derivationPath: StellarConstants.derivationPath
            )
        )

        #expect(snapshot.balancesAreAuthoritative)
        #expect(snapshot.historyIsAuthoritative)
        #expect(snapshot.balances.count == 1)
        #expect(snapshot.balances[0].atomicAmount == "0")
        #expect(snapshot.history.isEmpty)
    }

    @Test
    func existingAccountMissingNativeBalanceIsRejected() async throws {
        let sender = try Self.material(index: 0).address
        StellarFixtureURLProtocol.install(
            sender: sender,
            recipient: try Self.material(index: 1).address,
            issuer: Self.usdcIssuer,
            accountExists: true,
            omitNativeBalance: true
        )

        await #expect(throws: StellarProviderError.self) {
            _ = try await Self.client().loadSnapshot(
                material: StellarAccountMaterial(
                    address: sender,
                    publicKey: "fixture",
                    derivationPath: StellarConstants.derivationPath
                )
            )
        }
    }

    @Test
    func issuerCanSendWithoutTrustlineAndDestinationLimitIsEnforced()
        throws
    {
        let issuer = try Self.material(index: 0).address
        let destination = try Self.material(index: 1).address
        let token = try #require(
            StellarAssetIdentity.validated(code: "TEST", issuer: issuer)
        )
        let issuerState = Self.accountState(address: issuer, trustlines: [])
        let destinationLine = StellarTrustlineState(
            identity: token,
            balanceStroops: "90000000",
            sellingLiabilitiesStroops: "0",
            buyingLiabilitiesStroops: "5000000",
            limitStroops: "100000000",
            authorized: true
        )
        let destinationState = Self.accountState(
            address: destination,
            trustlines: [destinationLine]
        )

        let allowed = try SendStellarTransactionService.prepareAmount(
            draft: Self.tokenDraft(
                token: token,
                recipient: destination,
                amount: "0.5"
            ),
            requestedAtomic: 5_000_000,
            senderState: issuerState,
            recipientState: destinationState,
            networkState: StellarNetworkState(
                baseReserveStroops: "5000000",
                recommendedFeeStroops: 100
            ),
            feeStroops: 100,
            token: token
        )
        #expect(allowed.atomicAmount == 5_000_000)

        #expect(throws: SendTransactionSubmissionError.self) {
            try SendStellarTransactionService.prepareAmount(
                draft: Self.tokenDraft(
                    token: token,
                    recipient: destination,
                    amount: "0.5000001"
                ),
                requestedAtomic: 5_000_001,
                senderState: issuerState,
                recipientState: destinationState,
                networkState: StellarNetworkState(
                    baseReserveStroops: "5000000",
                    recommendedFeeStroops: 100
                ),
                feeStroops: 100,
                token: token
            )
        }
    }

    private static func material(index: Int) throws -> StellarAccountMaterial {
        let wallet = try #require(BIP39Mnemonic.hdWallet(mnemonic: mnemonic))
        let path = "m/44'/148'/\(index)'"
        let key = try #require(
            wallet.getKey(coin: .stellar, derivationPath: path)
        )
        return try StellarAddress.material(
            privateKey: key,
            derivationPath: path
        )
    }

    private static func client() -> StellarAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StellarFixtureURLProtocol.self]
        let transport = StellarHorizonTransport(
            baseURL: URL(string: "https://stellar.fixture")!,
            session: URLSession(configuration: configuration)
        )
        return StellarAPIClient(transport: transport)
    }

    private static func accountState(
        address: String,
        trustlines: [StellarTrustlineState]
    ) -> StellarAccountState {
        StellarAccountState(
            address: address,
            sequence: 41,
            nativeBalanceStroops: "500000000",
            nativeSellingLiabilitiesStroops: "0",
            subentryCount: Int64(trustlines.count),
            numSponsoring: 0,
            numSponsored: 0,
            trustlines: trustlines
        )
    }

    private static func tokenDraft(
        token: StellarAssetIdentity,
        recipient: String,
        amount: String
    ) -> SendDraft {
        SendDraft(
            request: .manualEntry(networkID: StellarConstants.networkID),
            asset: SendAssetChoice(
                id: token.assetID,
                name: "Test Asset",
                symbol: token.code,
                networkID: StellarConstants.networkID,
                networkName: "Stellar",
                blockchain: .stellar,
                contractAddress: token.contractAddress,
                decimals: StellarConstants.decimals,
                logoSource: .nativeCoin(blockchain: .stellar),
                networkLogoSource: .nativeCoin(blockchain: .stellar),
                balance: 1,
                fiatValue: 1
            ),
            recipient: recipient,
            amount: amount,
            note: nil
        )
    }
}

private actor StellarBalanceProbe {
    private(set) var count = 0
    private(set) var historyCount = -1

    func record(_ snapshot: StellarWalletSnapshot) {
        count += 1
        historyCount = snapshot.history.count
    }
}

private final class StellarFixtureURLProtocol: URLProtocol,
    @unchecked Sendable {
    struct RecordedSubmission: Equatable, Sendable {
        let method: String
        let contentType: String
        let body: String
    }

    private struct State {
        var sender = ""
        var recipient = ""
        var issuer = ""
        var accountExists = false
        var omitNativeBalance = false
        var feeReads = 0
        var submission: RecordedSubmission?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func install(
        sender: String,
        recipient: String,
        issuer: String,
        accountExists: Bool,
        omitNativeBalance: Bool = false
    ) {
        lock.lock()
        state = State(
            sender: sender,
            recipient: recipient,
            issuer: issuer,
            accountExists: accountExists,
            omitNativeBalance: omitNativeBalance
        )
        lock.unlock()
    }

    static func feeReadCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return state.feeReads
    }

    static func submittedRequest() -> RecordedSubmission? {
        lock.lock()
        defer { lock.unlock() }
        return state.submission
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let fixture = Self.state
        Self.lock.unlock()
        guard let url = request.url else {
            fail(URLError(.badURL))
            return
        }
        if url.path == "/accounts/\(fixture.sender)" {
            fixture.accountExists
                ? respond(status: 200, object: Self.account(fixture))
                : respond(status: 404, object: ["title": "Resource Missing"])
        } else if url.path == "/accounts/\(fixture.sender)/payments" {
            respond(
                status: 200,
                object: fixture.accountExists
                    ? Self.payments(fixture) : Self.emptyPayments
            )
        } else if url.path == "/fee_stats" {
            Self.lock.lock()
            Self.state.feeReads += 1
            Self.lock.unlock()
            respond(status: 200, object: ["fee_charged": ["p95": "200"]])
        } else if url.path == "/ledgers" {
            respond(
                status: 200,
                object: ["_embedded": ["records": [[
                    "base_reserve_in_stroops": 5_000_000
                ]]]]
            )
        } else if url.path == "/transactions" {
            let submission = RecordedSubmission(
                method: request.httpMethod ?? "",
                contentType: request.value(
                    forHTTPHeaderField: "Content-Type"
                ) ?? "",
                body: URLRequestBodyReader.data(from: request).map {
                    String(decoding: $0, as: UTF8.self)
                } ?? ""
            )
            Self.lock.lock()
            Self.state.submission = submission
            Self.lock.unlock()
            respond(
                status: 200,
                object: [
                    "hash": String(repeating: "a", count: 64),
                    "ledger": 99,
                    "successful": true
                ]
            )
        } else {
            fail(URLError(.unsupportedURL))
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, object: Any) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else {
            fail(URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }

    private static func account(_ value: State) -> [String: Any] {
        let nativeBalance: [[String: Any]] = value.omitNativeBalance
            ? []
            : [[
                "balance": "50.0000000",
                "selling_liabilities": "1.0000000",
                "asset_type": "native"
            ]]
        return [
            "account_id": value.sender,
            "sequence": "41",
            "subentry_count": 1,
            "num_sponsoring": 0,
            "num_sponsored": 0,
            "balances": nativeBalance + [
                [
                    "balance": "1.2500000",
                    "selling_liabilities": "0.0000000",
                    "buying_liabilities": "0.0000000",
                    "limit": "100.0000000",
                    "asset_type": "credit_alphanum4",
                    "asset_code": "USDC",
                    "asset_issuer": value.issuer,
                    "is_authorized": true
                ],
                [
                    "balance": "7.0000000",
                    "selling_liabilities": "0.0000000",
                    "asset_type": "liquidity_pool_shares"
                ]
            ]
        ]
    }

    private static func payments(_ value: State) -> [String: Any] {
        let transaction: [String: Any] = [
            "hash": "hash-native",
            "ledger": 77,
            "created_at": "2026-08-02T01:00:00Z",
            "fee_charged": "100",
            "successful": true,
            "memo_type": "text",
            "memo": "invoice",
            "source_account": value.sender,
            "source_account_sequence": "42"
        ]
        return [
            "_embedded": ["records": [
                [
                    "id": "1",
                    "paging_token": "1",
                    "transaction_hash": "hash-native",
                    "created_at": "2026-08-02T01:00:00Z",
                    "type": "payment",
                    "asset_type": "native",
                    "amount": "1.0000000",
                    "from": value.sender,
                    "to": value.recipient,
                    "transaction": transaction
                ],
                [
                    "id": "2",
                    "paging_token": "2",
                    "transaction_hash": "hash-token",
                    "created_at": "2026-08-02T00:00:00Z",
                    "type": "path_payment_strict_receive",
                    "asset_type": "credit_alphanum4",
                    "asset_code": "USDC",
                    "asset_issuer": value.issuer,
                    "amount": "0.5000000",
                    "from": value.recipient,
                    "to": value.sender,
                    "transaction": [
                        "hash": "hash-token",
                        "ledger": 76,
                        "created_at": "2026-08-02T00:00:00Z",
                        "fee_charged": "100",
                        "successful": true,
                        "memo_type": "none",
                        "source_account": value.recipient,
                        "source_account_sequence": "9"
                    ]
                ]
            ]],
            "_links": ["next": ["href": "https://stellar.fixture/next"]]
        ]
    }

    private static var emptyPayments: [String: Any] {
        [
            "_embedded": ["records": []],
            "_links": ["next": ["href": "https://stellar.fixture/next"]]
        ]
    }
}
