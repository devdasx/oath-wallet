import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
import Vision
@testable import Aperture

@MainActor
struct WalletCallSafetyTests {
    @Test func hideOnlySuppressesWarningWithoutStoppingCallDetection() {
        let state = WalletCallSafetyState()
        state.callChanged(.init(id: UUID(), hasEnded: false))
        #expect(state.shouldShowWarning)
        state.hideForCurrentCalls()
        #expect(state.hasActiveCall)
        #expect(!state.shouldShowWarning)
    }

    @Test func sameCallStaysHiddenAcrossCallbacksAndForegroundRefresh() {
        let state = WalletCallSafetyState()
        let call = WalletCallSnapshot(id: UUID(), hasEnded: false)
        state.callChanged(call)
        state.hideForCurrentCalls()
        state.callChanged(call)
        state.refresh([call])
        #expect(!state.shouldShowWarning)
    }

    @Test func anotherCallWarnsEvenWhileHiddenCallIsStillActive() {
        let state = WalletCallSafetyState()
        let first = WalletCallSnapshot(id: UUID(), hasEnded: false)
        let second = WalletCallSnapshot(id: UUID(), hasEnded: false)
        state.callChanged(first)
        state.hideForCurrentCalls()
        state.callChanged(second)
        #expect(state.shouldShowWarning)
        state.hideForCurrentCalls()
        #expect(!state.shouldShowWarning)
        state.callChanged(.init(id: second.id, hasEnded: true))
        #expect(!state.shouldShowWarning)
        state.callChanged(.init(id: UUID(), hasEnded: false))
        #expect(state.shouldShowWarning)
    }

    @Test func nextCallWarnsAfterHiddenCallEnds() {
        let state = WalletCallSafetyState()
        let first = UUID()
        state.callChanged(.init(id: first, hasEnded: false))
        state.hideForCurrentCalls()
        state.callChanged(.init(id: first, hasEnded: true))
        #expect(!state.shouldShowWarning)
        state.callChanged(.init(id: UUID(), hasEnded: false))
        #expect(state.shouldShowWarning)
    }

    @Test func newCallDiscoveredOnResumeIsNotHidden() {
        let state = WalletCallSafetyState()
        state.refresh([.init(id: UUID(), hasEnded: false)])
        state.hideForCurrentCalls()
        state.refresh([.init(id: UUID(), hasEnded: false)])
        #expect(state.shouldShowWarning)
    }

    @Test func hideWithoutActiveCallCannotDisableFutureWarnings() {
        let state = WalletCallSafetyState()
        state.hideForCurrentCalls()
        #expect(!state.shouldShowWarning)
        state.refresh([.init(id: UUID(), hasEnded: false)])
        #expect(state.shouldShowWarning)
    }

    @Test func noCallShowsNoWarning() {
        let state = WalletCallSafetyState()
        #expect(!state.hasActiveCall)
        state.refresh([])
        #expect(!state.hasActiveCall)
    }

    @Test func openingDuringACallShowsWarning() {
        let state = WalletCallSafetyState()
        state.refresh([.init(id: UUID(), hasEnded: false)])
        #expect(state.hasActiveCall)
    }

    @Test func callStartAndEndUpdateWarning() {
        let state = WalletCallSafetyState()
        let id = UUID()
        state.callChanged(.init(id: id, hasEnded: false))
        #expect(state.hasActiveCall)
        state.callChanged(.init(id: id, hasEnded: true))
        #expect(!state.hasActiveCall)
    }

    @Test func endingOneOfMultipleCallsKeepsWarning() {
        let state = WalletCallSafetyState()
        let first = UUID(), second = UUID()
        state.refresh([.init(id: first, hasEnded: false), .init(id: second, hasEnded: false)])
        state.callChanged(.init(id: first, hasEnded: true))
        #expect(state.activeCallIDs == [second])
        state.callChanged(.init(id: second, hasEnded: true))
        #expect(!state.hasActiveCall)
    }

    @Test func foregroundRefreshClearsCallEndedWhileSuspended() {
        let state = WalletCallSafetyState()
        state.callChanged(.init(id: UUID(), hasEnded: false))
        // iOS may suspend delegate delivery; read the current snapshot on resume.
        state.refresh([])
        #expect(!state.hasActiveCall)
    }

