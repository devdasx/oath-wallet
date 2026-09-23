import Foundation
@testable import Aperture

extension PushNotificationRegistrationTests {
    static func challengeClient(
        server: PushRegistrationChallengeTestServer
    ) throws -> PushNotificationAPIClient {
        try PushNotificationAPIClient(
            baseURL: URL(string: "https://notifications.example")!,
            requestExecutor: { request in
                try await server.execute(request)
            }
        )
    }

    static let challengeIdentity = PushInstallationIdentity(
        installationID: "00000000-0000-4000-8000-000000000701",
        credential: Data(repeating: 0x42, count: 32),
        apnsToken: Data(repeating: 0x01, count: 32),
        remoteUserID: "00000000-0000-4000-8000-000000000702"
    )

    static let challengeSnapshot =
        PushInstallationSnapshotRequest(
            remoteUserID:
                "00000000-0000-4000-8000-000000000702",
            installationID: challengeIdentity.installationID,
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
            wallets: []
        )

    static var credentialHeaderValue: String {
        challengeIdentity.credential.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
