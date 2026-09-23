import BiometricBridge
import Foundation
import ObjectiveC
import Observation
import SwiftUI
import Testing
import UIKit
@testable import Aperture

// Opt-in: the runner enrolls simulated Face ID and restores its previous state.
// These tests use Apple's real LAContext in Simulator, never wallet secrets.
extension NativeListInteractionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APERTURE_RUN_SIMULATOR_BIOMETRICS"] == "1"))
    func faceIDSuccessHandoffToNativeSettings() async throws {
        #if targetEnvironment(simulator)
        for attempt in 1...3 {
            try await verifyFaceIDHandoff(attempt: attempt)
        }
        #endif
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["APERTURE_RUN_SIMULATOR_BIOMETRICS"] == "1"))
    func cancellingRealFaceIDDoesNotAuthorizeOrBlockTheNextRequest() async throws {
        #if targetEnvironment(simulator)
        try await waitForBiometricTestCondition {
            UIApplication.shared.applicationState == .active
        }
        let model = BiometricSettingsNavigationProbe()
        let database = try WalletDatabase.temporary()
        let host = try NativeListTestHost(layout: biometricTestLayout) {
            BiometricSettingsNavigationTestView(model: model, database: database)
                .environment(WalletSettingsStore(database: database))
        }
        defer { model.authentication?.cancel(); host.close() }
        let list = try await host.list()
        try await host.selectRow(IndexPath(item: 1, section: 1), in: list)
        try await waitForBiometricTestCondition {
            UIApplication.shared.applicationState == .inactive && model.authorization.isAuthorizing
        }
        #expect(model.path.isEmpty)
        #expect(model.appearedAt == nil)

        // A second request must not overwrite the continuation for the first.
        do {
            try await WalletBiometricAuthenticator.shared.authenticate(
                reason: WalletLocalization.string("security.authentication.settings.title")
            )
            Issue.record("Concurrent Face ID must be rejected while the first request is pending")
        } catch let error as WalletBiometricAuthenticationError {
            #expect(error == .busy)
        }
        model.authorization.clear()
        model.authentication?.cancel()
        await model.authentication?.value
        guard case .cancelled = model.lastPreparation else {
            Issue.record("Cancelling the real authentication task must not authorize Settings")
            return
        }
        #expect(model.appearedAt == nil)
        #expect(model.authorization.authorizedSettings == nil)
        #expect(model.authorization.takePendingPresentation() == nil)
        try await waitForBiometricTestCondition {
            UIApplication.shared.applicationState == .active
        }
        // A fresh, real LAContext request must still work after cancellation.
        try await verifyFaceIDHandoff(attempt: 4)
        #endif
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["APERTURE_RUN_UNENROLLED_BIOMETRICS"] == "1"))
    func unavailableFaceIDUsesNativeFullScreenPasscode() async throws {
        #if targetEnvironment(simulator)
        try #require(!WalletBiometricAuthenticator.shared.availability().isAvailable)
        let model = BiometricSettingsNavigationProbe()
        let database = try WalletDatabase.temporary()
        let host = try NativeListTestHost(layout: biometricTestLayout) {
            BiometricSettingsNavigationTestView(model: model, database: database)
                .environment(WalletSettingsStore(database: database))
        }
        defer { model.authentication?.cancel(); host.close() }
        let list = try await host.list()
        try await host.selectRow(IndexPath(item: 1, section: 1), in: list)
        let navigation = try #require(host.navigationController)
        try await waitForBiometricTestCondition {
            navigation.presentedViewController != nil
        }
        let passcode = try #require(navigation.presentedViewController)
        try await waitForBiometricTestCondition {
            passcode.viewIfLoaded?.window != nil && passcode.transitionCoordinator == nil
        }
        // SwiftUI uses overFullScreen for fullScreenCover on iOS 26. Verify
        // actual full-window coverage, not an implementation-specific enum.
        #expect([.fullScreen, .overFullScreen].contains(passcode.modalPresentationStyle))
        #expect(passcode.sheetPresentationController == nil)
        let window = try #require(passcode.view.window)
        let coveredFrame = passcode.view.convert(passcode.view.bounds, to: window)
        #expect(abs(coveredFrame.minX - window.bounds.minX) < 1)
        #expect(abs(coveredFrame.minY - window.bounds.minY) < 1)
        #expect(abs(coveredFrame.width - window.bounds.width) < 1)
        #expect(abs(coveredFrame.height - window.bounds.height) < 1)
        #expect(model.authorization.authorizedSettings == nil)
        #expect(model.appearedAt == nil)
        #expect(model.path.isEmpty)
        #expect(navigation.viewControllers.count == 1)
        #expect(model.authorization.passcodeContext?.initialErrorKey == "security.authentication.biometric.unavailable")
        passcode.dismiss(animated: false)
        #endif
    }

    private func verifyFaceIDHandoff(attempt: Int) async throws {
        try await waitForBiometricTestCondition {
            UIApplication.shared.applicationState == .active
        }
        let probe = try BiometricCallbackTimingProbe()
        defer { probe.restore() }
        let model = BiometricSettingsNavigationProbe()
        let database = try WalletDatabase.temporary()
        let host = try NativeListTestHost(layout: biometricTestLayout) {
            BiometricSettingsNavigationTestView(model: model, database: database)
                .environment(WalletSettingsStore(database: database))
        }
        defer { model.authentication?.cancel(); host.close() }
        let list = try await host.list()
        let navigation = try #require(host.navigationController)
        let availability = WalletBiometricAuthenticator.shared.availability()
        try #require(availability.isAvailable, "Runner must enroll simulated Face ID first")

        try await host.selectRow(IndexPath(item: 1, section: 1), in: list)
        try await waitForBiometricTestCondition {
            UIApplication.shared.applicationState == .inactive
                && model.authorization.isAuthorizing
        }
        #expect(model.path.isEmpty)
        #expect(model.appearedAt == nil)
        #expect(navigation.viewControllers.count == 1)

        let matchingFace = Task { @MainActor in
            while !Task.isCancelled {
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("com.apple.BiometricKit_Sim.pearl.match" as CFString),
                    nil, nil, true
                )
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { matchingFace.cancel() }
        try await waitForBiometricTestCondition {
            model.appearedAt != nil
        }
        matchingFace.cancel()
        let callbackAt = try #require(probe.succeededAt)
        let returnedAt = try #require(model.authenticationReturnedAt)
        let appearedAt = try #require(model.appearedAt)
        let returnMilliseconds = (returnedAt - callbackAt) * 1_000
        let navigationMilliseconds = (appearedAt - callbackAt) * 1_000
        print("Face ID timing: attempt=\(attempt) callback_to_return_ms=\(returnMilliseconds) callback_to_destination_ms=\(navigationMilliseconds) callback_application_state=\(probe.applicationStateAtSuccess) callback_scene_states=\(probe.sceneStatesAtSuccess)")
        #expect(navigation.viewControllers.count == 2)
        #expect(navigation.presentedViewController == nil)
        #expect(returnMilliseconds < 1_500, "Settings authorization must resume promptly after Face ID succeeds and its system UI dismisses")
        #expect(navigationMilliseconds < 1_500, "Native navigation must start promptly after Face ID succeeds and its system UI dismisses")
        // OS reactivation must not push the destination a second time. Waiting
        // for test cleanup is deliberately outside the measured handoff.
        try await waitForBiometricTestCondition {
            UIApplication.shared.applicationState == .active && navigation.transitionCoordinator == nil
        }
        model.resumeAfterInactive()
        #expect(model.path == [.security])
        #expect(model.appearanceCount == 1)
        #expect(model.authorization.takePendingPresentation() == nil)
        navigation.popViewController(animated: false)
        try await waitForBiometricTestCondition { model.path.isEmpty }
        #expect(model.authorization.authorizedSettings == nil)
    }

    private func waitForBiometricTestCondition(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        try #require(condition(), "Simulator biometric or native navigation condition did not complete")
    }

    private var biometricTestLayout: NativeListTestLayout {
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
    }
}