    @Test func staleSnapshotCannotResurrectEndedCall() {
        let state = WalletCallSafetyState()
        let id = UUID()
        state.callChanged(.init(id: id, hasEnded: true))
        state.refresh([.init(id: id, hasEnded: false)])
        state.callChanged(.init(id: id, hasEnded: false))
        #expect(!state.hasActiveCall)
        let newCall = UUID()
        state.callChanged(.init(id: newCall, hasEnded: false))
        #expect(state.activeCallIDs == [newCall])
    }

    @Test func duplicateCallbacksDoNotCreateExtraCalls() {
        let state = WalletCallSafetyState()
        let call = WalletCallSnapshot(id: UUID(), hasEnded: false)
        state.callChanged(call)
        state.callChanged(call)
        #expect(state.activeCallIDs.count == 1)
        state.callChanged(.init(id: call.id, hasEnded: true))
        #expect(!state.hasActiveCall)
    }

    @Test func snapshotSeparatesEndedAndOngoingCalls() {
        let state = WalletCallSafetyState()
        let ended = UUID(), active = UUID()
        state.refresh([.init(id: ended, hasEnded: true), .init(id: active, hasEnded: false)])
        #expect(state.activeCallIDs == [active])
    }
}

/// Counts text in real rendered presentations instead of relying on SwiftUI's
/// unmaterialized accessibility tree on the iOS 27 simulator.
@MainActor @Suite(.serialized)
struct WalletCallSafetyPresentationTests {
    @Test(arguments: [NativeListTestLayout.phone, .phoneLandscape, .pad, .largeTextLTR])
    func navigationAndNestedSheetsHaveOneWarning(layout: NativeListTestLayout) async throws {
        let database = try WalletDatabase.temporary()
        let safety = WalletCallSafetyState()
        let call = UUID()
        safety.callChanged(.init(id: call, hasEnded: false))
        let state = CallSafetyPresentationFixtureState()
        let settings = WalletSettingsStore(database: database, initialSettings: .default)
        let host = try NativeListTestHost(layout: layout) {
            CallSafetyPresentationFixture(database: database, state: state)
                .environment(settings)
                .environment(\.walletCallSafety, safety)
        }
        defer { host.close() }
        let root = try #require(host.rootView.window?.rootViewController)
        try await assertBanners(1, in: root.view, name: "root-\(layout)")

        state.showsSettings = true
        let sheet = try await presentedController(on: root)
        try await assertBanners(1, in: sheet.view, name: "settings-\(layout)")
        let navigation = try #require(navigationController(in: sheet))
        state.path = [.evmAccessManager]
        try await settle { navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil }
        let destination = try #require(navigation.topViewController)
        try await assertBanners(1, in: sheet.view, name: "evm-access-\(layout)", contains: "EVM Access")

        // Hiding/ending a call must not pop the user's screen or recreate its
        // navigation controller. A subsequent call must warn again.
        safety.hideForCurrentCalls()
        try await assertBanners(0, in: sheet.view, name: "hidden-\(layout)")
        #expect(navigation.topViewController === destination)
        safety.callChanged(.init(id: call, hasEnded: true))
        safety.callChanged(.init(id: UUID(), hasEnded: false))
        try await assertBanners(1, in: sheet.view, name: "next-call-\(layout)")
        #expect(navigation.topViewController === destination)

        // This production sheet also styles itself internally. Both it and its
        // parent need one warning, never two in the same presentation.
        state.showsAddress = true
        let addressSheet = try await presentedController(on: sheet)
        try await assertBanners(1, in: addressSheet.view, name: "address-sheet-\(layout)")
        state.showsAddress = false
        try await settle { sheet.presentedViewController == nil }
        #expect(navigation.topViewController === destination)
        try await assertBanners(1, in: sheet.view, name: "returned-\(layout)")

        safety.refresh([])
        try await assertBanners(0, in: sheet.view, name: "ended-\(layout)")
        #expect(navigation.topViewController === destination)
    }

