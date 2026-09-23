import Foundation
import UIKit
import Testing
@testable import Aperture

@MainActor
struct BiometricNavigationHandoffTests {
    @Test(arguments: [SettingsSecurityPresentationHost.home, .settings])
    func securityEntryWaitsForAuthorizationAtItsOriginalHost(
        host: SettingsSecurityPresentationHost
    ) throws {
        var state = SettingsSecurityNavigationState()
        let pendingID = state.beginAuthorization(from: host)
        let requestID = try #require(pendingID)
        #expect(state.presentationHost == host)
        #expect(state.authorizedSettings == nil)
        #expect(state.takePendingPresentation() == nil)
        #expect(state.beginAuthorization(from: host) == nil)

        state.receive(.authorized(.secureDefault), requestID: requestID, sceneIsActive: false)
        #expect(state.takePendingPresentation() == nil)
        #expect(state.beginAuthorization(from: host) == nil)
        state.resumeAfterInactive()
        #expect(state.authorizedSettings == .secureDefault)
        #expect(state.takePendingPresentation() == .security)
    }

    @Test(arguments: [SettingsSecurityPresentationHost.home, .settings], [
        WalletBiometricAuthenticationError.cancelled, .unsuccessful,
        .fallbackRequested, .unavailable, .interrupted, .busy
    ])
    func incompleteFaceIDPresentsPasscodeAtEntryPoint(
        host: SettingsSecurityPresentationHost,
        error: WalletBiometricAuthenticationError
    ) throws {
        let settings = WalletSecuritySettings(
            appLockEnabled: true, biometricEnabled: true,
            autoLockDuration: .minute1, privacyShieldEnabled: false
        )
        var state = SettingsSecurityNavigationState()
        let pendingID = state.beginAuthorization(from: host)
        let requestID = try #require(pendingID)
        let result = WalletAuthenticationAction.resolveBiometricResult(
            .failure(error), settings: settings
        )
        guard case let .requiresPasscode(context) = result else {
            Issue.record("Incomplete Face ID must fall back to the app passcode.")
            return
        }
        state.receive(.requiresPasscode(context), requestID: requestID, sceneIsActive: false)
        #expect(state.takePendingPresentation(sceneIsActive: false) == nil)
        state.resumeAfterInactive()
        #expect(state.presentationHost == host)
        #expect(state.authorizedSettings == nil)
        #expect(state.takePendingPresentation() == .passcode)
        #expect(state.isPasscodePresentationActive)
        #expect(state.beginAuthorization(from: host) == nil)

        state.acceptAfterPasscode()
        // Re-activation must not push Security underneath a dismissing cover.
        state.resumeAfterInactive()
        #expect(state.takePendingPresentation() == nil)
        state.passcodeAuthenticationDidDismiss()
        #expect(state.takePendingPresentation() == .security)
        #expect(state.authorizedSettings == settings)
        #expect(state.takePendingPresentation() == nil)
    }

    @Test(arguments: [SettingsSecurityPresentationHost.home, .settings])
    func dismissingPasscodeDoesNotAuthorizeOrChangeItsEntryPoint(
        host: SettingsSecurityPresentationHost
    ) throws {
        var state = SettingsSecurityNavigationState()
        let pendingID = state.beginAuthorization(from: host)
        let requestID = try #require(pendingID)
        state.receive(
            .requiresPasscode(.init(settings: .secureDefault, initialErrorKey: nil)),
            requestID: requestID, sceneIsActive: true
        )
        #expect(state.takePendingPresentation() == .passcode)
        state.passcodeAuthenticationDidDismiss()
        #expect(state.presentationHost == host)
        #expect(state.authorizedSettings == nil)
        #expect(state.passcodeContext == nil)
        #expect(!state.isPasscodePresentationActive)
        #expect(state.takePendingPresentation() == .settings)
        #expect(state.beginAuthorization(from: host) != nil)
    }

    @Test(arguments: [false, true])
    func settingsRejectsSuccessAfterActualBackground(invalidatedBeforeCallback: Bool) throws {
        var state = SettingsSecurityNavigationState()
        let pendingID = state.beginAuthorization()
        let requestID = try #require(pendingID)
        if invalidatedBeforeCallback { state.invalidateForBackground() }

        state.receive(
            .authorized(.secureDefault), requestID: requestID,
            sceneIsActive: false, sceneIsBackground: true
        )
        state.resumeAfterInactive()

        #expect(state.activeRequestID == nil)
        #expect(!state.isAuthorizing)
        #expect(state.authorizedSettings == nil)
        #expect(state.takePendingPresentation() == nil)
    }

