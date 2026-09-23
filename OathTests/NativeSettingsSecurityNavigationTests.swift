import Observation
import SwiftUI
import Testing
import UIKit
@testable import Aperture

// Keep window-backed tests in the serialized native-list suite.
extension NativeListInteractionTests {
    @Test(arguments: [SettingsSecurityPresentationHost.home, .settings])
    func securityCanRetryAfterBackgroundBeforePasscodePresentation(
        host: SettingsSecurityPresentationHost
    ) throws {
        var state = SettingsSecurityNavigationState()
        let pendingID = state.beginAuthorization(from: host)
        let requestID = try #require(pendingID)
        state.receive(
            .requiresPasscode(.init(settings: .secureDefault, initialErrorKey: nil)),
            requestID: requestID, sceneIsActive: true
        )
        // Background arrives before SwiftUI can present the queued fallback.
        state.invalidateForBackground()
        state.resumeAfterInactive()
        #expect(state.takePendingPresentation() == nil)
        #expect(state.passcodeContext == nil)
        #expect(!state.isAwaitingAuthorization)
        #expect(state.beginAuthorization(from: host) != nil)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func securityActionKeepsSettingsVisibleUntilAuthenticationCompletes(
        layout: NativeListTestLayout
    ) async throws {
        let model = SettingsSecurityListTestModel()
        let settings = WalletSettingsStore(database: try WalletDatabase.temporary())
        let host = try NativeListTestHost(layout: layout) {
            SettingsSecurityListTestHarness(model: model)
                .environment(settings)
        }
        defer { host.close() }
        let list = try await host.list()
        let navigation = try #require(host.navigationController)
        let securityRow = IndexPath(item: 1, section: 1)

        try await host.selectRow(securityRow, in: list)
        try await settleSettingsNavigation(navigation) {
            model.authorization.isAuthorizing && model.requestCount == 1
        }
        #expect(model.requestCount == 1)
        #expect(model.path.isEmpty)
        #expect(model.appearedRoutes.isEmpty)
        #expect(navigation.viewControllers.count == 1)
        #expect(navigation.presentedViewController == nil)
        #expect(list.delegate?.collectionView?(list, shouldHighlightItemAt: securityRow) == false)
        list.delegate?.collectionView?(list, performPrimaryActionForItemAt: securityRow)
        #expect(model.requestCount == 1)

        let requestID = try #require(model.authorization.activeRequestID)
        model.authorization.receive(
            .authorized(.secureDefault), requestID: requestID, sceneIsActive: true
        )
        #expect(model.authorization.takePendingPresentation() == .security)
        model.path = [.security]
        try await settleSettingsNavigation(navigation) {
            navigation.viewControllers.count == 2
                && navigation.transitionCoordinator == nil
                && model.appearedRoutes == [.security]
        }
        #expect(model.requestCount == 1)
        #expect(navigation.topViewController?.navigationItem.hidesBackButton == false)
        #expect(navigation.presentedViewController == nil)

        navigation.popViewController(animated: false)
        try await settleSettingsNavigation(navigation) {
            navigation.viewControllers.count == 1 && model.path.isEmpty
        }
        #expect(model.requestCount == 1)

        try await host.selectRow(securityRow, in: list)
        try await settleSettingsNavigation(navigation) {
            model.requestCount == 2 && navigation.viewControllers.count == 1
                && model.authorization.isAuthorizing
        }
        #expect(model.path.isEmpty)
        #expect(model.appearedRoutes == [.security])
        #expect(model.authorization.authorizedSettings == nil)
        let failedRequestID = try #require(model.authorization.activeRequestID)
        let passcodeContext = SettingsSecurityPasscodeContext(
            settings: .secureDefault,
            initialErrorKey: "security.authentication.biometric.error"
        )
        model.authorization.receive(
            .requiresPasscode(passcodeContext),
            requestID: failedRequestID,
            sceneIsActive: true
        )
        #expect(model.authorization.takePendingPresentation() == .passcode)
        #expect(model.authorization.passcodeContext?.initialErrorKey
            == "security.authentication.biometric.error")
        #expect(model.path.isEmpty)
        #expect(navigation.viewControllers.count == 1)
        model.authorization.cancelPasscodeAuthentication()
        #expect(model.authorization.takePendingPresentation() == .settings)
        try await settleSettingsNavigation(navigation) {
            !model.authorization.isAwaitingAuthorization
        }

        try await host.selectRow(securityRow, in: list)
        try await settleSettingsNavigation(navigation) {
            model.requestCount == 3 && navigation.viewControllers.count == 1
                && model.authorization.isAuthorizing
        }
        let abandonedRequestID = try #require(model.authorization.activeRequestID)
        model.authorization.clear()
        model.authorization.receive(
            .authorized(.secureDefault), requestID: abandonedRequestID, sceneIsActive: true
        )
        #expect(model.authorization.authorizedSettings == nil)
        #expect(model.authorization.takePendingPresentation() == nil)
        #expect(model.appearedRoutes == [.security])

        try await host.selectNavigationRow(IndexPath(item: 2, section: 1), in: list)
        try await settleSettingsNavigation(navigation) {
            navigation.viewControllers.count == 2
                && navigation.transitionCoordinator == nil
                && model.path == [.appearance]
        }
        #expect(model.requestCount == 3)
        #expect(model.appearedRoutes == [.security, .appearance])
    }

    private func settleSettingsNavigation(
        _ navigation: UINavigationController,
        until isSettled: () -> Bool
    ) async throws {
        for _ in 0..<100 {
            await Task.yield()
            navigation.view.layoutIfNeeded()
            if isSettled() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(isSettled(), "Native Settings navigation did not settle")
    }
}

@MainActor
@Observable
private final class SettingsSecurityListTestModel {
    var path: [WalletSettingsSearchRoute] = []
    var authorization = SettingsSecurityNavigationState()
    var requestCount = 0
    var appearedRoutes: [WalletSettingsSearchRoute] = []

    func requestSecurityAccess() {
        guard authorization.beginAuthorization() != nil else { return }
        requestCount += 1
    }
}

private struct SettingsSecurityListTestHarness: View {
    @Bindable var model: SettingsSecurityListTestModel

    var body: some View {
        NavigationStack(
            path: SettingsSecurityNavigationPath.binding(
                to: $model.path,
                securityDidExit: { model.authorization.clear() }
            )
        ) {
            WalletSettingsView(
                isSecurityAuthorizationInProgress:
                    model.authorization.isAwaitingAuthorization,
                onSecurityRequested: model.requestSecurityAccess
            )
            .navigationDestination(for: WalletSettingsSearchRoute.self) { route in
                if route == .security && model.authorization.authorizedSettings == nil {
                    SettingsSecurityAccessUnavailableView(
                        isAwaitingAuthorization: model.authorization.isAwaitingAuthorization,
                        retry: model.requestSecurityAccess
                    )
                } else {
                    Text("common.done")
                        .navigationTitle(route == .security
                            ? Text("settings.security.title")
                            : Text("settings.appearance.title"))
                        .onAppear { model.appearedRoutes.append(route) }
                }
            }
        }
    }
}
