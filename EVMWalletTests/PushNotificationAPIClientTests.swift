import Foundation
import Testing
@testable import Aperture

struct PushNotificationAPIClientTests {
    @Test
    func bootstrapUsesPostAndServerCanonicalBody() async throws {
        let recorder = PushAPIRequestRecorder(
            responses: [.success]
        )
        let client = try PushNotificationAPIClient(
            baseURL: try #require(
                URL(string: "https://notifications.example")
            ),
            requestExecutor: { request in
                try await recorder.execute(request)
            }
        )

        _ = try await client.reconcile(
            snapshot: Self.snapshot,
            identity: Self.identity,
            serverRegistrationKnown: false
        )

        let requests = await recorder.recordedRequests()
        #expect(
            requests.map { $0.url?.path }
                == [
                    "/v1/registration-challenges",
                    "/v1/installations"
                ]
        )
        let request = try #require(requests.last)
        #expect(request.httpMethod == "POST")
        #expect(
            request.url?.path == "/v1/installations"
        )
        let body = try #require(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body)
        let object = try #require(decoded as? [String: Any])
        #expect(object["environment"] as? String == "sandbox")
        #expect(object["bootstrapCredential"] as? String != nil)
        #expect(object["apnsEnvironment"] == nil)
        #expect(object["snapshotDigest"] == nil)
        let preferences = try #require(
            object["preferences"] as? [String: Any]
        )
        #expect(preferences["master"] as? Bool == true)
        #expect(preferences["masterEnabled"] == nil)
        let wallets = try #require(
            object["wallets"] as? [[String: Any]]
        )
        #expect(
            wallets.first?["notificationMonitoringEnabled"] as? Bool
                == true
        )
        let accounts = try #require(
            wallets.first?["accounts"] as? [[String: Any]]
        )
        #expect(accounts.first?["chainID"] as? String == "1")
    }

    @Test
    func encodedBootstrapMatchesCrossRuntimeFixture() throws {
        let request = PushInstallationBootstrapRequest(
            snapshot: Self.snapshot,
            bootstrapCredential:
                "QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI"
        )
        let encoded = try JSONEncoder().encode(request)
        let fixtureURL = try #require(
            Bundle(for: PushFixtureBundleMarker.self).url(
                forResource: "push-installation-registration",
                withExtension: "json"
            )
        )
        let fixture = try Data(contentsOf: fixtureURL)
        let decodedEncoded = try JSONSerialization.jsonObject(
            with: encoded
        )
        let decodedFixture = try JSONSerialization.jsonObject(
            with: fixture
        )
        let encodedObject = try #require(
            decodedEncoded as? NSDictionary
        )
        let fixtureObject = try #require(
            decodedFixture as? NSDictionary
        )
        #expect(encodedObject == fixtureObject)
    }

    @Test
    func knownRegistrationRecoversWhenServerStateWasLost()
        async throws {
        let recorder = PushAPIRequestRecorder(
            responses: [
                .error(
                    status: 401,
                    code: "installation_authentication_failed"
                ),
                .success
            ]
        )
        let client = try PushNotificationAPIClient(
            baseURL: try #require(
                URL(string: "https://notifications.example")
            ),
            requestExecutor: { request in
                try await recorder.execute(request)
            }
        )

        _ = try await client.reconcile(
            snapshot: Self.snapshot,
            identity: Self.identity,
            serverRegistrationKnown: true
        )

        let requests = await recorder.recordedRequests()
        #expect(
            requests.map(\.httpMethod) == ["PUT", "POST", "POST"]
        )
        #expect(
            requests.first?.url?.path
                == "/v1/installations/\(Self.identity.installationID)"
        )
        let updateBody = try #require(requests.first?.httpBody)
        let bootstrapBody = try #require(requests.last?.httpBody)
        #expect(
            String(decoding: updateBody, as: UTF8.self)
                .contains("bootstrapCredential") == false
        )
        #expect(
            String(decoding: bootstrapBody, as: UTF8.self)
                .contains("bootstrapCredential")
        )
    }

    @Test
    func existingBootstrapFallsBackToAuthenticatedReplacement()
        async throws {
        let recorder = PushAPIRequestRecorder(
            responses: [
                .error(
                    status: 409,
                    code: "installation_already_registered"
                ),
                .success
            ]
        )
        let client = try PushNotificationAPIClient(
            baseURL: try #require(
                URL(string: "https://notifications.example")
            ),
            requestExecutor: { request in
                try await recorder.execute(request)
            }
        )

        _ = try await client.reconcile(
            snapshot: Self.snapshot,
            identity: Self.identity,
            serverRegistrationKnown: false
        )

        #expect(
            await recorder.recordedRequests().map(\.httpMethod)
                == ["POST", "POST", "PUT"]
        )
    }

    @Test
    func credentialCollisionRequiresInstallationIdentityRotation()
        async throws {
        let recorder = PushAPIRequestRecorder(
            responses: [
                .error(
                    status: 409,
                    code: "installation_already_registered"
                ),
                .error(
                    status: 401,
                    code: "installation_authentication_failed"
                )
            ]
        )
        let client = try PushNotificationAPIClient(
            baseURL: try #require(
                URL(string: "https://notifications.example")
            ),
            requestExecutor: { request in
                try await recorder.execute(request)
            }
        )

        do {
            _ = try await client.reconcile(
                snapshot: Self.snapshot,
                identity: Self.identity,
                serverRegistrationKnown: false
            )
            Issue.record("Expected installation credential rejection")
        } catch let error as PushNotificationAPIError {
            #expect(
                error.diagnosticCode
                    == "installation_credential_rejected"
            )
        }
    }

    @Test
    func legacyRehomingConflictRequiresIdentityRotation()
        async throws {
        let recorder = PushAPIRequestRecorder(
            responses: [
                .error(
                    status: 409,
                    code: "remote_user_rebinding_forbidden"
                )
            ]
        )
        let client = try PushNotificationAPIClient(
            baseURL: try #require(
                URL(string: "https://notifications.example")
            ),
            requestExecutor: { request in
                try await recorder.execute(request)
            }
        )

        do {
            _ = try await client.reconcile(
                snapshot: Self.snapshot,
                identity: Self.identity,
                serverRegistrationKnown: true
            )
            Issue.record("Expected installation identity rotation")
        } catch let error as PushNotificationAPIError {
            #expect(
                error.diagnosticCode
                    == "installation_credential_rejected"
            )
        }
        #expect(
            await recorder.recordedRequests().map(\.httpMethod)
                == ["PUT"]
        )
    }

    @Test
    func replacementRebindingConflictRequiresIdentityRotation()
        async throws {
        let recorder = PushAPIRequestRecorder(
            responses: [
                .error(
                    status: 409,
                    code: "installation_already_registered"
                ),
                .error(
                    status: 409,
                    code: "remote_user_rebinding_forbidden"
                )
            ]
        )
        let client = try PushNotificationAPIClient(
            baseURL: try #require(
                URL(string: "https://notifications.example")
            ),
            requestExecutor: { request in
                try await recorder.execute(request)
            }
        )

        do {
            _ = try await client.reconcile(
                snapshot: Self.snapshot,
                identity: Self.identity,
                serverRegistrationKnown: false
            )
            Issue.record("Expected installation identity rotation")
        } catch let error as PushNotificationAPIError {
            #expect(
                error.diagnosticCode
                    == "installation_credential_rejected"
            )
        }
        #expect(
            await recorder.recordedRequests().map(\.httpMethod)
                == ["POST", "POST", "PUT"]
        )
    }

    @Test
    func authenticatedNotificationHistoryDecodesPagination()
        async throws {
        let recorder = PushAPIRequestRecorder(responses: [.history])
        let client = try PushNotificationAPIClient(
            baseURL: try #require(
                URL(string: "https://notifications.example")
            ),
            requestExecutor: { request in
                try await recorder.execute(request)
            }
        )

        let response = try await client.notificationHistory(
            identity: Self.identity,
            cursor: "cursor_123"
        )

        let request = try #require(
            await recorder.recordedRequests().first
        )
        #expect(request.httpMethod == "GET")
        #expect(
            request.url?.path
                == "/v1/installations/\(Self.identity.installationID)/notifications"
        )
        let requestURL = try #require(request.url)
        let components = try #require(
            URLComponents(
                url: requestURL,
                resolvingAgainstBaseURL: false
            )
        )
        let query = Dictionary(
            uniqueKeysWithValues:
                (components.queryItems ?? []).compactMap {
                    item in
                    item.value.map { (item.name, $0) }
                }
        )
        #expect(query["limit"] == "100")
        #expect(query["cursor"] == "cursor_123")
        #expect(
            request.value(
                forHTTPHeaderField: "Authorization"
            )?.hasPrefix("Installation ") == true
        )
        #expect(response.items.count == 1)
        #expect(response.items.first?.category == .received)
        #expect(
            response.items.first?.arguments
                == ["1.25", "ETH", "Ethereum"]
        )
        #expect(response.nextCursor == "next_cursor")
    }

    private static let identity = PushInstallationIdentity(
        installationID: "00000000-0000-4000-8000-000000000001",
        credential: Data(repeating: 0x42, count: 32),
        apnsToken: Data(repeating: 0x01, count: 32),
        remoteUserID: "00000000-0000-4000-8000-000000000002"
    )

    private static let snapshot = PushInstallationSnapshotRequest(
        remoteUserID: "00000000-0000-4000-8000-000000000002",
        installationID: identity.installationID,
        apnsToken: String(repeating: "01", count: 32),
        environment: "sandbox",
        locale: "en",
        currencyCode: "USD",
        currencyRatePerUSDBase10: "1",
        appVersion: "1.0",
        osVersion: "26.0",
        deviceModel: "iPhone",
        preferences: PushNotificationPreferences(
            master: true,
            received: true,
            sent: false,
            admin: true
        ),
        wallets: [
            PushRegisteredWallet(
                walletID: "wallet-fixture",
                name: "Fixture Wallet",
                kind: "created",
                notificationMonitoringEnabled: true,
                accounts: [
                    PushRegisteredAccount(
                        accountID: "account-ethereum",
                        networkID: "eth",
                        chainID: "1",
                        monitoredAddresses: [
                            PushMonitoredAddress(
                                address:
                                    "0x1111111111111111111111111111111111111111",
                                normalizedAddress:
                                    "0x1111111111111111111111111111111111111111",
                                role: "evm_owner"
                            )
                        ]
                    ),
                    PushRegisteredAccount(
                        accountID: "account-solana",
                        networkID: "solana",
                        chainID: "-501",
                        monitoredAddresses: [
                            PushMonitoredAddress(
                                address:
                                    "Vote111111111111111111111111111111111111111",
                                normalizedAddress:
                                    "Vote111111111111111111111111111111111111111",
                                role: "solana_owner"
                            ),
                            PushMonitoredAddress(
                                address:
                                    "Stake11111111111111111111111111111111111111",
                                normalizedAddress:
                                    "Stake11111111111111111111111111111111111111",
                                role: "solana_token_account"
                            )
                        ]
                    )
                ]
            )
        ]
    )
}

