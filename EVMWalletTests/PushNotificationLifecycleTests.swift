import Foundation
import Testing
@testable import Aperture

struct PushNotificationLifecycleTests {
    @Test
    func permissionRequestWaitsForAuthorizationAndUncoveredHome() {
        var prompt = NotificationPermissionPromptState()
        let whileUnknown = prompt.claim(
            authorizationState: .unknown,
            explicitlyDisabled: false, isHomeReady: true
        )
        #expect(!whileUnknown)
        let whileCovered = prompt.claim(
            authorizationState: .notDetermined,
            explicitlyDisabled: false, isHomeReady: false
        )
        #expect(!whileCovered)
        let firstRequest = prompt.claim(
            authorizationState: .notDetermined,
            explicitlyDisabled: false, isHomeReady: true
        )
        #expect(firstRequest)
        // Scene activation and permission refresh can arrive while the system
        // dialog is outstanding. Neither may schedule another request.
        let repeatedRequest = prompt.claim(
            authorizationState: .notDetermined,
            explicitlyDisabled: false, isHomeReady: true
        )
        #expect(!repeatedRequest)
    }

    @Test(arguments: [PushAuthorizationState.denied, .authorized, .provisional, .ephemeral])
    func existingSystemDecisionsNeverPromptAgain(state: PushAuthorizationState) {
        for _ in 0..<2 {
            var newSession = NotificationPermissionPromptState()
            let requested = newSession.claim(
                authorizationState: state,
                explicitlyDisabled: false, isHomeReady: true
            )
            #expect(!requested)
        }
    }

    @Test
    func explicitOptOutIsRespectedBeforeAnySystemRequest() {
        var prompt = NotificationPermissionPromptState()
        let whileDisabled = prompt.claim(
            authorizationState: .notDetermined,
            explicitlyDisabled: true, isHomeReady: true
        )
        #expect(!whileDisabled)
        let afterOptIn = prompt.claim(
            authorizationState: .notDetermined,
            explicitlyDisabled: false, isHomeReady: true
        )
        #expect(afterOptIn)
    }

    @Test
    func onlyExplicitMissingInstallationIsIdempotent() {
        #expect(
            !PushNotificationDeactivationError.isAlreadyComplete(
                PushNotificationAPIError.credentialRejected
            )
        )
        #expect(
            !PushNotificationDeactivationError.isAlreadyComplete(
                PushNotificationAPIError.server(
                    status: 401,
                    code: "installation_authentication_failed"
                )
            )
        )
        #expect(
            !PushNotificationDeactivationError.isAlreadyComplete(
                PushNotificationAPIError.server(
                    status: 401,
                    code: "installation_authentication_required"
                )
            )
        )
        #expect(
            PushNotificationDeactivationError.isAlreadyComplete(
                PushNotificationAPIError.server(
                    status: 404,
                    code: "installation_not_found"
                )
            )
        )
        #expect(
            !PushNotificationDeactivationError.isAlreadyComplete(
                PushNotificationAPIError.transport("timed_out")
            )
        )
        #expect(
            !PushNotificationDeactivationError.isAlreadyComplete(
                PushNotificationAPIError.server(
                    status: 503,
                    code: "temporarily_unavailable"
                )
            )
        )
    }

    @Test
    func deactivationUsesAuthenticatedInstallationDelete()
        async throws {
        let recorder = PushDeactivationRequestRecorder()
        let client = try PushNotificationAPIClient(
            baseURL: URL(
                string: "https://notifications.example"
            )!,
            requestExecutor: { request in
                await recorder.execute(request)
            }
        )
        let installationID =
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let credential = Data(repeating: 0x42, count: 32)

        try await client.deactivate(
            installationID: installationID,
            credential: credential
        )

        let request = try #require(await recorder.recordedRequest())
        #expect(request.httpMethod == "DELETE")
        #expect(
            request.url?.path
                == "/v1/installations/\(installationID)"
        )
        #expect(
            request.value(
                forHTTPHeaderField: "X-Aperture-Installation-ID"
            ) == installationID
        )
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "Installation \(base64URL(credential))"
        )
        #expect(request.httpBody == nil)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private actor PushDeactivationRequestRecorder {
    private var request: URLRequest?

    func execute(
        _ request: URLRequest
    ) -> (Data, URLResponse) {
        self.request = request
        return (
            Data(),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func recordedRequest() -> URLRequest? {
        request
    }
}