@MainActor
@Observable
private final class BiometricSettingsNavigationProbe {
    let settings = WalletSecuritySettings(
        appLockEnabled: true, biometricEnabled: true,
        autoLockDuration: .minute1, privacyShieldEnabled: false
    )
    var path: [WalletSettingsSearchRoute] = []
    var authorization = SettingsSecurityNavigationState()
    var authentication: Task<Void, Never>?
    var lastPreparation: SettingsSecurityDestinationPreparation?
    var authenticationReturnedAt: CFTimeInterval?
    var appearedAt: CFTimeInterval?
    var appearanceCount = 0
    var showsPasscode = false

    func requestSecurityAccess() {
        guard let requestID = authorization.beginAuthorization() else { return }
        authentication = Task { @MainActor in
            let preparation = await SettingsSecurityAccessAuthorizer.prepare(settings: settings)
            authenticationReturnedAt = CACurrentMediaTime()
            lastPreparation = preparation
            authorization.receive(
                preparation, requestID: requestID,
                sceneIsActive: UIApplication.shared.applicationState == .active,
                sceneIsBackground: UIApplication.shared.applicationState == .background
            )
            presentPendingNavigation()
        }
    }

    func resumeAfterInactive() {
        authorization.resumeAfterInactive()
        presentPendingNavigation()
    }

