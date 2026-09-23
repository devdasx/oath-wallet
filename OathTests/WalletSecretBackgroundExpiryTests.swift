import Foundation
import Observation
import SwiftUI
import Testing
@testable import Aperture

struct WalletSecretBackgroundExpiryTests {
    @Test(arguments: [0.0, 15.0, 19.999, 20.0, 20.001, 300.0, 3_600.0])
    func returnChecksActualAwayDuration(seconds: Double) throws {
        var state = WalletSensitiveContentLifecycleState()
        let pendingToken = state.beginContentLoad()
        let token = try #require(pendingToken)
        let loaded = state.contentDidLoad(for: token)
        #expect(loaded)
        let leftAt = ContinuousClock.now
        _ = state.protect(for: .sceneInactive, now: leftAt)
        _ = state.protect(for: .sceneBackground, now: leftAt.advanced(by: .milliseconds(10)))

        let resumed = state.resumeAfterInactive(now: leftAt.advanced(by: .seconds(seconds)))
        let expires = seconds >= 20
        #expect(resumed == !expires)
        #expect(state.hasExpired == expires)
        #expect(state.isMasked == expires)
        #expect(!state.canPublishContent(for: token))
        let accepted = state.acceptLoadedContent()
        #expect(accepted == !expires)
    }

    @Test
    func repeatedSceneEventsDoNotExtendTheDeadline() {
        var state = WalletSensitiveContentLifecycleState()
        let leftAt = ContinuousClock.now
        _ = state.protect(for: .sceneInactive, now: leftAt)
        _ = state.protect(for: .sceneBackground, now: leftAt.advanced(by: .seconds(2)))
        _ = state.protect(for: .sceneBackground, now: leftAt.advanced(by: .seconds(18)))
        _ = state.protect(for: .sceneInactive, now: leftAt.advanced(by: .seconds(19)))

        let resumed = state.resumeAfterInactive(now: leftAt.advanced(by: .seconds(20)))
        #expect(!resumed)
        #expect(state.hasExpired)
    }

    @Test
    func expiryCannotBeUndoneByAnotherActivationOrLateLoad() throws {
        var state = WalletSensitiveContentLifecycleState()
        let pendingToken = state.beginContentLoad()
        let token = try #require(pendingToken)
        let leftAt = ContinuousClock.now
        _ = state.protect(for: .sceneInactive, now: leftAt)
        let firstResume = state.resumeAfterInactive(now: leftAt.advanced(by: .seconds(21)))
        let secondResume = state.resumeAfterInactive(now: leftAt.advanced(by: .seconds(22)))
        let lateLoad = state.contentDidLoad(for: token)
        let newToken = state.beginContentLoad()
        let accepted = state.acceptLoadedContent()
        #expect(!firstResume)
        #expect(!secondResume)
        #expect(!lateLoad)
        #expect(newToken == nil)
        #expect(!accepted)
        #expect(state.isMasked)
    }

    @Test
    func separateShortAbsencesDoNotAccumulate() {
        var state = WalletSensitiveContentLifecycleState()
        let start = ContinuousClock.now
        for offset in [0, 100, 200] {
            let leftAt = start.advanced(by: .seconds(offset))
            _ = state.protect(for: .sceneBackground, now: leftAt)
            let resumed = state.resumeAfterInactive(now: leftAt.advanced(by: .seconds(19)))
            let accepted = state.acceptLoadedContent()
            #expect(resumed)
            #expect(!state.hasExpired)
            #expect(accepted)
        }
    }
}