    @Test
    func repeatedBackgroundStylingDoesNotInstallAWarning() async throws {
        let database = try WalletDatabase.temporary()
        let safety = WalletCallSafetyState()
        safety.callChanged(.init(id: UUID(), hasEnded: false))
        let host = try NativeListTestHost {
            NavigationStack { EVMAccessManagerView(database: database) }
                .walletSheetBackground(nativeGlass: false)
                .walletSheetBackground(nativeGlass: false)
                .environment(WalletSettingsStore(database: database, initialSettings: .default))
                .environment(\.walletCallSafety, safety)
        }
        defer { host.close() }
        try await assertBanners(0, in: host.rootView, name: "background-only")
    }

    @Test
    func visualCheckDetectsTheOriginalDoubleBanner() async throws {
        let database = try WalletDatabase.temporary()
        let safety = WalletCallSafetyState()
        safety.callChanged(.init(id: UUID(), hasEnded: false))
        let host = try NativeListTestHost {
            NavigationStack {
                EVMAccessManagerView(database: database)
                    // Reproduce the old background helper's hidden side effect.
                    .walletCallSafetyBanner()
            }
            .walletSheetPresentation(nativeGlass: false)
            .environment(WalletSettingsStore(database: database, initialSettings: .default))
            .environment(\.walletCallSafety, safety)
        }
        defer { host.close() }
        try await assertBanners(2, in: host.rootView, name: "duplicate-control")
    }

    @Test
    func gasFundingSheetRetainsOneWarning() async throws {
        let database = try WalletDatabase.temporary()
        let safety = WalletCallSafetyState()
        safety.callChanged(.init(id: UUID(), hasEnded: false))
        let funding = try #require(EVMApprovalGasFunding(address: NativeListTestFixtures.address, networkID: "eth"))
        let host = try NativeListTestHost {
            EVMApprovalGasReceiveScreen(funding: funding)
                .walletSheetPresentation(nativeGlass: false)
                .environment(WalletSettingsStore(database: database, initialSettings: .default))
                .environment(\.walletCallSafety, safety)
        }
        defer { host.close() }
        try await assertBanners(1, in: host.rootView, name: "gas-funding")
    }

    private func assertBanners(_ count: Int, in view: UIView, name: String, contains title: String? = nil) async throws {
        try await Task.sleep(for: .milliseconds(450))
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("oath-call-banner-\(name).png")
        try image.pngData()?.write(to: path)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        let cgImage = try #require(image.cgImage)
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        let strings = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let normalized = strings.joined(separator: " ").lowercased().filter(\.isLetter)
        let phrase = "protectyourwalletduringcalls"
        let actual = normalized.components(separatedBy: phrase).count - 1
        #expect(!strings.isEmpty, "The rendered UI must contain readable text")
        #expect(actual == count, "Expected \(count) visible warnings; saw \(actual): \(strings)")
        if let title {
            #expect(normalized.contains(title.lowercased().filter(\.isLetter)), "Missing navigation title: \(strings)")
        }
        print("Call banner screenshot: \(path.path)")
    }

    private func presentedController(on parent: UIViewController) async throws -> UIViewController {
        try await settle { parent.presentedViewController != nil }
        return try #require(parent.presentedViewController)
    }

    private func settle(until ready: () -> Bool) async throws {
        for _ in 0..<150 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ready(), "Native presentation did not settle")
    }

    private func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.compactMap { navigationController(in: $0) }.first
    }
}

@MainActor @Observable
private final class CallSafetyPresentationFixtureState {
    var showsSettings = false
    var showsAddress = false
    var path: [WalletSettingsSearchRoute] = []
}

private struct CallSafetyPresentationFixture: View {
    let database: WalletDatabase
    @Bindable var state: CallSafetyPresentationFixtureState

    var body: some View {
        NavigationStack {
            List { Text("settings.title") }
                .walletListAppearance()
        }
        .sheet(isPresented: $state.showsSettings) {
            SettingsSheetNavigationContainer(path: $state.path, securityDidExit: {}, onClose: {}) {
                ToolsSettingsView(database: database)
            } destination: { _ in
                EVMAccessManagerView(database: database)
            }
            .walletSheetPresentation(nativeGlass: false)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .sheet(isPresented: $state.showsAddress) {
                EVMApprovalAddressDetailSheet(detail: .init(kind: .spender, value: NativeListTestFixtures.address))
                    .walletSheetPresentation()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .walletCallSafetyBanner()
    }
}