    @Test
    func settingsIgnoresAnOldRequestWhenANewOneHasStarted() throws {
        var state = SettingsSecurityNavigationState()
        let oldPendingID = state.beginAuthorization()
        let oldRequestID = try #require(oldPendingID)
        state.clear()
        let newPendingID = state.beginAuthorization()
        let newRequestID = try #require(newPendingID)

        state.receive(.authorized(.secureDefault), requestID: oldRequestID, sceneIsActive: false)
        #expect(state.isAuthorizing)
        #expect(state.activeRequestID == newRequestID)
        #expect(state.authorizedSettings == nil)
        #expect(state.takePendingPresentation(sceneIsActive: false) == nil)

        state.receive(.authorized(.secureDefault), requestID: newRequestID, sceneIsActive: false)
        #expect(state.authorizedSettings == nil)
        #expect(state.takePendingPresentation(sceneIsActive: false) == nil)
        state.resumeAfterInactive()
        #expect(state.authorizedSettings == .secureDefault)
        #expect(state.takePendingPresentation() == .security)
    }

    @Test(arguments: [false, true])
    func settingsKeepsPasscodePendingUntilModalPresentationIsSafe(activeAtCallback: Bool) throws {
        var state = SettingsSecurityNavigationState()
        let pendingID = state.beginAuthorization()
        let requestID = try #require(pendingID)
        state.receive(
            .requiresPasscode(.init(settings: .secureDefault, initialErrorKey: nil)),
            requestID: requestID, sceneIsActive: activeAtCallback
        )

        // This also covers a scene becoming inactive between receiving an
        // active result and consuming its pending full-screen presentation.
        #expect(state.takePendingPresentation(sceneIsActive: false) == nil)
        #expect(state.authorizedSettings == nil)
        state.resumeAfterInactive()
        #expect(state.takePendingPresentation(sceneIsActive: true) == .passcode)
        #expect(state.takePendingPresentation() == nil)
    }

    @Test
    func settingsBackgroundDropsAQueuedPasscodeWithoutReopeningIt() throws {
        var state = SettingsSecurityNavigationState()
        let pendingID = state.beginAuthorization()
        let requestID = try #require(pendingID)
        state.receive(
            .requiresPasscode(.init(settings: .secureDefault, initialErrorKey: nil)),
            requestID: requestID, sceneIsActive: false
        )
        state.invalidateForBackground()
        state.resumeAfterInactive()
        #expect(state.passcodeContext == nil)
        #expect(state.takePendingPresentation() == nil)
    }

    @Test
    func settingsDoesNotPushAPasscodeSuccessDeliveredInBackground() throws {
        var state = SettingsSecurityNavigationState()
        let pendingID = state.beginAuthorization()
        let requestID = try #require(pendingID)
        state.receive(
            .requiresPasscode(.init(settings: .secureDefault, initialErrorKey: nil)),
            requestID: requestID, sceneIsActive: true
        )
        #expect(state.takePendingPresentation() == .passcode)
        state.acceptAfterPasscode(sceneIsBackground: true)
        state.resumeAfterInactive()
        #expect(state.authorizedSettings == nil)
        #expect(state.takePendingPresentation() == nil)
    }

    @Test
    func deviceMigrationSuccessWaitsForFaceIDDismissal() async throws {
        let authorization = try await migrationAuthorization()
        var state = DeviceMigrationExportNavigationState()
        let pendingID = state.beginAuthorization()
        let requestID = try #require(pendingID)
        state.receive(.authorized(authorization), requestID: requestID, sceneIsActive: false)

        #expect(state.authorization == nil)
        #expect(!state.isAuthorizing)
        #expect(state.takePendingPresentation(sceneIsActive: false) == nil)
        state.resumeAfterInactive()
        #expect(state.authorization != nil)
        #expect(state.takePendingPresentation() == .export)
        #expect(state.takePendingPresentation() == nil)
    }

    @Test(arguments: [false, true])
    func deviceMigrationRejectsBackgroundSuccess(invalidatedBeforeCallback: Bool) async throws {
        let authorization = try await migrationAuthorization()
        var state = DeviceMigrationExportNavigationState()
        let pendingID = state.beginAuthorization()
        let requestID = try #require(pendingID)
        if invalidatedBeforeCallback { state.invalidateForBackground() }
        state.receive(
            .authorized(authorization), requestID: requestID,
            sceneIsActive: false, sceneIsBackground: true
        )
        state.resumeAfterInactive()
        #expect(state.authorization == nil)
        #expect(state.activeRequestID == nil)
        #expect(state.takePendingPresentation() == nil)
    }