@MainActor @Suite(.serialized)
struct WalletSecretScreenExpiryPresentationTests {
    @Test(arguments: [5.0, 300.0])
    func returningOnlyClosesExpiredSecretDestination(seconds: Double) async throws {
        let state = SecretExpiryPresentationState()
        let host = try NativeListTestHost { SecretExpiryPresentationHarness(state: state) }
        defer { host.close() }
        for _ in 0..<100 {
            host.rootView.layoutIfNeeded()
            if state.secretVisible { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(state.secretVisible)

        state.phase = .background
        for _ in 0..<100 {
            if state.lifecycle.isProtected { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(state.lifecycle.isProtected)
        // Simulate elapsed suspension without sleeping the test for five minutes.
        state.lifecycle = WalletSensitiveContentLifecycleState()
        _ = state.lifecycle.protect(for: .sceneBackground,
            now: ContinuousClock.now.advanced(by: .seconds(-seconds)))
        state.phase = .active
        for _ in 0..<100 {
            let ready = seconds >= 20 ? state.path.isEmpty : state.lifecycle.isSceneActive
            if ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(state.path == (seconds >= 20 ? [] : [1]))
        #expect(state.isSheetPresented, "Expiry must preserve the surrounding ordinary sheet")
        #expect(state.lifecycle.hasExpired == (seconds >= 20))
    }

    @Test(arguments: [5.0, 120.0])
    func secretExpiryWaitsUntilNativeLockCoverCloses(seconds: Double) async throws {
        let state = SecretExpiryPresentationState()
        let host = try NativeListTestHost { SecretExpiryPresentationHarness(state: state) }
        defer { host.close() }
        try await wait { state.secretVisible }
        try await wait {
            guard let sheet = host.rootView.window?.rootViewController?.presentedViewController else { return false }
            return !sheet.isBeingPresented && sheet.transitionCoordinator == nil
                && sheet.viewIfLoaded?.window != nil
        }
        state.phase = .inactive
        try await wait { state.lifecycle.isMasked }
        state.phase = .background
        try await wait { state.lifecycle.isProtected }
        state.isLockPresented = true
        try await wait { state.lockVisible }
        // SwiftUI onAppear precedes UIKit's presentation completion. Authenticate
        // only after the native cover is fully presented, as the real UI does.
        try await wait {
            guard let cover = host.rootView.window?.rootViewController?
                .presentedViewController?.presentedViewController else { return false }
            return !cover.isBeingPresented && cover.transitionCoordinator == nil
                && cover.viewIfLoaded?.window != nil
        }

        state.lifecycle = WalletSensitiveContentLifecycleState()
        _ = state.lifecycle.protect(for: .sceneBackground,
            now: ContinuousClock.now.advanced(by: .seconds(-seconds)))
        state.phase = .active
        try await wait { state.lifecycle.hasExpired || state.lifecycle.isSceneActive }
        #expect(state.path == [1], "Do not dismiss an ancestor while native authentication covers it")
        #expect(state.isSheetPresented)
        #expect(state.isLockPresented)

        state.isLockPresented = false
        try await wait { !state.lockVisible && (seconds >= 20 ? state.path.isEmpty : state.secretVisible) }
        #expect(state.path == (seconds >= 20 ? [] : [1]))
        #expect(state.isSheetPresented, "Only the secret destination should close")
    }

    @Test
    func secretIsMaskedImmediatelyEvenWhenPrivacyShieldIsDisabled() async throws {
        let state = SecretExpiryPresentationState()
        let host = try NativeListTestHost { SecretExpiryPresentationHarness(state: state) }
        defer { host.close() }
        try await wait { state.secretVisible }
        #expect(!state.secretMasked)
        state.phase = .inactive
        try await wait { state.secretMasked }
        #expect(state.path == [1])
        state.phase = .active
        try await wait { !state.secretMasked }
        #expect(state.path == [1])
    }

    private func wait(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ ready: () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(ready(), "Native secret presentation did not settle", sourceLocation: sourceLocation)
    }
}

@MainActor @Observable
private final class SecretExpiryPresentationState {
    var phase = ScenePhase.active
    var lifecycle = WalletSensitiveContentLifecycleState()
    var path = [1]
    var isSheetPresented = true
    var secretVisible = false
    var secretMasked = false
    var isLockPresented = false
    var lockVisible = false
}

private struct SecretExpiryPresentationHarness: View {
    @Bindable var state: SecretExpiryPresentationState

    var body: some View {
        Color.clear.sheet(isPresented: $state.isSheetPresented) {
            NavigationStack(path: $state.path) {
                Text(verbatim: "Parent")
                    .navigationDestination(for: Int.self) { _ in
                        Text(verbatim: "No real secret material")
                            .walletSensitiveValue()
                            .background {
                                SecretMaskProbe { state.secretMasked = $0 }
                            }
                            .walletSecretScreenExpiry(lifecycle: $state.lifecycle)
                            .onAppear { state.secretVisible = true }
                            .onDisappear { state.secretVisible = false }
                    }
            }
            .environment(\.walletAppLockIsPresented, state.isLockPresented || state.lockVisible)
            .fullScreenCover(isPresented: $state.isLockPresented, onDismiss: { state.lockVisible = false }) {
                Text(verbatim: "Native authentication cover fixture")
                    .onAppear { state.lockVisible = true }
            }
            .environment(\.scenePhase, state.phase)
            .environment(\.walletPrivacyShieldEnabled, false)
        }
    }
}

@MainActor @Suite(.serialized)
struct WalletCompletedFlowResumeTests {
    @Test(arguments: CompletedResumeDestination.allCases, [NativeListTestLayout.phone, .largeTextRTL])
    func completedWalletSheetSurvivesBackgroundWithRecoveryScreenInHistory(
        destination: CompletedResumeDestination, layout: NativeListTestLayout
    ) async throws {
        let state = CompletedWalletResumeState()
        let host = try NativeListTestHost(layout: layout) {
            CompletedWalletResumeHarness(state: state, destination: destination)
        }
        defer { host.close() }
        try await settle { state.recoveryVisible }
        state.path = [1]
        try await settle { state.successVisible && !state.recoveryVisible }

        for seconds in [120, 300] {
            state.phase = .inactive
            try await Task.sleep(for: .milliseconds(80))
            state.phase = .background
            try await Task.sleep(for: .milliseconds(80))
            state.now = state.now.advanced(by: .seconds(seconds))
            state.phase = .active
            try await Task.sleep(for: .milliseconds(700))
            #expect(state.isSheetPresented)
            #expect(state.successVisible)
        }

        #expect(state.isSheetPresented, "An off-screen recovery destination must not dismiss the success sheet")
        #expect(state.successVisible)
        #expect(state.path == [1])
        #expect(host.rootView.window?.rootViewController?.presentedViewController != nil)
        #expect(Set(state.destinationIdentities).count == 1, "The destination's local SwiftUI state must survive")
    }

    private func settle(_ ready: () -> Bool) async throws {
        for _ in 0..<100 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(ready(), "Native navigation did not settle")
    }
}

@MainActor @Observable
private final class CompletedWalletResumeState {
    var phase = ScenePhase.active
    var now = ContinuousClock.now
    var path = [Int]()
    var isSheetPresented = true
    var recoveryVisible = false
    var successVisible = false
    var destinationIdentities: [UUID] = []
}

enum CompletedResumeDestination: String, CaseIterable, Sendable {
    case created, imported, restored, ordinaryDetails
}

private struct CompletedWalletResumeHarness: View {
    @Bindable var state: CompletedWalletResumeState
    let destination: CompletedResumeDestination

    var body: some View {
        Color.clear.sheet(isPresented: $state.isSheetPresented) {
            NavigationStack(path: $state.path) {
                // No key generation, persistence, or real recovery material.
                SettingsWalletCreationRecoveryScreen(
                    words: Array(repeating: "test", count: 12),
                    hasPassphrase: false, isSaving: false,
                    onManagePassphrase: {}, onContinue: { state.path = [1] }
                )
                .onAppear { state.recoveryVisible = true }
                .onDisappear { state.recoveryVisible = false }
                .navigationDestination(for: Int.self) { _ in
                    Group {
                        switch destination {
                        case .created:
                            SettingsWalletCreationSuccessScreen(onDone: {})
                        case .imported:
                            WalletSuccessView(kind: .imported, onContinue: {})
                        case .restored:
                            WalletSuccessView(kind: .restored, onContinue: {})
                        case .ordinaryDetails:
                            List { Text(verbatim: "Ordinary wallet details") }
                        }
                    }
                        .background {
                            RetainedDestinationProbe { state.destinationIdentities.append($0) }
                        }
                        .onAppear { state.successVisible = true }
                        .onDisappear { state.successVisible = false }
                }
            }
            .environment(\.scenePhase, state.phase)
            .environment(
                \.walletSecretScreenNow,
                // The identity carries the instant so advancing the harness's
                // clock reaches the screen through the environment's equality.
                WalletSecretScreenClock(identity: "\(state.now)", now: state.now)
            )
            .environment(\.walletPrivacyShieldEnabled, false)
        }
    }
}

private struct SecretMaskProbe: View {
    @Environment(\.walletSensitiveValuesProtected) private var isMasked
    let observe: (Bool) -> Void
    var body: some View {
        Color.clear.onChange(of: isMasked, initial: true) { _, value in observe(value) }
    }
}

private struct RetainedDestinationProbe: View {
    @State private var identity = UUID()
    let observe: (UUID) -> Void
    var body: some View { Color.clear.onAppear { observe(identity) } }
}
