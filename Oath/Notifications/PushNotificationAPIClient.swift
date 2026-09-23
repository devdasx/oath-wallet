import Foundation

enum PushNotificationAPIError: Error {
    case missingConfiguration
    case invalidConfiguration(String)
    case transport(String)
    case invalidHTTPResponse
    case server(status: Int, code: String)
    case invalidResponse(String)
    case credentialRejected

    var diagnosticCode: String {
        switch self {
        case .missingConfiguration:
            "configuration_missing"
        case let .invalidConfiguration(reason):
            "configuration_invalid_\(reason)"
        case let .transport(code):
            "transport_\(code)"
        case .invalidHTTPResponse:
            "response_not_http"
        case let .server(status, code):
            "server_\(status)_\(code)"
        case let .invalidResponse(code):
            "response_invalid_\(code)"
        case .credentialRejected:
            "installation_credential_rejected"
        }
    }
}

struct PushNotificationAPIClient: Sendable {
    private let baseURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let requestExecutor:
        @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(baseURL: URL, session: URLSession? = nil) throws {
        guard baseURL.scheme?.lowercased() == "https" else {
            throw PushNotificationAPIError
                .invalidConfiguration("https_required")
        }
        guard baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw PushNotificationAPIError
                .invalidConfiguration("unexpected_url_components")
        }
        self.baseURL = baseURL

        let resolvedSession: URLSession
        if let session {
            resolvedSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy =
                .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            resolvedSession = URLSession(configuration: configuration)
        }
        requestExecutor = { request in
            try await resolvedSession.data(for: request)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    init(
        baseURL: URL,
        requestExecutor: @escaping @Sendable (URLRequest) async throws
            -> (Data, URLResponse)
    ) throws {
        guard baseURL.scheme?.lowercased() == "https" else {
            throw PushNotificationAPIError
                .invalidConfiguration("https_required")
        }
        guard baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw PushNotificationAPIError
                .invalidConfiguration("unexpected_url_components")
        }
        self.baseURL = baseURL
        self.requestExecutor = requestExecutor
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    static func configured() throws -> PushNotificationAPIClient {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "NotificationServiceBaseURL"
        ) as? String,
        !value.isEmpty,
        !value.contains("$("),
        let url = URL(string: value) else {
            throw PushNotificationAPIError.missingConfiguration
        }
        return try PushNotificationAPIClient(baseURL: url)
    }

    func reconcile(
        snapshot: PushInstallationSnapshotRequest,
        identity: PushInstallationIdentity,
        serverRegistrationKnown: Bool
    ) async throws -> PushInstallationSnapshotResponse {
        if serverRegistrationKnown {
            do {
                return try await replace(
                    snapshot: snapshot,
                    identity: identity
                )
            } catch where Self.isRemoteUserRebindingFailure(error) {
                throw PushNotificationAPIError.credentialRejected
            } catch where Self.isAuthenticationFailure(error) {
                do {
                    return try await bootstrap(
                        snapshot: snapshot,
                        identity: identity
                    )
                } catch where Self.isAlreadyRegistered(error) {
                    throw PushNotificationAPIError.credentialRejected
                }
            }
        }

        do {
            return try await bootstrap(
                snapshot: snapshot,
                identity: identity
            )
        } catch where Self.isAlreadyRegistered(error) {
            do {
                return try await replace(
                    snapshot: snapshot,
                    identity: identity
                )
            } catch where Self.isAuthenticationFailure(error)
                || Self.isRemoteUserRebindingFailure(error) {
                throw PushNotificationAPIError.credentialRejected
            }
        }
    }

    private func bootstrap(
        snapshot: PushInstallationSnapshotRequest,
        identity: PushInstallationIdentity
    ) async throws -> PushInstallationSnapshotResponse {
        let challenge = try await registrationChallenge(
            snapshot: snapshot,
            identity: identity
        )
        do {
            return try await createInstallation(
                snapshot: snapshot,
                identity: identity,
                challenge: challenge.challenge
            )
        } catch where Self.isExpiredRegistrationChallenge(error) {
            let replacement = try await registrationChallenge(
                snapshot: snapshot,
                identity: identity
            )
            return try await createInstallation(
                snapshot: snapshot,
                identity: identity,
                challenge: replacement.challenge
            )
        }
    }

