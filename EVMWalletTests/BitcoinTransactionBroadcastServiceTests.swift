import Foundation
import Testing
@testable import Aperture

struct BitcoinTransactionBroadcastServiceTests {
    private static let genesisTransaction = """
        0100000001
        0000000000000000000000000000000000000000000000000000000000000000
        ffffffff
        4d
        04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73
        ffffffff
        01
        00f2052a01000000
        43
        4104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac
        00000000
        """
    private static let genesisTransactionID =
        "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
    private static let firstPersonToPersonTransaction = """
        0100000001
        c997a5e56e104102fa209c6a852dd90660a20b2d9c352423edce25857fcd3704
        00000000
        48
        47304402204e45e16932b8af514961a1d3a1a25fdf3f4f7732e9d624c6c61548ab5fb8cd410220181522ec8eca07de4860a4acdd12909d831cc56cbbac4622082221a8768d1d0901
        ffffffff
        02
        00ca9a3b00000000
        43
        4104ae1a62fe09c5f51b13905f07f06b99a2f7159b2225f374cd378d71302fa28414e7aab37397f554a7df5f142c21c1b7303b8a0626f1baded5c72a704f7e6cd84cac
        00286bee00000000
        43
        410411db93e1dcdb8a016b49840f8c53bc1eb68a382e97b1482ecad7b148a6909a5cb2e0eaddfb84ccf9744464f82e160bfa9b8b64f9d4c03f999b8643f656b412a3ac
        00000000
        """
    private static let firstPersonToPersonTransactionID =
        "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16"

    @Test
    func decodesCompleteRawTransactionAndComputesCanonicalID() throws {
        let service = BitcoinTransactionBroadcastService(
            broadcaster: BitcoinTransactionBroadcastMock(.success(""))
        )
        let preview = try service.preview(
            for: "0x\n" + Self.genesisTransaction
        )

        #expect(preview.transactionID == Self.genesisTransactionID)
        #expect(preview.inputCount == 1)
        #expect(preview.outputCount == 1)
        #expect(preview.byteCount == 204)
        #expect(!preview.normalizedHex.contains { $0.isWhitespace })
    }

