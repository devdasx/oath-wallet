import Observation
import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Observable
final class NativeWalletSwitcherTestState {
    var isPresented = true
    var path: [WalletSwitcherNavigationRoute] = []
    var dismissalCount = 0
    var completedAddresses: [String] = []
    let refreshGeneration = UUID()
}

private struct NativeWalletSwitcherTestPresentation: View {
    @Bindable var state: NativeWalletSwitcherTestState
    let database: WalletDatabase
    let services: WalletSwitcherSetupServices

    var body: some View {
        Text("common.done")
            .sheet(isPresented: $state.isPresented, onDismiss: {
                state.dismissalCount += 1
            }) {
                WalletSwitcherSheet(
                    database: database,
                    isAppSwitcherPrivacyActive: false,
                    refreshGeneration: state.refreshGeneration,
                    path: $state.path,
                    onWalletSelected: { _, _ in true },
                    onWalletAdded: {
                        state.completedAddresses.append($0)
                        return true
                    },
                    onDismissRequested: { state.isPresented = false },
                    services: services,
                    makeCloudDiscovery: {
                        WalletSwitcherICloudDiscoveryModel(
                            loadBackups: { [WalletSwitcherSetupTestFixtures.backup] },
                            reconciliationDelays: [.zero]
                        )
                    }
                ) { _ in
                    Text("settings.wallets.title")
                }
                .environment(WalletSettingsStore(database: database))
                .presentationDetents(WalletSwitcherSheetDetentPolicy.allowedDetents)
            }
    }
}

/// Hosts the real SwiftUI sheet and native navigation controller. Tests assert
/// presentation identity so a dismiss/re-present regression cannot pass.
@MainActor
final class NativeWalletSwitcherTestHost {
    let state = NativeWalletSwitcherTestState()
    let database: WalletDatabase
    let host: NativeListTestHost
    let layout: NativeListTestLayout

    init(layout: NativeListTestLayout = .phone) throws {
        self.layout = layout
        database = try WalletDatabase.temporary()
        let state = state
        let database = database
        host = try NativeListTestHost(layout: layout) {
            NativeWalletSwitcherTestPresentation(
                state: state,
                database: database,
                services: WalletSwitcherSetupTestFixtures.services()
            )
        }
    }

    var root: UIViewController? { host.rootView.window?.rootViewController }

    func close() {
        root?.presentedViewController?.dismiss(animated: false)
        host.close()
    }

    func presentation(sourceLocation: SourceLocation = #_sourceLocation) async throws -> UIViewController {
        try await settle("initial sheet", sourceLocation: sourceLocation) {
            guard let presented = self.root?.presentedViewController,
                  !presented.isBeingPresented else { return false }
            return self.navigation(in: presented)?.viewControllers.count == 1
        }
        return try #require(root?.presentedViewController)
    }

    func navigation(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        for child in controller.children {
            if let navigation = navigation(in: child) { return navigation }
        }
        return nil
    }

    func title(_ key: String) -> String {
        WalletAppLanguage.localizedBundle(
            for: layout.direction == .rightToLeft ? "ar" : "en"
        ).localizedString(forKey: key, value: nil, table: nil)
    }

    func list(
        in controller: UIViewController, rows: Int? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> UICollectionView {
        var result: UICollectionView?
        try await settle("list with \(rows.map(String.init) ?? "any") rows", sourceLocation: sourceLocation) {
            controller.view.layoutIfNeeded()
            result = self.findList(in: controller.view)
            guard let result, result.numberOfSections > 0 else { return false }
            guard let rows else { return true }
            return (0..<result.numberOfSections).contains {
                result.numberOfItems(inSection: $0) == rows
            }
        }
        return try #require(result)
    }

    func selectAction(_ action: HomeWalletAddAction, in navigation: UINavigationController) async throws {
        let controller = try #require(navigation.topViewController)
        let list = try await list(in: controller, rows: 3)
        let section = try #require((0..<list.numberOfSections).first {
            list.numberOfItems(inSection: $0) == 3
        })
        let row = try #require(HomeWalletAddAction.allCases.firstIndex(of: action))
        try await host.selectRow(IndexPath(item: row, section: section), in: list)
    }

    func assertSameSheet(_ presentation: UIViewController, navigation: UINavigationController) {
        #expect(root?.presentedViewController === presentation)
        #expect(presentation.presentedViewController == nil)
        #expect(navigation.presentedViewController == nil)
        #expect(state.isPresented)
        #expect(state.dismissalCount == 0)
    }

    func pop(
        _ navigation: UINavigationController, toDepth depth: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        navigation.popViewController(animated: false)
        try await settle("native Back to depth \(depth)", sourceLocation: sourceLocation) {
            navigation.viewControllers.count == depth
                && navigation.transitionCoordinator == nil
                && self.state.path.count == depth - 1
        }
    }

    func settle(
        _ context: String = "navigation", sourceLocation: SourceLocation = #_sourceLocation,
        until ready: () -> Bool
    ) async throws {
        for _ in 0..<200 {
            await Task.yield()
            host.rootView.layoutIfNeeded()
            root?.presentedViewController?.view.layoutIfNeeded()
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let depth = root?.presentedViewController.flatMap(navigation)?.viewControllers.count ?? 0
        try #require(
            ready(), "Did not settle: \(context), navigation depth \(depth), path count \(state.path.count)",
            sourceLocation: sourceLocation
        )
    }

    private func findList(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        for child in view.subviews {
            if let list = findList(in: child) { return list }
        }
        return nil
    }

}