    private func registrationChallenge(
        snapshot: PushInstallationSnapshotRequest,
        identity: PushInstallationIdentity
    ) async throws -> PushRegistrationChallengeResponse {
        let endpoint = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("registration-challenges")
        var request = authenticatedRequest(
            url: endpoint,
            method: "POST",
            identity: identity
        )
        request.httpBody = try encoder.encode(
            PushRegistrationChallengeRequest(
                installationID: snapshot.installationID,
                apnsToken: snapshot.apnsToken
            )
        )
        let data = try await perform(request, expectedStatus: 201)
        let response: PushRegistrationChallengeResponse
        do {
            response = try decoder.decode(
                PushRegistrationChallengeResponse.self,
                from: data
            )
        } catch {
            throw PushNotificationAPIError.invalidResponse(
                Self.errorTypeCode(error)
            )
        }
        guard Self.isValidRegistrationChallenge(response) else {
            throw PushNotificationAPIError.invalidResponse(
                "registration_challenge_metadata"
            )
        }
        return response
    }

    private func createInstallation(
        snapshot: PushInstallationSnapshotRequest,
        identity: PushInstallationIdentity,
        challenge: String
    ) async throws -> PushInstallationSnapshotResponse {
        let endpoint = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("installations")
        var request = authenticatedRequest(
            url: endpoint,
            method: "POST",
            identity: identity
        )
        request.setValue(
            challenge,
            forHTTPHeaderField:
                "X-Aperture-Registration-Challenge"
        )
        request.httpBody = try encoder.encode(
            PushInstallationBootstrapRequest(
                snapshot: snapshot,
                bootstrapCredential:
                    identity.credential.base64URLString
            )
        )
        return try await snapshotResponse(for: request)
    }

    private func replace(
        snapshot: PushInstallationSnapshotRequest,
        identity: PushInstallationIdentity
    ) async throws -> PushInstallationSnapshotResponse {
        let endpoint = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("installations")
            .appendingPathComponent(identity.installationID)
        var request = authenticatedRequest(
            url: endpoint,
            method: "PUT",
            identity: identity
        )
        request.httpBody = try encoder.encode(snapshot)
        return try await snapshotResponse(for: request)
    }

    private func snapshotResponse(
        for request: URLRequest
    ) async throws -> PushInstallationSnapshotResponse {
        let data = try await perform(request)
        let response: PushInstallationSnapshotResponse
        do {
            response = try decoder.decode(
                PushInstallationSnapshotResponse.self,
                from: data
            )
        } catch {
            throw PushNotificationAPIError.invalidResponse(
                Self.errorTypeCode(error)
            )
        }
        guard Self.isValidDigest(response.snapshotDigest),
              PushServiceDate.parse(response.registeredAt) != nil,
              PushServiceDate.parse(response.serverTime) != nil else {
            throw PushNotificationAPIError.invalidResponse(
                "invalid_snapshot_metadata"
            )
        }
        return response
    }

    func deactivate(
        installationID: String,
        credential: Data
    ) async throws {
        let endpoint = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("installations")
            .appendingPathComponent(installationID)
        let identity = PushInstallationIdentity(
            installationID: installationID,
            credential: credential,
            apnsToken: nil
        )
        let request = authenticatedRequest(
            url: endpoint,
            method: "DELETE",
            identity: identity
        )
        _ = try await perform(request, allowsEmptyResponse: true)
    }

    func markOpened(
        notificationID: String,
        identity: PushInstallationIdentity
    ) async throws {
        let endpoint = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("notifications")
            .appendingPathComponent(notificationID)
            .appendingPathComponent("opened")
        let request = authenticatedRequest(
            url: endpoint,
            method: "POST",
            identity: identity
        )
        _ = try await perform(request, allowsEmptyResponse: true)
    }

