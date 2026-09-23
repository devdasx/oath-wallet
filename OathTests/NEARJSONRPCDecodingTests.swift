import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct NEARJSONRPCDecodingTests {
    @Test
    func jsonValuePreservesSignedUnsignedAndDecimalNumbers() throws {
        let payload = Data(
            """
            {
              "signed": -12,
              "maximum": 18446744073709551615,
              "gas_limit": 51.591948,
              "ratio": 0.8
            }
            """.utf8
        )

        let object = try JSONDecoder().decode(
            [String: NEARJSONValue].self,
            from: payload
        )

        #expect(object["signed"]?.stringValue == "-12")
        #expect(
            object["maximum"]?.stringValue == "18446744073709551615"
        )
        #expect(object["gas_limit"]?.stringValue == "51.591948")
        #expect(object["ratio"]?.stringValue == "0.8")
    }

    @Test
    func protocolConfigIgnoresUnrelatedDecimalFields() async throws {
        let client = try Self.client(
            statusCode: 200,
            payload: """
            {
              "jsonrpc": "2.0",
              "id": "aperture",
              "result": {
                "chain_id": "mainnet",
                "gas_limit": 51.591948,
                "protocol_reward_rate": [1, 10],
                "runtime_config": {
                  "storage_amount_per_byte": "10000000000000000000",
                  "wasm_config": {
                    "regular_op_cost": 0.8
                  }
                }
              }
            }
            """
        )

        let config = try await client.protocolConfig()

        #expect(config.chainID == "mainnet")
        #expect(config.storageAmountPerByte == "10000000000000000000")
    }

    @Test
    func proxyHTTPErrorPreservesStructuredProviderCode() async throws {
        let client = try Self.client(
            statusCode: 403,
            payload: #"{"error":{"code":"near_method_forbidden"}}"#
        )

        do {
            _ = try await client.gasPrice()
            Issue.record("The rejected NEAR request unexpectedly succeeded.")
        } catch let error as NEARProviderError {
            #expect(
                error.diagnosticDescription
                    == "near_http_403_near_method_forbidden"
            )
        } catch {
            Issue.record("Unexpected NEAR provider error: \(error)")
        }
    }

    @Test
    func nestedUnknownAccountMeansAccountDoesNotExist() async throws {
        let client = try Self.client(
            statusCode: 200,
            payload: """
            {
              "jsonrpc": "2.0",
              "id": "aperture",
              "error": {
                "code": -32000,
                "data": {
                  "name": "HANDLER_ERROR",
                  "cause": {
                    "name": "UNKNOWN_ACCOUNT"
                  }
                }
              }
            }
            """
        )

        #expect(
            try await client.accountExists(
                accountID:
                    "288736a61dd2d19345a6badd00f067b7e3048826840dbd76e7c68e49de4a3814"
            ) == false
        )
    }

    @Test
    func proxyTextUnknownAccountMeansAccountDoesNotExist() async throws {
        let recipient =
            "288736a61dd2d19345a6badd00f067b7e3048826840dbd76e7c68e49de4a5814"
        let client = try Self.client(
            statusCode: 200,
            payload: """
            {
              "jsonrpc": "2.0",
              "id": "aperture",
              "error": {
                "code": -32000,
                "message": "Server error",
                "data": "account \(recipient) does not exist while viewing"
              }
            }
            """
        )

        #expect(
            try await client.accountExists(accountID: recipient) == false
        )
    }

    @Test
    func addressKindsMatchMainnetAccountRules() {
        #expect(
            NEARAddress.kind(
                "288736a61dd2d19345a6badd00f067b7e3048826840dbd76e7c68e49de4a3814"
            ) == .implicit
        )
        #expect(
            NEARAddress.kind("0x" + String(repeating: "a", count: 40))
                == .ethereumImplicit
        )
        #expect(NEARAddress.kind("alice.near") == .named)
        #expect(
            NEARAddress.kind(String(repeating: "A", count: 64)) == nil
        )
    }

    @Test
    func nativeTransferCanInitializeImplicitRecipients() throws {
        try SendNEARTransactionService.validateRecipient(
            kind: .implicit,
            accountExists: false,
            sendsToken: false
        )
        try SendNEARTransactionService.validateRecipient(
            kind: .ethereumImplicit,
            accountExists: false,
            sendsToken: false
        )
    }

    @Test
    func missingNamedAndTokenRecipientsAreRejectedBeforeSigning() {
        Self.expectRecipientFailure(
            kind: .named,
            sendsToken: false,
            expectedCode: "near_named_recipient_missing"
        )
        Self.expectRecipientFailure(
            kind: .implicit,
            sendsToken: true,
            expectedCode: "near_token_recipient_missing"
        )
    }

    @Test
    func existingNamedTokenRecipientIsAccepted() throws {
        try SendNEARTransactionService.validateRecipient(
            kind: .named,
            accountExists: true,
            sendsToken: true
        )
    }

    private static func expectRecipientFailure(
        kind: NEARAddress.Kind,
        sendsToken: Bool,
        expectedCode: String
    ) {
        do {
            try SendNEARTransactionService.validateRecipient(
                kind: kind,
                accountExists: false,
                sendsToken: sendsToken
            )
            Issue.record("Expected the missing NEAR recipient to be rejected.")
        } catch let error as SendTransactionSubmissionError {
            guard case let .provider(networkID, code, _) = error else {
                Issue.record("Unexpected send error: \(error)")
                return
            }
            #expect(networkID == NEARConstants.networkID)
            #expect(code == expectedCode)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static func client(
        statusCode: Int,
        payload: String
    ) throws -> NEARAPIClient {
        let endpoint = try #require(
            URL(string: "https://near-decoding.example.test")
        )
        let transport = try NEARJSONRPCTransport(
            endpoint: endpoint,
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            let responseURL = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: responseURL,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (Data(payload.utf8), response)
        }
        return NEARAPIClient(transport: transport)
    }
}