    @Test
    func rejectsMalformedIncompleteAndOversizedPayloads() {
        let service = BitcoinTransactionBroadcastService(
            broadcaster: BitcoinTransactionBroadcastMock(.success(""))
        )

        #expect(throws: BitcoinTransactionBroadcastValidationError.empty) {
            try service.preview(for: " \n\t")
        }
        #expect(throws: BitcoinTransactionBroadcastValidationError.invalid) {
            try service.preview(for: "001")
        }
        #expect(throws: BitcoinTransactionBroadcastValidationError.invalid) {
            try service.preview(for: "00gg")
        }
        #expect(throws: BitcoinTransactionBroadcastValidationError.invalid) {
            try service.preview(for: "01000000000000000000")
        }
        #expect(throws: BitcoinTransactionBroadcastValidationError.tooLarge) {
            try service.preview(
                for: String(
                    repeating: "00",
                    count: BitcoinTransactionBroadcastService
                        .maximumSerializedByteCount + 1
                )
            )
        }
    }

    @Test
    func verifiesProviderTransactionIDBeforeReportingSuccess() async throws {
        let transport = BitcoinTransactionBroadcastMock(
            .success("  \(Self.genesisTransactionID.uppercased())\n")
        )
        let service = BitcoinTransactionBroadcastService(
            broadcaster: transport
        )
        let preview = try service.preview(for: Self.genesisTransaction)

        let result = try await service.broadcast(preview)

        #expect(result.transactionID == Self.genesisTransactionID)
        #expect(!result.wasAlreadyKnown)
        #expect(await transport.submittedHexes() == [preview.normalizedHex])
    }

    @Test
    func treatsAlreadyKnownTransactionAsSuccessful() async throws {
        let transport = BitcoinTransactionBroadcastMock(
            .alreadyKnown
        )
        let service = BitcoinTransactionBroadcastService(
            broadcaster: transport
        )
        let preview = try service.preview(for: Self.genesisTransaction)

        let result = try await service.broadcast(preview)

        #expect(result.transactionID == Self.genesisTransactionID)
        #expect(result.wasAlreadyKnown)
        #expect(await transport.submittedHexes().count == 1)
    }

    @Test
    func preservesDefinitiveNetworkRejectionDetails() async throws {
        let rejection = BitcoinTransactionBroadcastError.rejected(
            code: "test_rpc_-26",
            message: "min relay fee not met"
        )
        let transport = BitcoinTransactionBroadcastMock(
            .failure(
                .rejected(
                    provider: "test",
                    code: "rpc_-26",
                    message: "min relay fee not met"
                )
            )
        )
        let service = BitcoinTransactionBroadcastService(
            broadcaster: transport
        )
        let preview = try service.preview(for: Self.genesisTransaction)

        await #expect(throws: rejection) {
            try await service.broadcast(preview)
        }
    }

    @Test
    func distinguishesSafePreflightFailureFromUnknownOutcome() async throws {
        let previewService = BitcoinTransactionBroadcastService(
            broadcaster: BitcoinTransactionBroadcastMock(.success(""))
        )
        let preview = try previewService.preview(
            for: Self.genesisTransaction
        )

        let preflight = BitcoinTransactionBroadcastService(
            broadcaster: BitcoinTransactionBroadcastMock(
                .failure(
                    .notAttempted(
                        provider: "test",
                        code: "provider_timeout"
                    )
                )
            )
        )
        await #expect(
            throws: BitcoinTransactionBroadcastError.notAttempted(
                code: "test_provider_timeout"
            )
        ) {
            try await preflight.broadcast(preview)
        }

        let ambiguous = BitcoinTransactionBroadcastService(
            broadcaster: BitcoinTransactionBroadcastMock(
                .failure(
                    .outcomeUnknown(
                        provider: "test",
                        code: "unavailable"
                    )
                )
            )
        )
        await #expect(
            throws: BitcoinTransactionBroadcastError.outcomeUnknown(
                code: "test_unavailable"
            )
        ) {
            try await ambiguous.broadcast(preview)
        }
    }

    @Test
    func rejectsMismatchedProviderTransactionID() async throws {
        let service = BitcoinTransactionBroadcastService(
            broadcaster: BitcoinTransactionBroadcastMock(
                .success(String(repeating: "0", count: 64))
            )
        )
        let preview = try service.preview(for: Self.genesisTransaction)

        await #expect(
            throws: BitcoinTransactionBroadcastError.outcomeUnknown(
                code: "transaction_id_mismatch"
            )
        ) {
            try await service.broadcast(preview)
        }
    }

    #if LIVE_MAINNET_TESTS
    @Test
    func configuredHTTPSBroadcastersKeepSpentInputsAmbiguous() async throws {
        let service = BitcoinTransactionBroadcastService()
        let preview = try service.preview(
            for: Self.firstPersonToPersonTransaction
        )
        #expect(
            preview.transactionID == Self.firstPersonToPersonTransactionID
        )

        do {
            let result = try await service.broadcast(preview)
            #expect(result.wasAlreadyKnown)
        } catch let error as BitcoinTransactionBroadcastError {
            guard case let .outcomeUnknown(code) = error else {
                Issue.record("Unexpected mainnet broadcast outcome: \(error)")
                return
            }
            #expect(code.contains("http_"))
        } catch {
            Issue.record("Unexpected mainnet transport error: \(error)")
        }
    }
    #endif
}

struct BitcoinFamilyHTTPAPIClientTests {
    private static let transactionID =
        "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"