    private func presentPendingNavigation() {
        guard UIApplication.shared.applicationState != .background else { return }
        switch authorization.takePendingPresentation(
            sceneIsActive: UIApplication.shared.applicationState == .active
        ) {
        case .security: path = [.security]
        case .settings: path.removeAll()
        case .passcode: showsPasscode = true
        case nil: break
        }
    }
}

private struct BiometricSettingsNavigationTestView: View {
    @Bindable var model: BiometricSettingsNavigationProbe
    let database: WalletDatabase
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: SettingsSecurityNavigationPath.binding(
            to: $model.path,
            securityDidExit: { model.authorization.clear() }
        )) {
            WalletSettingsView(
                isSecurityAuthorizationInProgress:
                    model.authorization.isAwaitingAuthorization,
                onSecurityRequested: model.requestSecurityAccess
            )
                .navigationDestination(for: WalletSettingsSearchRoute.self) { _ in
                    if let settings = model.authorization.authorizedSettings {
                        SecuritySettingsView(database: database, initialSettings: settings)
                            .onAppear {
                                model.appearedAt = CACurrentMediaTime()
                                model.appearanceCount += 1
                            }
                    } else {
                        SettingsSecurityAccessUnavailableView(
                            isAwaitingAuthorization: model.authorization.isAwaitingAuthorization,
                            retry: model.requestSecurityAccess
                        )
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resumeAfterInactive() }
            if phase == .background { model.authorization.invalidateForBackground() }
        }
        .fullScreenCover(isPresented: $model.showsPasscode) {
            if model.authorization.passcodeContext != nil {
                WalletAuthenticationFullScreenContainer(title: "security.authentication.settings.title") {
                    Text("security.authentication.settings.message")
                }
            }
        }
    }
}

/// Test-only observation: calls the original Objective-C bridge method unchanged.
/// No swizzling, simulated authentication, or timing probes ship in the app.
@MainActor
private final class BiometricCallbackTimingProbe {
    private let method: Method
    private let original: IMP
    private var replacement: IMP?
    private(set) var succeededAt: CFTimeInterval?
    private(set) var applicationStateAtSuccess = -1
    private(set) var sceneStatesAtSuccess: [Int] = []

    init() throws {
        let selector = NSSelectorFromString("completeWithResult:")
        method = try #require(class_getInstanceMethod(EVMBiometricAuthenticationBridge.self, selector))
        original = method_getImplementation(method)
        typealias Implementation = @convention(c) (AnyObject, Selector, Int) -> Void
        let originalCall = unsafeBitCast(original, to: Implementation.self)
        let block: @convention(block) (AnyObject, Int) -> Void = { [weak self] bridge, result in
            MainActor.assumeIsolated {
                if result == EVMBiometricAuthenticationResult.succeeded.rawValue {
                    self?.succeededAt = CACurrentMediaTime()
                    self?.applicationStateAtSuccess = UIApplication.shared.applicationState.rawValue
                    self?.sceneStatesAtSuccess = UIApplication.shared.connectedScenes.map { $0.activationState.rawValue }
                }
                originalCall(bridge, selector, result)
            }
        }
        let replacement = imp_implementationWithBlock(block)
        self.replacement = replacement
        method_setImplementation(method, replacement)
    }

    func restore() {
        guard let replacement else { return }
        method_setImplementation(method, original)
        imp_removeBlock(replacement)
        self.replacement = nil
    }
}