private final class PushFixtureBundleMarker {}

private actor PushAPIRequestRecorder {
    enum Stub {
        case success
        case history
        case error(status: Int, code: String)
    }

    private var responses: [Stub]
    private var requests: [URLRequest] = []

    init(responses: [Stub]) {
        self.responses = responses
    }

    func execute(
        _ request: URLRequest
    ) throws -> (Data, URLResponse) {
        requests.append(request)
        let status: Int
        let data: Data
        if request.url?.path == "/v1/registration-challenges" {
            status = 201
            data = try JSONSerialization.data(withJSONObject: [
                "challenge": String(repeating: "c", count: 43),
                "expiresAt": "2026-07-26T00:05:00.000Z",
                "serverTime": "2026-07-26T00:00:00.000Z"
            ])
        } else {
            let stub = responses.isEmpty
                ? .success
                : responses.removeFirst()
            switch stub {
            case .success:
                status = 200
                data = try JSONSerialization.data(withJSONObject: [
                    "registeredAt": "2026-07-26T00:00:00.000Z",
                    "serverTime": "2026-07-26T00:00:01.000Z",
                    "snapshotDigest": String(repeating: "a", count: 43)
                ])
            case .history:
                status = 200
                data = try JSONSerialization.data(withJSONObject: [
                    "items": [[
                        "notificationID":
                            "12b59011-d6ea-4b58-97ef-5ef355bb1d42",
                        "category": "received",
                        "state": "sent",
                        "titleKey": "notification.received.title",
                        "bodyKey":
                            "notification.received.body.unpriced",
                        "arguments": ["1.25", "ETH", "Ethereum"],
                        "walletID": "wallet-fixture",
                        "networkID": "eth",
                        "transactionHash": "0xabc123",
                        "assetSymbol": "ETH",
                        "createdAt": "2026-07-26T00:00:00.000Z",
                        "sentAt": "2026-07-26T00:00:01.000Z"
                    ]],
                    "nextCursor": "next_cursor",
                    "serverTime": "2026-07-26T00:00:02.000Z"
                ])
            case let .error(errorStatus, code):
                status = errorStatus
                data = try JSONSerialization.data(withJSONObject: [
                    "error": ["code": code]
                ])
            }
        }
        let response = try #require(
            HTTPURLResponse(
                url: request.url
                    ?? URL(string: "https://notifications.example")!,
                statusCode: status,
                httpVersion: "HTTP/2",
                headerFields: [
                    "Content-Type": "application/json"
                ]
            )
        )
        return (data, response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

actor PushRegistrationChallengeTestServer {
    struct Reply: Sendable {
        let status: Int
        let data: Data

        static func json(
            status: Int,
            _ object: [String: String]
        ) throws -> Reply {
            Reply(
                status: status,
                data: try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]
                )
            )
        }

        static func challenge(
            _ value: String,
            status: Int = 201,
            expiresAt: String = "2026-07-26T00:05:00.000Z",
            serverTime: String = "2026-07-26T00:00:00.000Z"
        ) throws -> Reply {
            try json(status: status, [
                "challenge": value,
                "expiresAt": expiresAt,
                "serverTime": serverTime
            ])
        }

        static func registrationSuccess() throws -> Reply {
            try json(status: 201, [
                "registeredAt": "2026-07-26T00:00:00.000Z",
                "serverTime": "2026-07-26T00:00:01.000Z",
                "snapshotDigest": String(repeating: "d", count: 43)
            ])
        }

        static func error(
            status: Int,
            code: String
        ) throws -> Reply {
            Reply(
                status: status,
                data: try JSONSerialization.data(withJSONObject: [
                    "error": ["code": code]
                ])
            )
        }
    }

    private var replies: [Reply]
    private var requests: [URLRequest] = []

    init(replies: [Reply]) {
        self.replies = replies
    }

    func execute(
        _ request: URLRequest
    ) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !replies.isEmpty else {
            throw PushRegistrationChallengeTestError
                .unexpectedRequest
        }
        let reply = replies.removeFirst()
        guard let response = HTTPURLResponse(
            url: request.url
                ?? URL(string: "https://notifications.example")!,
            statusCode: reply.status,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            throw PushRegistrationChallengeTestError
                .invalidResponseFixture
        }
        return (reply.data, response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private enum PushRegistrationChallengeTestError: Error {
    case unexpectedRequest
    case invalidResponseFixture
}
