import Foundation
import Observation
import SwiftUI
import Testing
@testable import Aperture

struct WalletSensitiveContentLifecycleTests {
    @Test(arguments: [false, true])
    @MainActor
    func everyActionSkipsAuthenticationWhenAppLockIsDisabled(biometricEnabled: Bool) async {
        let settings = WalletSecuritySettings(
            appLockEnabled: false, biometricEnabled: biometricEnabled,
            autoLockDuration: .minute1, privacyShieldEnabled: false
        )
        let purposes: [WalletSecurityAuthenticationPurpose] = [
            .appUnlock, .settings, .resetAppData, .removeWallet,
            .deleteICloudBackup, .walletSensitiveData, .sendTransaction, .deviceMigrationExport
        ]
        #expect(WalletAuthenticationRequirementPolicy.requirement(
            settings: settings, availability: .init(isAvailable: true, kind: .faceID)
        ) == .none)
        for purpose in purposes {
            guard case let .authorized(grant) = await WalletAuthenticationAction.prepare(
                settings: settings, purpose: purpose
            ) else {
                Issue.record("Disabled App Lock must skip challenges for every action")
                continue
            }
            #expect(grant.permits(settings: settings))
            #expect(!grant.permits(settings: .secureDefault))
        }
    }

    @Test
    func availableEnabledBiometricsHidePasscodeUntilFallback() {
        let settings = WalletSecuritySettings(
            appLockEnabled: true,
            biometricEnabled: true,
            autoLockDuration: .minute1,
            privacyShieldEnabled: false
        )
        let availability = WalletBiometricAvailability(
            isAvailable: true,
            kind: .faceID
        )

        #expect(
            WalletAuthenticationRequirementPolicy.requirement(
                settings: settings,
                availability: availability
            ) == .biometrics
        )
    }

    @Test
    func unavailableBiometricsShowPasscodeFallback() {
        let settings = WalletSecuritySettings(
            appLockEnabled: true,
            biometricEnabled: true,
            autoLockDuration: .minute1,
            privacyShieldEnabled: false
        )
        let availability = WalletBiometricAvailability(
            isAvailable: false,
            kind: .faceID
        )

        #expect(
            WalletAuthenticationRequirementPolicy.requirement(
                settings: settings,
                availability: availability
            ) == .passcode
        )
    }

    @Test
    func disabledBiometricsShowPasscodeFallback() {
        let settings = WalletSecuritySettings(
            appLockEnabled: true,
            biometricEnabled: false,
            autoLockDuration: .minute1,
            privacyShieldEnabled: false
        )
        let availability = WalletBiometricAvailability(
            isAvailable: true,
            kind: .faceID
        )

        #expect(
            WalletAuthenticationRequirementPolicy.requirement(
                settings: settings,
                availability: availability
            ) == .passcode
        )
    }

    @Test
    func disabledProtectionRequiresNoActionAuthentication() {
        let settings = WalletSecuritySettings(
            appLockEnabled: false,
            biometricEnabled: false,
            autoLockDuration: .minute1,
            privacyShieldEnabled: false
        )
        let availability = WalletBiometricAvailability(
            isAvailable: false,
            kind: .generic
        )

        #expect(
            WalletAuthenticationRequirementPolicy.requirement(
                settings: settings,
                availability: availability
            ) == .none
        )
    }

    @Test
    @MainActor
    func sharedActionUsesPasscodeWhenBiometricsAreDisabled() async {
        let settings = WalletSecuritySettings(
            appLockEnabled: true,
            biometricEnabled: false,
            autoLockDuration: .minute1,
            privacyShieldEnabled: false
        )

        switch await WalletAuthenticationAction.prepare(
            settings: settings,
            purpose: .walletSensitiveData
        ) {
        case .authorized:
            Issue.record("Protected access must require the passcode.")
        case let .requiresPasscode(context):
            #expect(context.settings == settings)
            #expect(context.initialErrorKey == nil)
        case .cancelled:
            Issue.record("Passcode-only access must not be cancelled.")
        }
    }

    @Test
    @MainActor
    func sharedActionSkipsAuthenticationWhenProtectionIsDisabled()
        async {
        let settings = WalletSecuritySettings(
            appLockEnabled: false,
            biometricEnabled: false,
            autoLockDuration: .minute1,
            privacyShieldEnabled: false
        )

        switch await WalletAuthenticationAction.prepare(
            settings: settings,
            purpose: .walletSensitiveData
        ) {
        case let .authorized(grant):
            #expect(grant.permits(settings: settings))
        case .requiresPasscode:
            Issue.record("Unprotected access must not prompt for a passcode.")
        case .cancelled:
            Issue.record("Unprotected access must not be cancelled.")
        }
    }

    @Test
    @MainActor
    func passcodeOnlyActionIgnoresEnabledBiometrics() {
        let settings = biometricSettings

        switch WalletAuthenticationAction.preparePasscodeOnly(
            settings: settings
        ) {
        case .authorized:
            Issue.record("Protected destructive actions must require the passcode.")
        case let .requiresPasscode(context):
            #expect(context.settings == settings)
            #expect(context.initialErrorKey == nil)
        case .cancelled:
            Issue.record("Passcode-only authentication must not be cancelled.")
        }
    }

    @Test
    @MainActor
    func passcodeOnlyActionSkipsPromptWhenProtectionIsDisabled() {
        let settings = WalletSecuritySettings(
            appLockEnabled: false,
            biometricEnabled: false,
            autoLockDuration: .minute1,
            privacyShieldEnabled: false
        )

        switch WalletAuthenticationAction.preparePasscodeOnly(
            settings: settings
        ) {
        case let .authorized(grant):
            #expect(grant.permits(settings: settings))
        case .requiresPasscode:
            Issue.record("Unprotected destructive actions must not dead-end on passcode entry.")
        case .cancelled:
            Issue.record("Unprotected destructive actions must remain available.")
        }
    }

    @Test
    @MainActor
    func sharedActionBiometricSuccessAuthorizesWithoutPasscode() {
        let settings = biometricSettings
        let preparation = WalletAuthenticationAction
            .resolveBiometricResult(.success(()), settings: settings)

        switch preparation {
        case let .authorized(grant):
            #expect(grant.permits(settings: settings))
        case .requiresPasscode:
            Issue.record("Successful Face ID must not show passcode.")
        case .cancelled:
            Issue.record("Successful Face ID must authorize the action.")
        }
    }

    @Test
    @MainActor
    func sharedActionOnlyExplicitFallbackRequestsPasscode() {
        let settings = biometricSettings
        let preparation = WalletAuthenticationAction
            .resolveBiometricResult(
                .failure(.fallbackRequested),
                settings: settings
            )

        switch preparation {
        case .authorized:
            Issue.record("Fallback must still require authentication.")
        case let .requiresPasscode(context):
            #expect(context.settings == settings)
            #expect(context.initialErrorKey == nil)
        case .cancelled:
            Issue.record("Explicit passcode fallback must open passcode.")
        }
    }

    @Test
    @MainActor
    func sharedActionBiometricCancellationAndInterruptionOpenPasscode() {
        let settings = biometricSettings
        let fallbackErrors: [
            (WalletBiometricAuthenticationError, String?)
        ] = [
            (.cancelled, nil),
            (
                .interrupted,
                "security.authentication.biometric.unavailable"
            ),
            (
                .busy,
                "security.authentication.biometric.unavailable"
            ),
        ]

        for (error, expectedErrorKey) in fallbackErrors {
            let preparation = WalletAuthenticationAction
                .resolveBiometricResult(
                    .failure(error),
                    settings: settings
                )
            switch preparation {
            case .authorized:
                Issue.record("Interrupted Face ID must not authorize.")
            case let .requiresPasscode(context):
                #expect(context.settings == settings)
                #expect(context.initialErrorKey == expectedErrorKey)
            case .cancelled:
                Issue.record("Biometric failure must open passcode fallback.")
            }
        }
    }

    @Test
    func bitcoinWIFExportAuthorizationIsBoundToOneWallet() async throws {
        let database = try WalletDatabase.temporary()
        let authorization = try await database
            .authorizeUnprotectedSecretExport(walletID: "authorized-wallet")

        await #expect(throws: WalletSecretExportAuthorizationError.self) {
            try await database.bitcoinHDWIFForExport(
                walletID: "different-wallet",
                addressType: .bip84,
                branch: .external,
                index: 0,
                authorization: authorization
            )
        }
        await #expect(throws: WalletSecretExportAuthorizationError.self) {
            try await database
                .bitcoinSilentPaymentOutputPrivateKeyForExport(
                    walletID: "different-wallet",
                    transactionHash: String(repeating: "ab", count: 32),
                    outputIndex: 0,
                    authorization: authorization
                )
        }
    }

    private var biometricSettings: WalletSecuritySettings {
        WalletSecuritySettings(
            appLockEnabled: true,
            biometricEnabled: true,
            autoLockDuration: .minute1,
            privacyShieldEnabled: false
        )
    }

    @Test
    func privateKeyPublicationDefersWhileSceneIsInactive() {
        var state = WalletSensitiveContentLifecycleState()

        _ = state.protect(for: .sceneInactive)

        #expect(
            WalletPrivateKeyExportPublicationPolicy.decision(
                for: state
            ) == .deferUntilActive
        )

        let didResume = state.resumeAfterInactive()

        #expect(didResume)
        #expect(
            WalletPrivateKeyExportPublicationPolicy.decision(
                for: state
            ) == .publish
        )
    }

    @Test
    func privateKeyPublicationRejectsAfterRealBackgrounding() {
        var state = WalletSensitiveContentLifecycleState()

        _ = state.protect(for: .sceneBackground)

        #expect(
            WalletPrivateKeyExportPublicationPolicy.decision(
                for: state
            ) == .reject
        )
    }

    @Test
    func inactiveSceneMasksAndInvalidatesLoadedContent() throws {
        var state = WalletSensitiveContentLifecycleState()
        let pendingToken = state.beginContentLoad()
        let token = try #require(pendingToken)
        let didLoad = state.contentDidLoad(for: token)
        #expect(didLoad)

        let transition = state.protect(for: .sceneInactive)

        #expect(transition.hadLoadedContent)
        #expect(!transition.wasAlreadyProtected)
        #expect(!transition.shouldDismissPresentation)
        #expect(state.isMasked)
        #expect(!state.hasLoadedContent)
        #expect(!state.canPublishContent(for: token))

        let didResume = state.resumeAfterInactive()
        #expect(didResume)
        #expect(!state.isMasked)
        #expect(!state.canPublishContent(for: token))
    }

    @Test
    func inFlightLoadCannotPublishUntilTransientInactiveEnds() throws {
        var state = WalletSensitiveContentLifecycleState()
        let pendingToken = state.beginContentLoad()
        let token = try #require(pendingToken)

        let transition = state.protect(for: .sceneInactive)

        #expect(!transition.hadLoadedContent)
        #expect(state.isMasked)
        #expect(!state.canPublishContent(for: token))

        let didResume = state.resumeAfterInactive()
        #expect(didResume)
        #expect(state.canPublishContent(for: token))
        let didLoad = state.contentDidLoad(for: token)
        #expect(didLoad)
    }

    @Test
    func newerLoadGenerationRejectsAnOlderCompletion() throws {
        var state = WalletSensitiveContentLifecycleState()
        let pendingOlderToken = state.beginContentLoad()
        let olderToken = try #require(pendingOlderToken)
        let pendingCurrentToken = state.beginContentLoad()
        let currentToken = try #require(pendingCurrentToken)

        #expect(!state.canPublishContent(for: olderToken))
        let didLoadOlderContent = state.contentDidLoad(for: olderToken)
        #expect(!didLoadOlderContent)
        #expect(state.canPublishContent(for: currentToken))
        let didLoadCurrentContent = state.contentDidLoad(for: currentToken)
        #expect(didLoadCurrentContent)
    }

    @Test
    func backgroundProtectionMasksAndCanResumeWithoutDismissal() throws {
        var state = WalletSensitiveContentLifecycleState()
        let pendingToken = state.beginContentLoad()
        let token = try #require(pendingToken)
        let didLoad = state.contentDidLoad(for: token)
        #expect(didLoad)

        let transition = state.protect(for: .sceneBackground)

        #expect(transition.hadLoadedContent)
        #expect(!transition.shouldDismissPresentation)
        #expect(state.isProtected)
        #expect(state.isMasked)
        let didResume = state.resumeAfterInactive()
        #expect(didResume)
        #expect(!state.isProtected)
        #expect(!state.isMasked)
        #expect(state.beginContentLoad() != nil)
    }

    @Test
    func disappearanceInvalidatesWithoutRequestingAnotherDismissal()
        throws {
        var state = WalletSensitiveContentLifecycleState()
        let pendingToken = state.beginContentLoad()
        let token = try #require(pendingToken)
        let didLoad = state.contentDidLoad(for: token)
        #expect(didLoad)

        let transition = state.protect(for: .viewDisappeared)

        #expect(transition.hadLoadedContent)
        #expect(!transition.shouldDismissPresentation)
        #expect(state.isProtected)
        #expect(!state.canPublishContent(for: token))
    }

    @Test
    func repeatedBackgroundProtectionRemainsMaskedUntilActivation() {
        var state = WalletSensitiveContentLifecycleState()

        let first = state.protect(for: .sceneBackground)
        let second = state.protect(for: .sceneBackground)

        #expect(!first.wasAlreadyProtected)
        #expect(second.wasAlreadyProtected)
        #expect(!first.shouldDismissPresentation)
        #expect(!second.shouldDismissPresentation)
        let didAcceptLoadedContent = state.acceptLoadedContent()
        #expect(!didAcceptLoadedContent)
        let didResume = state.resumeAfterInactive()
        #expect(didResume)
        #expect(!state.isMasked)
    }

    @Test
    func immediateBackgroundPreservesPresentationAndShowsLock() {
        let plan = WalletSceneSecurityTransitionPlan.make(
            event: .background,
            locksImmediately: true
        )

        #expect(
            plan.actions == [
                .applyConfiguredPrivacyShield,
                .lockWallet
            ]
        )
    }

    @Test
    func delayedBackgroundPreservesPresentationWithoutShowingLock() {
        let plan = WalletSceneSecurityTransitionPlan.make(
            event: .background,
            locksImmediately: false
        )

        #expect(plan.actions == [.applyConfiguredPrivacyShield])
    }

    @Test
    func transientInactiveMasksWithoutDismissingOrLocking() {
        let plan = WalletSceneSecurityTransitionPlan.make(
            event: .inactive,
            locksImmediately: true
        )

        #expect(plan.actions == [.applyConfiguredPrivacyShield])
    }

    @Test
    func lockWaitsForEveryCoveringModalDismissal() {
        var state = WalletSensitiveLockPresentationState()
        state.modalDidPresent(.settings)
        state.modalDidPresent(.send)
        state.modalDidPresent(.homeWalletSwitcher)
        state.modalDidPresent(.homeWalletAdd)

        let didPresentImmediately = state.requestLock()
        #expect(!didPresentImmediately)
        #expect(state.isLockPending)
        let afterSettings = state.modalDidDismiss(.settings)
        let afterSend = state.modalDidDismiss(.send)
        let afterSwitcher =
            state.modalDidDismiss(.homeWalletSwitcher)
        #expect(!afterSettings)
        #expect(!afterSend)
        #expect(!afterSwitcher)
        let shouldPresentAfterDismissal =
            state.modalDidDismiss(.homeWalletAdd)
        #expect(shouldPresentAfterDismissal)
        #expect(!state.isLockPending)
    }

    @Test
    func delayedLockRequestStillWaitsForTrackedModal() {
        var state = WalletSensitiveLockPresentationState()
        state.modalDidPresent(.selectedReceiveAsset)

        let didPresentImmediately = state.requestLock()

        #expect(!didPresentImmediately)
        #expect(state.isLockPending)
        let shouldPresentAfterDismissal =
            state.modalDidDismiss(.selectedReceiveAsset)
        #expect(shouldPresentAfterDismissal)
    }

    @Test
    func lockWithoutCoveringModalCanPresentImmediately() {
        var state = WalletSensitiveLockPresentationState()

        let didPresentImmediately = state.requestLock()
        #expect(didPresentImmediately)
        #expect(!state.isLockPending)
        let shouldPresentAfterDismissal =
            state.modalDidDismiss(.notificationInbox)
        #expect(!shouldPresentAfterDismissal)
    }

    @Test
    func resettingLockPresentationDropsPendingCoordination() {
        var state = WalletSensitiveLockPresentationState()
        state.modalDidPresent(.send)
        let didPresentImmediately = state.requestLock()
        #expect(!didPresentImmediately)

        state.reset()

        #expect(!state.isLockPending)
        let shouldPresentAfterDismissal =
            state.modalDidDismiss(.send)
        #expect(!shouldPresentAfterDismissal)
    }

    @Test(arguments: WalletCoveringModalID.allCases)
    func repeatedUnlocksPreserveThePresentedSheet(modal: WalletCoveringModalID) {
        var state = WalletSensitiveLockPresentationState()
        state.modalDidPresent(modal)

        for _ in 0..<3 {
            let canLockAtRoot = state.requestLock()
            #expect(!canLockAtRoot)
            #expect(state.isPresented(modal))
            state.didUnlock()
            #expect(!state.isLockPending)
            #expect(state.isPresented(modal))
            #expect(state.hasPresentedModal)
        }

        _ = state.modalDidDismiss(modal)
        #expect(!state.hasPresentedModal)
        let canLockAtRoot = state.requestLock()
        #expect(canLockAtRoot)
    }

    @Test
    func receivePresentationCannotPublishAfterInvalidation() {
        var gate = WalletReceivePresentationGate()
        let staleToken = gate.begin()

        gate.invalidate()

        #expect(!gate.isCurrent(staleToken))
        #expect(
            !gate.canPresent(
                for: staleToken,
                isSceneActive: true,
                isWalletAccessRestricted: false,
                isTaskCancelled: false
            )
        )
    }

    @Test
    func receivePresentationRequiresActiveUnlockedSceneAndLiveTask() {
        var gate = WalletReceivePresentationGate()
        let token = gate.begin()

        #expect(
            gate.canPresent(
                for: token,
                isSceneActive: true,
                isWalletAccessRestricted: false,
                isTaskCancelled: false
            )
        )
        #expect(
            !gate.canPresent(
                for: token,
                isSceneActive: false,
                isWalletAccessRestricted: false,
                isTaskCancelled: false
            )
        )
        #expect(
            !gate.canPresent(
                for: token,
                isSceneActive: true,
                isWalletAccessRestricted: true,
                isTaskCancelled: false
            )
        )
        #expect(
            !gate.canPresent(
                for: token,
                isSceneActive: true,
                isWalletAccessRestricted: false,
                isTaskCancelled: true
            )
        )
    }

    @Test
    func settingsSecurityDoesNotPublishSettingsWhileAuthenticationIsInFlight()
        throws {
        var state = SettingsSecurityNavigationState()

        let pendingRequestID = state.beginAuthorization()
        let requestID = try #require(pendingRequestID)

        #expect(state.activeRequestID == requestID)
        #expect(state.isAuthorizing)
        #expect(state.authorizedSettings == nil)
        #expect(state.passcodeContext == nil)
        let presentation = state.takePendingPresentation()
        #expect(presentation == nil)

        let duplicateRequestID = state.beginAuthorization()
        #expect(duplicateRequestID == nil)
    }

    @Test
    func settingsSecurityFaceIDSuccessNavigatesDirectlyToSecurity()
        throws {
        var state = SettingsSecurityNavigationState()
        let pendingRequestID = state.beginAuthorization()
        let requestID = try #require(pendingRequestID)

        state.receive(
            .authorized(.secureDefault),
            requestID: requestID,
            sceneIsActive: true
        )

        #expect(!state.isAuthorizing)
        #expect(state.authorizedSettings == .secureDefault)
        #expect(state.passcodeContext == nil)
        #expect(state.takePendingPresentation() == .security)
    }

    @Test
    func cancelledSettingsAuthorizationReturnsToSettings() throws {
        var state = SettingsSecurityNavigationState()
        let pendingRequestID = state.beginAuthorization()
        let requestID = try #require(pendingRequestID)

        state.receive(
            .cancelled,
            requestID: requestID,
            sceneIsActive: true
        )

        #expect(!state.isAuthorizing)
        #expect(state.authorizedSettings == nil)
        #expect(state.passcodeContext == nil)
        #expect(state.takePendingPresentation() == .settings)
    }

    @Test
    func settingsSecurityWaitsForFaceIDSystemUIToDismissBeforePublishing()
        throws {
        var state = SettingsSecurityNavigationState()
        let pendingRequestID = state.beginAuthorization()
        let requestID = try #require(pendingRequestID)

        state.receive(
            .authorized(.secureDefault),
            requestID: requestID,
            sceneIsActive: false
        )

        let presentationBeforeResume = state.takePendingPresentation(sceneIsActive: false)
        #expect(presentationBeforeResume == nil)
        #expect(state.authorizedSettings == nil)

        state.resumeAfterInactive()

        let presentationAfterResume = state.takePendingPresentation()
        #expect(presentationAfterResume == .security)
        #expect(state.authorizedSettings == .secureDefault)
    }

    @Test
    func settingsSecurityFaceIDFailurePresentsFullScreenPasscode() throws {
        var state = SettingsSecurityNavigationState()
        let pendingRequestID = state.beginAuthorization()
        let requestID = try #require(pendingRequestID)
        let context = SettingsSecurityPasscodeContext(
            settings: .secureDefault,
            initialErrorKey: nil
        )

        state.receive(
            .requiresPasscode(context),
            requestID: requestID,
            sceneIsActive: true
        )

        #expect(state.authorizedSettings == nil)
        #expect(state.passcodeContext != nil)
        let presentation = state.takePendingPresentation()
        #expect(presentation == .passcode)
    }

    @Test
    func settingsSecurityPasscodeSuccessPresentsSecurityAfterFullScreen()
        throws {
        var state = SettingsSecurityNavigationState()
        let pendingRequestID = state.beginAuthorization()
        let requestID = try #require(pendingRequestID)
        let context = SettingsSecurityPasscodeContext(
            settings: .secureDefault,
            initialErrorKey: nil
        )
        state.receive(
            .requiresPasscode(context),
            requestID: requestID,
            sceneIsActive: true
        )
        let passcodePresentation = state.takePendingPresentation()
        #expect(passcodePresentation == .passcode)

        state.acceptAfterPasscode(sceneIsBackground: false)

        #expect(state.passcodeContext == nil)
        #expect(state.authorizedSettings == .secureDefault)
        #expect(state.takePendingPresentation() == nil)
        state.passcodeAuthenticationDidDismiss()
        let securityPresentation = state.takePendingPresentation()
        #expect(securityPresentation == .security)
    }

    @Test
    func deviceMigrationStaysOnSecurityWhileAuthenticationIsInFlight()
        throws {
        var state = DeviceMigrationExportNavigationState()

        let pendingRequestID = state.beginAuthorization()
        let requestID = try #require(pendingRequestID)

        #expect(state.activeRequestID == requestID)
        #expect(state.isAuthorizing)
        #expect(state.authorization == nil)
        #expect(state.passcodeContext == nil)
        let presentation = state.takePendingPresentation()
        #expect(presentation == nil)
    }

    @Test
    func deviceMigrationFaceIDFailurePresentsPasscodeBeforeExport()
        throws {
        var state = DeviceMigrationExportNavigationState()
        let pendingRequestID = state.beginAuthorization()
        let requestID = try #require(pendingRequestID)
        let context = DeviceMigrationExportPasscodeContext(
            settings: .secureDefault,
            initialErrorKey: nil
        )

        state.receive(
            .requiresPasscode(context),
            requestID: requestID,
            sceneIsActive: true
        )

        #expect(state.authorization == nil)
        #expect(state.passcodeContext != nil)
        let presentation = state.takePendingPresentation()
        #expect(presentation == .passcode)
    }
}