    @Test(arguments: [false, true])
    func deviceMigrationPasscodeWaitsForAUsableForegroundScene(activeAtCallback: Bool) throws {
        var state = DeviceMigrationExportNavigationState()
        let pendingID = state.beginAuthorization()
        let requestID = try #require(pendingID)
        state.receive(
            .requiresPasscode(.init(settings: .secureDefault, initialErrorKey: nil)),
            requestID: requestID, sceneIsActive: activeAtCallback
        )
        #expect(state.authorization == nil)
        #expect(state.takePendingPresentation(sceneIsActive: false) == nil)
        state.resumeAfterInactive()
        #expect(state.takePendingPresentation(sceneIsActive: true) == .passcode)
        #expect(state.takePendingPresentation() == nil)
    }

    @Test(arguments: [false, true])
    func deviceMigrationPasscodeCompletionDistinguishesInactivityFromBackground(background: Bool) async throws {
        let authorization = try await migrationAuthorization()
        var state = DeviceMigrationExportNavigationState()
        let pendingID = state.beginAuthorization()
        let requestID = try #require(pendingID)
        state.receive(
            .requiresPasscode(.init(settings: .secureDefault, initialErrorKey: nil)),
            requestID: requestID, sceneIsActive: true
        )
        #expect(state.takePendingPresentation() == .passcode)
        state.acceptAfterPasscode(authorization, sceneIsBackground: background)
        #expect(state.takePendingPresentation(sceneIsActive: false) == nil)
        state.resumeAfterInactive()
        #expect(state.takePendingPresentation() == nil)
        state.passcodeAuthenticationDidDismiss()
        #expect(state.takePendingPresentation() == (background ? nil : .export))
    }

    private func migrationAuthorization() async throws -> WalletDeviceMigrationAuthorization {
        // A real authorization fixture from an isolated, empty database. It
        // does not export wallet contents or change the running app's settings.
        let database = try WalletDatabase.temporary()
        return try await database.authorizeUnprotectedDeviceMigration()
    }
}

extension BiometricNavigationHandoffTests {
    @Test(arguments: [
        WalletBiometricAuthenticationError.cancelled, .unsuccessful,
        .fallbackRequested, .unavailable, .interrupted, .busy
    ])
    func appWideFallbackWaitsForFaceIDToDismiss(error: WalletBiometricAuthenticationError) async throws {
        let center = NotificationCenter()
        let readiness = WalletAuthenticationPresentationReadiness(
            applicationState: { .inactive }, notifications: center
        )
        let preparation = WalletAuthenticationAction.resolveBiometricResult(
            .failure(error), settings: .secureDefault
        )
        let task = Task {
            await WalletAuthenticationAction.finish(preparation) { try await readiness.wait() }
        }
        defer { task.cancel() }
        await waitForObserver(readiness)
        #expect(readiness.isWaiting)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        guard case let .requiresPasscode(context) = await task.value else {
            Issue.record("Every incomplete biometric result must retain passcode fallback.")
            return
        }
        #expect(context.settings == .secureDefault)
        #expect(!readiness.isWaiting)
    }

    @Test(arguments: [false, true])
    func backgroundOrCancellationDiscardsAuthenticationHandoff(cancelTask: Bool) async throws {
        let center = NotificationCenter()
        let readiness = WalletAuthenticationPresentationReadiness(
            applicationState: { .inactive }, notifications: center
        )
        let task = Task {
            await WalletAuthenticationAction.finish(
                WalletAuthenticationAction.resolveBiometricResult(.success(()), settings: .secureDefault)
            ) {
                try await readiness.wait()
            }
        }
        defer { task.cancel() }
        await waitForObserver(readiness)
        #expect(readiness.isWaiting)
        if cancelTask { task.cancel() }
        else { center.post(name: UIApplication.didEnterBackgroundNotification, object: nil) }
        guard case .cancelled = await task.value else {
            Issue.record("Backgrounded or cancelled authentication must not navigate.")
            return
        }
        #expect(!readiness.isWaiting)
        // A later activation must not revive the abandoned result.
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(!readiness.isWaiting)
    }

    @Test
    func successfulAuthenticationWaitsForSystemPresentationOwnership() async throws {
        let center = NotificationCenter()
        let readiness = WalletAuthenticationPresentationReadiness(
            applicationState: { .inactive }, notifications: center
        )
        let task = Task {
            await WalletAuthenticationAction.finish(
                WalletAuthenticationAction.resolveBiometricResult(.success(()), settings: .secureDefault)
            ) {
                try await readiness.wait()
            }
        }
        defer { task.cancel() }
        await waitForObserver(readiness)
        #expect(readiness.isWaiting)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        guard case .authorized = await task.value else {
            Issue.record("The verified grant should survive transient Face ID inactivity.")
            return
        }
        #expect(!readiness.isWaiting)
    }

    private func waitForObserver(_ readiness: WalletAuthenticationPresentationReadiness) async {
        for _ in 0..<100 {
            if readiness.isWaiting { return }
            await Task.yield()
        }
    }
}