    func notificationHistory(
        identity: PushInstallationIdentity,
        cursor: String? = nil
    ) async throws -> PushNotificationHistoryResponse {
        let endpoint = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("installations")
            .appendingPathComponent(identity.installationID)
            .appendingPathComponent("notifications")
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw PushNotificationAPIError
                .invalidResponse("history_url")
        }
        components.queryItems = [
            URLQueryItem(name: "limit", value: "100")
        ]
        if let cursor {
            guard Self.isValidCursor(cursor) else {
                throw PushNotificationAPIError
                    .invalidResponse("history_cursor")
            }
            components.queryItems?.append(
                URLQueryItem(name: "cursor", value: cursor)
            )
        }
        guard let url = components.url else {
            throw PushNotificationAPIError
                .invalidResponse("history_url")
        }
        let request = authenticatedRequest(
            url: url,
            method: "GET",
            identity: identity
        )
        let data = try await perform(request)
        let response: PushNotificationHistoryResponse
        do {
            response = try decoder.decode(
                PushNotificationHistoryResponse.self,
                from: data
            )
        } catch {
            throw PushNotificationAPIError.invalidResponse(
                Self.errorTypeCode(error)
            )
        }
        guard Self.isValidHistoryResponse(response) else {
            throw PushNotificationAPIError
                .invalidResponse("history_metadata")
        }
        return response
    }

    private func authenticatedRequest(
        url: URL,
        method: String,
        identity: PushInstallationIdentity
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            identity.installationID,
            forHTTPHeaderField: "X-Aperture-Installation-ID"
        )
        request.setValue(
            "Installation \(identity.credential.base64URLString)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            UUID().uuidString.lowercased(),
            forHTTPHeaderField: "X-Request-ID"
        )
        return request
    }

    private func perform(
        _ request: URLRequest,
        allowsEmptyResponse: Bool = false,
        expectedStatus: Int? = nil
    ) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requestExecutor(request)
        } catch {
            throw PushNotificationAPIError.transport(
                Self.errorTypeCode(error)
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw PushNotificationAPIError.invalidHTTPResponse
        }
        if let expectedStatus,
           200..<300 ~= http.statusCode,
           http.statusCode != expectedStatus {
            throw PushNotificationAPIError.invalidResponse(
                "unexpected_http_status_\(http.statusCode)"
            )
        }
        guard 200..<300 ~= http.statusCode else {
            throw PushNotificationAPIError.server(
                status: http.statusCode,
                code: Self.serverErrorCode(from: data)
            )
        }
        guard allowsEmptyResponse || !data.isEmpty else {
            throw PushNotificationAPIError
                .invalidResponse("empty_body")
        }
        return data
    }

    private static func serverErrorCode(from data: Data) -> String {
        guard data.count <= 16_384,
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return "unparseable"
        }
        let nested = object["error"] as? [String: Any]
        let raw = nested?["code"] as? String
            ?? object["code"] as? String
            ?? "unknown"
        return sanitized(raw)
    }

    private static func errorTypeCode(_ error: Error) -> String {
        sanitized(String(describing: type(of: error)))
    }

    private static func isAlreadyRegistered(_ error: Error) -> Bool {
        guard case let PushNotificationAPIError.server(status, code) =
                error else {
            return false
        }
        return status == 409 && code == "installation_already_registered"
    }

    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        guard case let PushNotificationAPIError.server(status, code) =
                error else {
            return false
        }
        return status == 401
            && code == "installation_authentication_failed"
    }

    private static func isRemoteUserRebindingFailure(
        _ error: Error
    ) -> Bool {
        guard case let PushNotificationAPIError.server(status, code) =
                error else {
            return false
        }
        return status == 409
            && code == "remote_user_rebinding_forbidden"
    }

    private static func isExpiredRegistrationChallenge(
        _ error: Error
    ) -> Bool {
        guard case let PushNotificationAPIError.server(status, code) =
                error else {
            return false
        }
        return status == 401
            && code == "registration_challenge_invalid_or_expired"
    }

    private static func isValidRegistrationChallenge(
        _ response: PushRegistrationChallengeResponse
    ) -> Bool {
        guard response.challenge.utf8.count == 43,
              isBase64URL(response.challenge),
              let expiresAt = PushServiceDate.parse(response.expiresAt),
              let serverTime = PushServiceDate.parse(response.serverTime)
        else {
            return false
        }
        let lifetime = expiresAt.timeIntervalSince(serverTime)
        return lifetime > 0 && lifetime <= 600
    }

    private static func isBase64URL(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_-")
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isValidDigest(_ value: String) -> Bool {
        guard (43...128).contains(value.utf8.count) else {
            return false
        }
        return isBase64URL(value)
    }

    private static func isValidCursor(_ value: String) -> Bool {
        guard (1...1_024).contains(value.utf8.count) else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_-")
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isValidHistoryResponse(
        _ response: PushNotificationHistoryResponse
    ) -> Bool {
        guard response.items.count <= 100,
              PushServiceDate.parse(response.serverTime) != nil,
              response.nextCursor.map(isValidCursor) ?? true else {
            return false
        }
        var identifiers = Set<String>()
        for item in response.items {
            let expectedTitle: String
            let allowedBodyKeys: Set<String>
            switch item.category {
            case .received:
                expectedTitle = "notification.received.title"
                allowedBodyKeys = [
                    "notification.received.body",
                    "notification.received.body.unpriced",
                    "notification.received.body.priced"
                ]
            case .sent:
                expectedTitle = "notification.sent.title"
                allowedBodyKeys = [
                    "notification.sent.body",
                    "notification.sent.body.v2"
                ]
            case .admin:
                expectedTitle = "notification.generic.title"
                allowedBodyKeys = ["notification.generic.body"]
            }
            guard UUID(uuidString: item.notificationID) != nil,
                  identifiers.insert(item.notificationID).inserted,
                  item.titleKey == expectedTitle,
                  allowedBodyKeys.contains(item.bodyKey),
                  Self.validArgumentCount(
                      item.arguments.count,
                      bodyKey: item.bodyKey,
                      category: item.category
                  ),
                  item.arguments.allSatisfy({
                      $0.utf8.count <= 256
                  }),
                  PushServiceDate.parse(item.createdAt) != nil,
                  item.sentAt == nil
                    || item.sentAt.flatMap(PushServiceDate.parse) != nil,
                  item.openedAt == nil
                    || item.openedAt.flatMap(PushServiceDate.parse)
                        != nil,
                  item.title.map({ $0.utf8.count <= 500 }) ?? true,
                  item.body.map({ $0.utf8.count <= 2_000 }) ?? true,
                  item.walletID.map({
                      !$0.isEmpty && $0.utf8.count <= 128
                  }) ?? true,
                  item.networkID.map({
                      !$0.isEmpty && $0.utf8.count <= 64
                  }) ?? true,
                  item.transactionHash.map({
                      !$0.isEmpty && $0.utf8.count <= 256
                  }) ?? true,
                  item.category != .admin
                    || (item.title != nil && item.body != nil) else {
                return false
            }
        }
        return true
    }

    private static func validArgumentCount(
        _ count: Int,
        bodyKey: String,
        category: PushNotificationCategory
    ) -> Bool {
        switch (category, bodyKey) {
        case (.received, "notification.received.body"),
             (.received, "notification.received.body.priced"),
             (.sent, "notification.sent.body"):
            count == 4
        case (.received, "notification.received.body.unpriced"),
             (.sent, "notification.sent.body.v2"):
            count == 3
        case (.admin, "notification.generic.body"):
            count <= 8
        default:
            false
        }
    }

    private static func sanitized(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_.-")
        )
        return String(
            value.unicodeScalars
                .filter { allowed.contains($0) }
                .prefix(80)
                .map(Character.init)
        )
    }
}

private extension Data {
    var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