    @Test
    func bitcoinFeeUsesMempoolRecommendedFeeSchema() async throws {
        let recorder = BitcoinFamilyHTTPRequestRecorder()
        let client = SendBitcoinFamilyHTTPAPIClient { request in
            await recorder.record(request)
            let data = Data(
                "{\"fastestFee\":12,\"halfHourFee\":8,\"hourFee\":4}"
                    .utf8
            )
            return (data, Self.response(request, status: 200))
        }

        let quote = try await client.quote(
            for: .bitcoin,
            now: Date(timeIntervalSince1970: 1_000)
        )

        #expect(quote.provider == "mempool_space")
        #expect(quote.tier(for: .fastest)?.primaryValue == "12")
        #expect(quote.tier(for: .standard)?.primaryValue == "8")
        #expect(quote.tier(for: .economy)?.primaryValue == "4")
        let requests = await recorder.requests()
        #expect(requests.map(\.url) == [
            "https://mempool.space/api/v1/fees/recommended"
        ])
        #expect(requests.first?.method == "GET")
    }

    @Test
    func bitcoinFeeFallsBackToBlockstreamAndRoundsUp() async throws {
        let recorder = BitcoinFamilyHTTPRequestRecorder()
        let client = SendBitcoinFamilyHTTPAPIClient { request in
            await recorder.record(request)
            if request.url?.host == "mempool.space" {
                return (
                    Data("temporarily unavailable".utf8),
                    Self.response(request, status: 503)
                )
            }
            return (
                Data("{\"1\":9.1,\"3\":5.2,\"6\":2.1}".utf8),
                Self.response(request, status: 200)
            )
        }

        let quote = try await client.quote(for: .bitcoin)

        #expect(quote.provider == "blockstream_esplora")
        #expect(quote.tier(for: .fastest)?.primaryValue == "10")
        #expect(quote.tier(for: .standard)?.primaryValue == "6")
        #expect(quote.tier(for: .economy)?.primaryValue == "3")
        #expect(await recorder.requests().map(\.url) == [
            "https://mempool.space/api/v1/fees/recommended",
            "https://blockstream.info/api/fee-estimates"
        ])
    }

    @Test
    func dogecoinAPIQuoteEnforcesRelayMinimum() async throws {
        let recorder = BitcoinFamilyHTTPRequestRecorder()
        let client = SendBitcoinFamilyHTTPAPIClient { request in
            await recorder.record(request)
            return (
                Data("{\"result\":\"0.001\"}".utf8),
                Self.response(request, status: 200)
            )
        }

        let quote = try await client.quote(for: .dogecoin)

        #expect(quote.provider == "atomic_dogecoin_blockbook")
        #expect(quote.tiers.allSatisfy { $0.primaryValue == "1000" })
        let paths = await recorder.requests().map(\.url).sorted()
        #expect(paths == [
            "https://dogecoin.atomicwallet.io/api/v2/estimatefee/12",
            "https://dogecoin.atomicwallet.io/api/v2/estimatefee/2",
            "https://dogecoin.atomicwallet.io/api/v2/estimatefee/6"
        ])
    }

    @Test
    func primaryHTTPBroadcastRequestMatchesEachChainAPI() async throws {
        let cases: [(BitcoinFamilyChain, String, String)] = [
            (.bitcoin, "mempool.space", "/api/tx"),
            (.bitcoinCash, "api.bitcore.io", "/api/BCH/mainnet/tx/send"),
            (.litecoin, "litecoinspace.org", "/api/tx"),
            (
                .dogecoin,
                "dogecoin.atomicwallet.io",
                "/api/v2/sendtx"
            )
        ]

        for (chain, host, path) in cases {
            let recorder = BitcoinFamilyHTTPRequestRecorder()
            let client = SendBitcoinFamilyHTTPAPIClient { request in
                await recorder.record(request)
                let data: Data
                switch chain {
                case .bitcoin, .litecoin:
                    data = Data(Self.transactionID.utf8)
                case .bitcoinCash:
                    data = Data(
                        "{\"txid\":\"\(Self.transactionID)\"}".utf8
                    )
                case .dogecoin:
                    data = Data(
                        "{\"result\":\"\(Self.transactionID)\"}".utf8
                    )
                }
                return (data, Self.response(request, status: 200))
            }

            let result = try await client.broadcast(
                chain: chain,
                rawTransactionHex: "00",
                expectedTransactionID: Self.transactionID
            )

            #expect(result.transactionID == Self.transactionID)
            #expect(!result.wasAlreadyKnown)
            let request = try #require(await recorder.requests().first)
            #expect(request.method == "POST")
            #expect(request.host == host)
            #expect(request.path == path)
            if chain == .bitcoinCash {
                let object = try #require(
                    try JSONSerialization.jsonObject(with: request.body)
                        as? [String: String]
                )
                #expect(object == ["rawTx": "00"])
                #expect(request.contentType == "application/json")
            } else {
                #expect(request.body == Data("00".utf8))
                #expect(
                    request.contentType == "text/plain; charset=utf-8"
                )
            }
        }
    }

    @Test
    func ambiguousPrimaryBroadcastFallsBackToIndependentAPI()
        async throws
    {
        let recorder = BitcoinFamilyHTTPRequestRecorder()
        let client = SendBitcoinFamilyHTTPAPIClient { request in
            await recorder.record(request)
            if request.url?.host == "mempool.space" {
                return (
                    Data("upstream timeout".utf8),
                    Self.response(request, status: 503)
                )
            }
            return (
                Data(Self.transactionID.utf8),
                Self.response(request, status: 200)
            )
        }

        let result = try await client.broadcast(
            chain: .bitcoin,
            rawTransactionHex: "00",
            expectedTransactionID: Self.transactionID
        )

        #expect(result.transactionID == Self.transactionID)
        #expect(await recorder.requests().map(\.host) == [
            "mempool.space",
            "blockstream.info"
        ])
    }

    @Test
    func definitiveBroadcastRejectionDoesNotReplayOnFallback()
        async throws
    {
        let recorder = BitcoinFamilyHTTPRequestRecorder()
        let client = SendBitcoinFamilyHTTPAPIClient { request in
            await recorder.record(request)
            return (
                Data("min relay fee not met".utf8),
                Self.response(request, status: 400)
            )
        }

        await #expect(
            throws: SendBitcoinFamilyHTTPBroadcastError.rejected(
                provider: "mempool_space",
                code: "http_400",
                message: "min relay fee not met"
            )
        ) {
            try await client.broadcast(
                chain: .bitcoin,
                rawTransactionHex: "00",
                expectedTransactionID: Self.transactionID
            )
        }
        #expect(await recorder.requests().count == 1)
    }

    @Test
    func duplicateHTTPBroadcastIsReportedAsSuccess() async throws {
        let client = SendBitcoinFamilyHTTPAPIClient { request in
            (
                Data("transaction already in block chain".utf8),
                Self.response(request, status: 400)
            )
        }

        let result = try await client.broadcast(
            chain: .litecoin,
            rawTransactionHex: "00",
            expectedTransactionID: Self.transactionID
        )

        #expect(result.transactionID == Self.transactionID)
        #expect(result.wasAlreadyKnown)
    }

    private static func response(
        _ request: URLRequest,
        status: Int
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}

