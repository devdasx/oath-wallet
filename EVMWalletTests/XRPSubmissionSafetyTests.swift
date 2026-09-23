import Foundation
import Testing
import WalletCore
@testable import Aperture

private struct XRPTestSpendReservation: SendSpendSubmissionReserving {
    func markSubmissionStarted(
        receipt: SendTransactionReceipt
    ) async throws {}
}

extension SendXRPTransactionService {
    /// Direct service tests never submit to mainnet. Production Send has no
    /// overload without the durable wallet-account reservation.
    func submit(
        draft: SendDraft,
        material: SendResolvedSigningMaterial
    ) async throws -> SendTransactionReceipt {
        try await submit(
            draft: draft,
            material: material,
            reservation: XRPTestSpendReservation()
        )
    }
}

@Suite(.serialized)
struct XRPSubmissionSafetyTests {
    private static let mnemonic =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    @Test
    func accountAndDestinationPoliciesRejectBeforeSubmission() async throws {
        try await Self.expectFailure(
            configuration: .init(senderFlags: 0x0010_0000),
            expectedCode: "provider_xrp_sender_master_key_disabled"
        )
        try await Self.expectFailure(
            configuration: .init(recipientFlags: 0x0002_0000),
            memo: nil,
            expectedCode: "provider_xrp_destination_tag_required"
        )
        try await Self.expectFailure(
            configuration: .init(recipientFlags: 0x0008_0000),
            expectedCode: "provider_xrp_destination_disallows_xrp"
        )
        try await Self.expectFailure(
            configuration: .init(
                recipientFlags: 0x0100_0000,
                depositAuthorized: false
            ),
            expectedCode: "provider_xrp_deposit_not_authorized",
            expectedDepositChecks: 1
        )
    }

    @Test
    func issuedTokenPoliciesRejectUnsafeTrustLineStates() async throws {
        try await Self.expectFailure(
            configuration: .init(
                recipientLine: .init(balance: "0", limit: "1")
            ),
            token: true,
            expectedCode: "provider_xrp_destination_trust_line_limit"
        )
        try await Self.expectFailure(
            configuration: .init(
                issuerFlags: 0x0004_0000,
                recipientLine: .init(
                    balance: "0",
                    authorizedByPeer: false
                )
            ),
            token: true,
            expectedCode:
                "provider_xrp_destination_trust_line_unauthorized"
        )
        try await Self.expectFailure(
            configuration: .init(
                senderLine: .init(
                    balance: "12.5",
                    frozenByPeer: true
                )
            ),
            token: true,
            expectedCode: "provider_xrp_trust_line_frozen"
        )
        try await Self.expectFailure(
            configuration: .init(issuerTransferRate: 1_005_000_000),
            token: true,
            expectedCode: "provider_xrp_transfer_fee_unsupported"
        )
        try await Self.expectFailure(
            configuration: .init(
                senderLine: .init(
                    balance: "12.5",
                    noRippleByPeer: true
                )
            ),
            token: true,
            expectedCode: "provider_xrp_issuer_rippling_disabled"
        )
        try await Self.expectFailure(
            configuration: .init(
                senderLine: .init(
                    balance: "12.5",
                    qualityOut: 500_000_000
                )
            ),
            token: true,
            expectedCode:
                "provider_xrp_trust_line_quality_unsupported"
        )
    }