@MainActor
@Suite(.serialized)
struct WalletPrivacyMaskPresentationTests {
    @Test(arguments: [false, true])
    func expiredSecretStaysHiddenWithPrivacyDisabled(inSheet: Bool) async throws {
        let state = WalletPrivacyMaskTestState()
        state.forced = true
        let observed = ListActionRecorder<[Bool]>()
        let host = try NativeListTestHost {
            WalletPrivacyMaskTestHarness(state: state, observed: observed, inSheet: inSheet)
        }
        defer { host.close() }
        for enabled in [false, true, false] {
            state.enabled = enabled
            for _ in 0..<50 {
                host.rootView.layoutIfNeeded()
                await Task.yield()
                if observed.actions.last == [true, true] { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(observed.actions.last == [true, true])
        }
    }

    @Test(arguments: [false, true])
    func privacySettingControlsNestedMasksAndUpdatesImmediately(inSheet: Bool) async throws {
        let state = WalletPrivacyMaskTestState()
        let observed = ListActionRecorder<[Bool]>()
        let host = try NativeListTestHost {
            WalletPrivacyMaskTestHarness(state: state, observed: observed, inSheet: inSheet)
        }
        defer { host.close() }

        // Inactive, pasted, or dismissed content must remain unredacted with Privacy off.
        for enabled in [false, true, false] {
            for inherited in [false, true] {
                for local in [false, true] {
                    state.enabled = enabled
                    state.inherited = inherited
                    state.local = local
                    let expected = enabled && (inherited || local)
                    for _ in 0..<50 {
                        host.rootView.layoutIfNeeded()
                        await Task.yield()
                        if observed.actions.last == [expected, expected] { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    #expect(observed.actions.last == [expected, expected],
                            "Privacy: \(enabled), parent: \(inherited), local: \(local)")
                }
            }
        }
    }
}

@MainActor
@Observable
private final class WalletPrivacyMaskTestState {
    var enabled = false
    var inherited = false
    var local = false
    var forced = false
}

private struct WalletPrivacyMaskTestHarness: View {
    let state: WalletPrivacyMaskTestState
    let observed: ListActionRecorder<[Bool]>
    let inSheet: Bool

    var body: some View {
        Group {
            if inSheet {
                Color.clear
            } else {
                probe
            }
        }
        .sheet(isPresented: .constant(inSheet)) {
            probe
        }
        .walletSensitiveContentMask(isProtected: state.inherited, requiresProtection: state.forced)
        .environment(\.walletPrivacyShieldEnabled, state.enabled)
    }

    private var probe: some View {
        WalletPrivacyMaskTestProbe(observed: observed)
            .walletSensitiveValue()
            .walletSensitiveContentMask(isProtected: state.local)
    }
}

private struct WalletPrivacyMaskTestProbe: View {
    let observed: ListActionRecorder<[Bool]>
    @Environment(\.walletSensitiveValuesProtected) private var isProtected
    @Environment(\.redactionReasons) private var redactionReasons

    var body: some View {
        Color.clear
            .onChange(of: [isProtected, redactionReasons.contains(.placeholder)], initial: true) {
                _, value in observed.actions.append(value)
            }
    }
}
