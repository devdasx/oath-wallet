import SwiftUI
import Testing
@testable import Aperture

@MainActor
struct SettingsSecurityNavigationPathTests {
    @Test
    func requirePasscodeOptionsMatchTheNativeSettingsOrder() {
        #expect(
            WalletAutoLockDuration.allCases == [
                .immediately,
                .minute1,
                .minutes5,
                .minutes15,
                .hour1,
                .hours4
            ]
        )
        #expect(
            WalletAutoLockDuration.allCases.map(\.seconds)
                == [0, 60, 300, 900, 3_600, 14_400]
        )
    }

    @Test
    func removedLockDelaysResolveToTheClosestSupportedChoice() {
        #expect(WalletAutoLockDuration(seconds: 30) == .minute1)
        #expect(WalletAutoLockDuration(seconds: nil) == .hours4)
        #expect(WalletAutoLockDuration(seconds: 3_600) == .hour1)
        #expect(WalletAutoLockDuration(seconds: 14_400) == .hours4)
    }

    @Test(arguments: [false, true])
    func settingsAuthorizerPreservesExistingProtectionPolicy(isProtected: Bool) async {
        let settings = WalletSecuritySettings(
            appLockEnabled: isProtected,
            biometricEnabled: false,
            autoLockDuration: .minute1,
            privacyShieldEnabled: false
        )
        switch await SettingsSecurityAccessAuthorizer.prepare(settings: settings) {
        case let .authorized(authorizedSettings):
            #expect(!isProtected)
            #expect(authorizedSettings == settings)
        case let .requiresPasscode(context):
            #expect(isProtected)
            #expect(context.settings == settings)
            #expect(context.initialErrorKey == nil)
        case .cancelled:
            Issue.record("Passcode-only and unprotected settings access must not cancel itself.")
        }
    }

    @Test(arguments: [
        WalletSettingsSearchRoute.wallets, .appearance, .language,
        .currency, .notifications, .about
    ])
    func ordinarySettingsLinksKeepTheirNativePathAndTransaction(route: WalletSettingsSearchRoute) {
        let source = SettingsPathSource()
        var transaction = Transaction()
        transaction.disablesAnimations = true

        source.guardedPath.transaction(transaction).wrappedValue = [route]

        #expect(source.path == [route])
        #expect(source.requestCount == 0)
        #expect(source.receivedTransaction?.disablesAnimations == true)
    }

    @Test(arguments: [
        [WalletSettingsSearchRoute](), [.about], [.wallets]
    ])
    func securityActionRequestsAuthorizationWithoutPublishingItsNativePath(currentPath: [WalletSettingsSearchRoute]) {
        let source = SettingsPathSource(path: currentPath)

        source.requestSecurityAccess()

        #expect(source.path == currentPath)
        #expect(source.pathWhenAuthorizationStarted == currentPath)
        #expect(source.requestCount == 1)
    }

    @Test
    func authorizedPushDoesNotRecursivelyRequestAuthorization() {
        let source = SettingsPathSource()
        source.requestSecurityAccess()

        // Matches AppRoot's successful-authorization callback.
        source.guardedPath.wrappedValue = [.security]

        #expect(source.guardedPath.wrappedValue == [.security])
        #expect(source.requestCount == 1)
    }

    @Test
    func backAndNestedNavigationAreNotIntercepted() {
        let source = SettingsPathSource(path: [.security])
        source.guardedPath.wrappedValue = [.security, .deviceMigrationExport]
        #expect(source.path == [.security, .deviceMigrationExport])
        source.guardedPath.wrappedValue = [.security]
        #expect(source.path == [.security])
        source.guardedPath.wrappedValue = []
        #expect(source.path.isEmpty)
        #expect(source.requestCount == 0)
        #expect(source.exitCount == 1)
    }

    @Test
    func returningToSecurityRequestsFreshAuthorization() {
        let source = SettingsPathSource(path: [.security])
        source.guardedPath.wrappedValue = []
        source.requestSecurityAccess()
        #expect(source.path.isEmpty)
        source.guardedPath.wrappedValue = [.security]
        #expect(source.path == [.security])
        #expect(source.requestCount == 1)
        #expect(source.exitCount == 1)
    }

    @Test
    func successfulAuthorizationWaitsForFaceIDSceneHandoff() throws {
        var state = SettingsSecurityNavigationState()
        let pendingRequestID = state.beginAuthorization()
        let requestID = try #require(pendingRequestID)
        #expect(state.isAwaitingAuthorization)
        state.receive(.authorized(.secureDefault), requestID: requestID, sceneIsActive: false)
        #expect(state.isAwaitingAuthorization)
        #expect(state.authorizedSettings == nil)
        #expect(state.takePendingPresentation(sceneIsActive: false) == nil)
        state.resumeAfterInactive()
        #expect(!state.isAwaitingAuthorization)
        #expect(state.authorizedSettings == .secureDefault)
        #expect(state.takePendingPresentation() == .security)
    }

    @Test
    func cancellingFullScreenPasscodeReturnsToSettingsWithoutUnlocking() throws {
        var state = SettingsSecurityNavigationState()
        let pendingRequestID = state.beginAuthorization()
        let requestID = try #require(pendingRequestID)
        state.receive(
            .requiresPasscode(.init(settings: .secureDefault, initialErrorKey: nil)),
            requestID: requestID, sceneIsActive: true
        )
        #expect(state.isAwaitingAuthorization)
        #expect(state.takePendingPresentation() == .passcode)
        state.cancelPasscodeAuthentication()
        #expect(!state.isAwaitingAuthorization)
        #expect(state.authorizedSettings == nil)
        #expect(state.passcodeContext == nil)
        #expect(state.takePendingPresentation() == .settings)
    }

    @Test
    func failedLoadAndAbandonedAuthorizationNeverExposeSettings() throws {
        var state = SettingsSecurityNavigationState()
        let pendingFailedRequestID = state.beginAuthorization()
        let failedRequestID = try #require(pendingFailedRequestID)
        state.fail(requestID: failedRequestID)
        #expect(!state.isAwaitingAuthorization)
        #expect(state.authorizedSettings == nil)

        let pendingAbandonedRequestID = state.beginAuthorization()
        let abandonedRequestID = try #require(pendingAbandonedRequestID)
        state.clear()
        state.receive(.authorized(.secureDefault), requestID: abandonedRequestID, sceneIsActive: true)
        #expect(!state.isAwaitingAuthorization)
        #expect(state.authorizedSettings == nil)
        #expect(state.takePendingPresentation() == nil)
    }
}

@MainActor
private final class SettingsPathSource {
    var path: [WalletSettingsSearchRoute]
    var requestCount = 0
    var exitCount = 0
    var pathWhenAuthorizationStarted: [WalletSettingsSearchRoute]?
    var receivedTransaction: Transaction?

    init(path: [WalletSettingsSearchRoute] = []) {
        self.path = path
    }

    var guardedPath: Binding<[WalletSettingsSearchRoute]> {
        SettingsSecurityNavigationPath.binding(
            to: Binding(
                get: { self.path },
                set: { self.path = $0; self.receivedTransaction = $1 }
            ),
            securityDidExit: { self.exitCount += 1 }
        )
    }

    func requestSecurityAccess() {
        pathWhenAuthorizationStarted = path
        requestCount += 1
    }
}