    @Test
    func depositAuthReserveExceptionAndDestinationTagZeroStillSign()
        async throws
    {
        let reserveException = try await Self.makeService(
            configuration: .init(
                recipientFlags: 0x0100_0000,
                recipientBalanceDrops: "1000000",
                depositAuthorized: false
            )
        )
        _ = try await reserveException.service.submit(
            draft: Self.nativeDraft(
                sender: reserveException.context.sender,
                recipient: reserveException.context.recipient,
                memo: nil
            ),
            material: reserveException.context.material
        )
        #expect(await reserveException.fixture.depositCheckCount == 0)
        #expect(await reserveException.fixture.submitCount == 1)

        let tagZero = try await Self.makeService(
            configuration: .init(recipientFlags: 0x0002_0000)
        )
        _ = try await tagZero.service.submit(
            draft: Self.nativeDraft(
                sender: tagZero.context.sender,
                recipient: tagZero.context.recipient,
                memo: "0"
            ),
            material: tagZero.context.material
        )
        #expect(await tagZero.fixture.submitCount == 1)
        #expect((await tagZero.fixture.submittedBlob)?.isEmpty == false)

        let xAddress = try #require(
            XRPAddress.signingDestination(
                classicAddress: tagZero.context.recipient,
                destinationTag: 0
            )
        )
        let xAddressReceipt = try await tagZero.service.submit(
            draft: Self.nativeDraft(
                sender: tagZero.context.sender,
                recipient: xAddress,
                memo: nil
            ),
            material: tagZero.context.material
        )
        #expect(xAddressReceipt.toAddress == tagZero.context.recipient)
        #expect(await tagZero.fixture.submitCount == 2)
    }

    @Test
    func submissionClassifiersSeparateDefiniteAndAmbiguousFailures() {
        #expect(
            XRPSubmissionErrorClassifier.isDefinitivePreSubmission(
                .rpc(code: -32_602, message: "invalid params")
            )
        )
        #expect(
            !XRPSubmissionErrorClassifier.isDefinitivePreSubmission(
                .rpc(code: -32_603, message: "internal error")
            )
        )
        #expect(
            XRPSubmissionErrorClassifier.isDefinitivePreSubmission(
                .http(status: 400, code: "bad_request")
            )
        )
        #expect(
            !XRPSubmissionErrorClassifier.isDefinitivePreSubmission(
                .http(status: 429, code: "rate_limited")
            )
        )
        #expect(
            !XRPSubmissionErrorClassifier.isDefinitivePreSubmission(
                .providerRejected("too_busy")
            )
        )
        #expect(
            XRPSubmissionErrorClassifier.isDefinitivePreSubmission(
                .providerRejected("invalid_transaction")
            )
        )
        #expect(
            !XRPSubmissionErrorClassifier.isDefinitivePreSubmission(
                .invalidResponse("decoding")
            )
        )

        #expect(
            XRPSubmitResult(
                engineResult: "tesSUCCESS",
                transactionHash: nil
            ).wasAccepted
        )
        #expect(
            XRPSubmitResult(
                engineResult: "terQUEUED",
                transactionHash: nil
            ).wasAccepted
        )
        #expect(
            XRPSubmitResult(
                engineResult: "tefALREADY",
                transactionHash: nil
            ).wasAccepted
        )
        #expect(
            !XRPSubmitResult(
                engineResult: "tecPATH_DRY",
                transactionHash: nil
            ).wasAccepted
        )
        #expect(
            XRPSubmitResult(
                engineResult: "tecPATH_DRY",
                transactionHash: nil
            ).mayHaveConsumedSequence
        )
        #expect(
            XRPSubmitResult(
                engineResult: "tefPAST_SEQ",
                transactionHash: nil
            ).mayHaveConsumedSequence
        )
        #expect(
            !XRPSubmitResult(
                engineResult: "temMALFORMED",
                transactionHash: nil
            ).mayHaveConsumedSequence
        )
    }

    @Test
    func transactionIDUsesXRPLSHA512Half() throws {
        // Validated XRP mainnet transaction 9E7727D3...063430A7.
        let blob = try #require(
            Data(
                hexString:
                    "1200002406569FAF2E00000001201B0658D259614000000000000001"
                    + "68400000000000000A7321ED4BEF4EA8BF8152665A4C250B4C6623A"
                    + "381524FE1820DC97C35FE6B0CDB1BD4FC7440E5BAC2D529B26297E35"
                    + "C2B8DD41ED0D686492A250E23B7C93EBFDADB69300D51E5818305BE0"
                    + "56A21FE83BA86CFC32CD2E901E64138A7E4A9C9A23A86EDE22A09811"
                    + "4FE45816308CDA5D4F3E4932ECCDF8FDDCF92C1368314B5F762798A53"
                    + "D543A014CAF8B297CFF8F2F937E8"
            )
        )
        let transactionID = SendXRPTransactionService.transactionHash(blob)
        #expect(
            transactionID
                == "9E7727D37B5CA420F3195CBAF658BE45E9629273210D0255F3729232063430A7"
        )

        let prefixedBlob = Data([0x54, 0x58, 0x4E, 0x00]) + blob
        let standardizedSHA512_256 = Hash.sha512_256(data: prefixedBlob)
            .map { String(format: "%02X", $0) }
            .joined()
        #expect(transactionID != standardizedSHA512_256)
    }

    @Test
    func signedSubmissionNeverFailsOverAfterAmbiguousFailure() async throws {
        let primary = try #require(
            URL(string: "https://xrp-submit-primary.example.test")
        )
        let fallback = try #require(
            URL(string: "https://xrp-submit-fallback.example.test")
        )
        let probe = XRPSubmissionEndpointProbe()
        let transport = try XRPJSONRPCTransport(
            endpoint: primary,
            fallbackEndpoints: [fallback],
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            await probe.record(request.url?.host)
            throw URLError(.timedOut)
        }

        do {
            _ = try await transport.request(
                method: "submit",
                parameters: [
                    "tx_blob": .string("AA"),
                    "fail_hard": .boolean(true)
                ]
            )
            Issue.record("Timed-out XRP submission unexpectedly succeeded.")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
        #expect(await probe.hosts == [primary.host])
    }

    private static func expectFailure(
        configuration: XRPSubmissionFixture.Configuration,
        token: Bool = false,
        memo: String? = "42",
        expectedCode: String,
        expectedDepositChecks: Int = 0
    ) async throws {
        let setup = try await Self.makeService(configuration: configuration)
        let draft = token
            ? Self.tokenDraft(
                sender: setup.context.sender,
                recipient: setup.context.recipient,
                issuer: setup.context.issuer
            )
            : Self.nativeDraft(
                sender: setup.context.sender,
                recipient: setup.context.recipient,
                memo: memo
            )
        do {
            _ = try await setup.service.submit(
                draft: draft,
                material: setup.context.material
            )
            Issue.record("Unsafe XRP transaction unexpectedly submitted.")
        } catch let error as SendTransactionSubmissionError {
            #expect(error.diagnosticCode == expectedCode)
        }
        #expect(await setup.fixture.submitCount == 0)
        #expect(
            await setup.fixture.depositCheckCount == expectedDepositChecks
        )
    }

    private static func makeService(
        configuration: XRPSubmissionFixture.Configuration
    ) async throws -> (
        service: SendXRPTransactionService,
        fixture: XRPSubmissionFixture,
        context: XRPTestSigningContext
    ) {
        let context = try Self.signingContext()
        let fixture = XRPSubmissionFixture(
            configuration: configuration,
            sender: context.sender,
            recipient: context.recipient,
            issuer: context.issuer
        )
        let endpoint = try #require(
            URL(string: "https://xrp-safety.example.test")
        )
        let client = XRPAPIClient(
            transport: try XRPJSONRPCTransport(
                endpoint: endpoint,
                router: AdaptiveProviderRouter(persistsHealth: false)
            ) { request in
                try await fixture.response(for: request)
            }
        )
        return (
            SendXRPTransactionService(
                api: client,
                quoteLoader: { _ in Self.feeQuote() }
            ),
            fixture,
            context
        )
    }

    private static func signingContext() throws -> XRPTestSigningContext {
        let wallet = try #require(
            BIP39Mnemonic.hdWallet(mnemonic: mnemonic)
        )
        func address(_ index: Int) throws -> String {
            let key = try #require(
                wallet.getKey(
                    coin: .xrp,
                    derivationPath: "m/44'/144'/\(index)'/0/0"
                )
            )
            return CoinType.xrp.deriveAddress(privateKey: key)
        }
        let key = try #require(
            wallet.getKey(
                coin: .xrp,
                derivationPath: XRPConstants.derivationPath
            )
        )
        let sender = try address(0)
        let account = DBWalletAccountRecord(
            id: "wallet:xrp:safety",
            walletID: "wallet",
            networkID: XRPConstants.networkID,
            address: sender,
            normalizedAddress: sender,
            label: XRPConstants.accountLabel,
            derivationPath: XRPConstants.derivationPath,
            accountIndex: 0,
            publicKey: key.getPublicKeySecp256k1(compressed: true).description,
            isWatchOnly: false,
            isEnabled: true,
            createdAt: 0,
            updatedAt: 0,
            lastSyncedAt: nil
        )
        return XRPTestSigningContext(
            sender: sender,
            recipient: try address(1),
            issuer: try address(2),
            material: SendResolvedSigningMaterial(
                walletID: "wallet",
                account: account,
                privateKey: key.data
            )
        )
    }

    private static func nativeDraft(
        sender: String,
        recipient: String,
        memo: String?
    ) -> SendDraft {
        SendDraft(
            request: SendPaymentRequest.manualEntry(
                networkID: XRPConstants.networkID
            ).replacingMemo(memo),
            asset: SendAssetChoice(
                id: XRPConstants.nativeAssetID,
                name: "XRP",
                symbol: XRPConstants.nativeSymbol,
                networkID: XRPConstants.networkID,
                networkName: "XRP",
                blockchain: .xrp,
                contractAddress: nil,
                decimals: XRPConstants.decimals,
                logoSource: .nativeCoin(blockchain: .xrp),
                networkLogoSource: .network(blockchain: .xrp),
                balance: 50,
                fiatValue: 0,
                balanceAtomic: "50000000",
                sourceAddress: sender
            ),
            recipient: recipient,
            amount: "1",
            note: nil
        )
    }

    private static func tokenDraft(
        sender: String,
        recipient: String,
        issuer: String
    ) -> SendDraft {
        SendDraft(
            request: .manualEntry(networkID: XRPConstants.networkID),
            asset: SendAssetChoice(
                id: "xrp:USD:\(issuer)",
                name: "USD",
                symbol: "USD",
                networkID: XRPConstants.networkID,
                networkName: "XRP",
                blockchain: .xrp,
                contractAddress: "USD:\(issuer)",
                decimals: 15,
                logoSource: .unavailable,
                networkLogoSource: .network(blockchain: .xrp),
                balance: 12.5,
                fiatValue: 0,
                sourceAddress: sender
            ),
            recipient: recipient,
            amount: "2.5",
            note: nil
        )
    }

    private static func feeQuote() -> SendNetworkFeeQuote {
        SendNetworkFeeQuote(
            networkID: XRPConstants.networkID,
            provider: "fixture",
            fetchedAt: Date(),
            expiresAt: Date().addingTimeInterval(60),
            tiers: [
                SendNetworkFeeTier(
                    preset: .fastest,
                    model: .xrpProtocol,
                    primaryValue: "10",
                    secondaryValue: nil
                )
            ]
        )
    }
}