private actor BitcoinFamilyHTTPRequestRecorder {
    struct Request: Equatable, Sendable {
        let method: String
        let url: String
        let host: String
        let path: String
        let contentType: String?
        let body: Data
    }

    private var values: [Request] = []

    func record(_ request: URLRequest) {
        values.append(Request(
            method: request.httpMethod ?? "",
            url: request.url?.absoluteString ?? "",
            host: request.url?.host ?? "",
            path: request.url?.path ?? "",
            contentType: request.value(
                forHTTPHeaderField: "Content-Type"
            ),
            body: request.httpBody ?? Data()
        ))
    }

    func requests() -> [Request] {
        values
    }
}

private actor BitcoinTransactionBroadcastMock:
    SendBitcoinFamilyTransactionBroadcasting {
    enum Outcome: Sendable {
        case success(String)
        case alreadyKnown
        case failure(SendBitcoinFamilyHTTPBroadcastError)
    }

    private let outcome: Outcome
    private var submissions: [String] = []

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }

    func broadcast(
        chain: BitcoinFamilyChain,
        rawTransactionHex: String,
        expectedTransactionID: String
    ) async throws -> SendBitcoinFamilyBroadcastResult {
        submissions.append(rawTransactionHex)
        switch outcome {
        case let .success(transactionID):
            return SendBitcoinFamilyBroadcastResult(
                transactionID: transactionID,
                wasAlreadyKnown: false
            )
        case .alreadyKnown:
            return SendBitcoinFamilyBroadcastResult(
                transactionID: expectedTransactionID,
                wasAlreadyKnown: true
            )
        case let .failure(error):
            throw error
        }
    }

    func submittedHexes() -> [String] {
        submissions
    }
}