private struct XRPTestSigningContext {
    let sender: String
    let recipient: String
    let issuer: String
    let material: SendResolvedSigningMaterial
}

private struct XRPLineConfiguration: Sendable {
    var balance = "0"
    var limit = "1000"
    var authorizedByPeer = true
    var frozenByAccount = false
    var frozenByPeer = false
    var deepFrozenByAccount = false
    var deepFrozenByPeer = false
    var noRippleByPeer = false
    var qualityIn: UInt32 = 0
    var qualityOut: UInt32 = 0

    func json(issuer: String) -> [String: Any] {
        [
            "account": issuer,
            "balance": balance,
            "currency": "USD",
            "limit": limit,
            "limit_peer": "0",
            "quality_in": Int(qualityIn),
            "quality_out": Int(qualityOut),
            "peer_authorized": authorizedByPeer,
            "freeze": frozenByAccount,
            "freeze_peer": frozenByPeer,
            "deep_freeze": deepFrozenByAccount,
            "deep_freeze_peer": deepFrozenByPeer,
            "no_ripple_peer": noRippleByPeer
        ]
    }
}

private actor XRPSubmissionFixture {
    struct Configuration: Sendable {
        var senderFlags: UInt32 = 0
        var recipientFlags: UInt32 = 0
        var issuerFlags: UInt32 = 0
        var issuerTransferRate: UInt32?
        var recipientBalanceDrops = "2000000"
        var senderLine: XRPLineConfiguration? = .init(balance: "12.5")
        var recipientLine: XRPLineConfiguration? = .init(balance: "0")
        var depositAuthorized = true
        var submitEngineResult = "tesSUCCESS"
    }

    private let configuration: Configuration
    private let sender: String
    private let recipient: String
    private let issuer: String
    private(set) var submitCount = 0
    private(set) var depositCheckCount = 0
    private(set) var submittedBlob: String?

    init(
        configuration: Configuration,
        sender: String,
        recipient: String,
        issuer: String
    ) {
        self.configuration = configuration
        self.sender = sender
        self.recipient = recipient
        self.issuer = issuer
    }

    func response(for request: URLRequest) throws -> (Data, URLResponse) {
        let body = try #require(request.httpBody)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let method = try #require(envelope["method"] as? String)
        let params = try #require(envelope["params"] as? [[String: Any]])
        let parameter = params.first ?? [:]
        let result: [String: Any]
        switch method {
        case "account_info":
            let account = parameter["account"] as? String ?? sender
            let flags: UInt32
            let balance: String
            let sequence: Int
            let ownerCount: Int
            if account == sender {
                flags = configuration.senderFlags
                balance = "50000000"
                sequence = 7
                ownerCount = 1
            } else if account == recipient {
                flags = configuration.recipientFlags
                balance = configuration.recipientBalanceDrops
                sequence = 2
                ownerCount = 0
            } else {
                flags = configuration.issuerFlags
                balance = "100000000"
                sequence = 3
                ownerCount = 0
            }
            var accountData: [String: Any] = [
                "Account": account,
                "Balance": balance,
                "Flags": Int(flags),
                "OwnerCount": ownerCount,
                "Sequence": sequence
            ]
            if account == issuer,
               let rate = configuration.issuerTransferRate {
                accountData["TransferRate"] = Int(rate)
            }
            result = ["account_data": accountData, "validated": true]
        case "account_lines":
            let account = parameter["account"] as? String
            let line = account == sender
                ? configuration.senderLine : configuration.recipientLine
            result = [
                "lines": line.map { [$0.json(issuer: issuer)] } ?? []
            ]
        case "server_state":
            result = [
                "state": [
                    "validated_ledger": [
                        "reserve_base": 1_000_000,
                        "reserve_inc": 200_000
                    ]
                ]
            ]
        case "ledger_current":
            result = ["ledger_current_index": 100]
        case "deposit_authorized":
            depositCheckCount += 1
            result = [
                "source_account": sender,
                "destination_account": recipient,
                "deposit_authorized": configuration.depositAuthorized,
                "validated": true
            ]
        case "submit":
            submitCount += 1
            submittedBlob = parameter["tx_blob"] as? String
            let blobHex = try #require(submittedBlob)
            let blob = try #require(Data(hexString: blobHex))
            result = [
                "engine_result": configuration.submitEngineResult,
                "tx_json": [
                    "hash": Self.transactionID(for: blob)
                ]
            ]
        default:
            Issue.record("Unexpected XRP safety request: \(method)")
            result = ["status": "error", "error": "unexpectedFixture"]
        }
        return try Self.response(for: request, result: result)
    }

    private static func response(
        for request: URLRequest,
        result: [String: Any]
    ) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (
            try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "result": result
            ]),
            response
        )
    }

    private static func transactionID(for blob: Data) -> String {
        let prefixedBlob = Data([0x54, 0x58, 0x4E, 0x00]) + blob
        return Hash.sha512(data: prefixedBlob)
            .prefix(32)
            .map { String(format: "%02X", $0) }
            .joined()
    }
}

private actor XRPSubmissionEndpointProbe {
    private(set) var hosts: [String?] = []

    func record(_ host: String?) {
        hosts.append(host)
    }
}
