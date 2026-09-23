import SwiftUI
import Testing
import UIKit
@testable import Aperture

enum ICloudRestoreTestFlow: CaseIterable, Sendable {
    case onboarding, walletSwitcher
}

/// Uses the production restore screen with fixture-only discovery. No iCloud
/// account, wallet secrets, screenshots, or destructive service calls are used.
@MainActor
@Suite(.serialized)
struct NativeICloudRestoreSelectionTests {
    @Test(arguments: NativeListTestLayout.allCases, ICloudRestoreTestFlow.allCases)
    func selectionUsesNativeRowsAndTrailingToolbar(
        layout: NativeListTestLayout, flow: ICloudRestoreTestFlow
    ) async throws {
        let host = try makeHost(layout: layout, flow: flow)
        defer { host.close() }
        let list = try await loadedList(in: host)
        let navigation = try #require(host.navigationController)
        let initialDepth = navigation.viewControllers.count
        let first = IndexPath(item: 0, section: 0)
        let second = IndexPath(item: 1, section: 0)
        let originalCell = try await host.cell(at: first, in: list)

        try requireTrailingSelect(in: navigation)
        #expect(!list.isEditing)
        #expect(ICloudRestoreUIProbe.element("icloud.restore.delete", in: host.rootView) == nil)

        try ICloudRestoreUIProbe.activate("icloud.restore.select", in: host.rootView)
        try await ICloudRestoreUIProbe.wait(in: host.rootView) { list.isEditing }
        #expect(list.cellForItem(at: first) === originalCell)
        #expect(list.allowsMultipleSelectionDuringEditing)
        #expect(list.delegate?.collectionView?(list, canPerformPrimaryActionForItemAt: first) == false)
        try requireTrailingSelect(in: navigation)
        try await ICloudRestoreUIProbe.wait(in: host.rootView) {
            ICloudRestoreUIProbe.element("icloud.restore.delete", in: host.rootView) != nil
        }
        #expect(ICloudRestoreUIProbe.element("icloud.restore.delete", in: host.rootView)?
            .accessibilityTraits.contains(.notEnabled) == true)

        try await host.selectNavigationRow(first, in: list)
        try await ICloudRestoreUIProbe.wait(in: host.rootView) {
            ICloudRestoreUIProbe.element("icloud.restore.delete", in: host.rootView)?
                .accessibilityTraits.contains(.notEnabled) == false
        }
        #expect(Set(list.indexPathsForSelectedItems ?? []) == [first])
        #expect(navigation.viewControllers.count == initialDepth)

        try ICloudRestoreUIProbe.activate("icloud.restore.selectAll", in: host.rootView)
        try await ICloudRestoreUIProbe.wait(in: host.rootView) {
            Set(list.indexPathsForSelectedItems ?? []) == [first, second]
        }
        #expect(navigation.viewControllers.count == initialDepth)
        try ICloudRestoreUIProbe.activate("icloud.restore.selectAll", in: host.rootView)
        try await ICloudRestoreUIProbe.wait(in: host.rootView) {
            (list.indexPathsForSelectedItems ?? []).isEmpty
        }

        try await host.selectNavigationRow(first, in: list)
        try ICloudRestoreUIProbe.activate("icloud.restore.select", in: host.rootView)
        try await ICloudRestoreUIProbe.wait(in: host.rootView) { !list.isEditing }
        try requireTrailingSelect(in: navigation)
        #expect(navigation.viewControllers.count == initialDepth)

        // Leaving selection clears it; re-entering must never retain a deletion target.
        try ICloudRestoreUIProbe.activate("icloud.restore.select", in: host.rootView)
        try await ICloudRestoreUIProbe.wait(in: host.rootView) {
            list.isEditing && (list.indexPathsForSelectedItems ?? []).isEmpty
        }
        #expect(ICloudRestoreUIProbe.element("icloud.restore.delete", in: host.rootView)?
            .accessibilityTraits.contains(.notEnabled) == true)
    }

    @Test
    func nativeSelectionTransitionKeepsRowsAndUsesSystemMotionPreference() async throws {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let host = try makeHost()
        defer { host.close() }
        let list = try await loadedList(in: host)
        let first = IndexPath(item: 0, section: 0)
        let cell = try await host.cell(at: first, in: list)
        try await ICloudRestoreUIProbe.wait(in: host.rootView) {
            !ICloudRestoreUIProbe.hasPositionAnimation(in: cell.layer)
        }

        try ICloudRestoreUIProbe.activate("icloud.restore.select", in: host.rootView)
        var observedNativeMotion = false
        try await ICloudRestoreUIProbe.wait(in: host.rootView) {
            observedNativeMotion = observedNativeMotion
                || ICloudRestoreUIProbe.hasPositionAnimation(in: cell.layer)
            return list.isEditing && (reduceMotion || observedNativeMotion)
        }
        #expect(observedNativeMotion == !reduceMotion)
        #expect(list.cellForItem(at: first) === cell)
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad], ICloudRestoreTestFlow.allCases)
    func leavingSelectionRestoresNativeBackupNavigation(
        layout: NativeListTestLayout, flow: ICloudRestoreTestFlow
    ) async throws {
        let host = try makeHost(layout: layout, flow: flow)
        defer { host.close() }
        let list = try await loadedList(in: host)
        let navigation = try #require(host.navigationController)
        let initialDepth = navigation.viewControllers.count
        try ICloudRestoreUIProbe.activate("icloud.restore.select", in: host.rootView)
        try await ICloudRestoreUIProbe.wait(in: host.rootView) { list.isEditing }
        try ICloudRestoreUIProbe.activate("icloud.restore.select", in: host.rootView)
        try await ICloudRestoreUIProbe.wait(in: host.rootView) { !list.isEditing }

        // Selection-backed lists dispatch navigation through UIKit's primary
        // action outside editing; didSelect alone only updates the selection.
        try await host.selectRow(IndexPath(item: 0, section: 0), in: list)
        try await ICloudRestoreUIProbe.wait(in: host.rootView) {
            navigation.viewControllers.count == initialDepth + 1 && navigation.transitionCoordinator == nil
        }
        #expect(navigation.presentedViewController == nil)
    }

    @Test
    func deleteButtonUsesNativeTrashSymbolWithoutDeletingAnything() async throws {
        let host = try makeHost()
        defer { host.close() }
        let list = try await loadedList(in: host)
        let navigation = try #require(host.navigationController)
        try ICloudRestoreUIProbe.activate("icloud.restore.select", in: host.rootView)
        try await ICloudRestoreUIProbe.wait(in: host.rootView) { list.isEditing }
        try await host.selectNavigationRow(IndexPath(item: 0, section: 0), in: list)
        try await ICloudRestoreUIProbe.wait(in: host.rootView) {
            ICloudRestoreUIProbe.element("icloud.restore.delete", in: host.rootView)?
                .accessibilityTraits.contains(.notEnabled) == false
        }
        let deleteItem = try #require(navigation.topViewController?.toolbarItems?.first {
            ICloudRestoreUIProbe.matches("icloud.restore.delete", item: $0)
        })
        #expect(deleteItem.image?.isSymbolImage == true)
        #expect(deleteItem.title == WalletLocalization.string("import.icloud.delete.action"))
    }

    @Test
    func discoveryRemovalClearsSelectionAndExitsEditing() async throws {
        let discovery = makeDiscovery()
        let host = try makeHost(discovery: discovery)
        defer { host.close() }
        let list = try await loadedList(in: host)
        try ICloudRestoreUIProbe.activate("icloud.restore.select", in: host.rootView)
        try await ICloudRestoreUIProbe.wait(in: host.rootView) { list.isEditing }
        try ICloudRestoreUIProbe.activate("icloud.restore.selectAll", in: host.rootView)
        try await ICloudRestoreUIProbe.wait(in: host.rootView) {
            list.indexPathsForSelectedItems?.count == 2
        }
        // Model-only removal simulates a reconciliation, not a remote deletion.
        discovery.remove(walletIDs: Set(discovery.backupWalletIDs))
        try await ICloudRestoreUIProbe.wait(in: host.rootView) {
            !list.isEditing
                && ICloudRestoreUIProbe.element("icloud.restore.select", in: host.rootView) == nil
                && ICloudRestoreUIProbe.element("icloud.restore.delete", in: host.rootView) == nil
        }
    }

    @Test(arguments: NativeListTestLayout.allCases, ICloudRestoreTestFlow.allCases)
    func selectionKeepsBackupNamesAndDatesAvailable(
        layout: NativeListTestLayout, flow: ICloudRestoreTestFlow
    ) async throws {
        let host = try makeHost(layout: layout, flow: flow)
        defer { host.close() }
        let list = try await loadedList(in: host)
        let first = IndexPath(item: 0, section: 0)
        try ICloudRestoreUIProbe.activate("icloud.restore.select", in: host.rootView)
        try await ICloudRestoreUIProbe.wait(in: host.rootView) { list.isEditing }

        for selected in [false, true] {
            if selected { try await host.selectNavigationRow(first, in: list) }
            let cell = try await host.cell(at: first, in: list)
            let row = try #require(ICloudRestoreUIProbe.element(
                "icloud.restore.backup.restore-selection-zebra", in: cell
            ))
            #expect(!row.accessibilityTraits.contains(.notEnabled),
                    "A selectable backup must not be presented as a disabled navigation link")
            #expect(row.accessibilityLabel?.contains("Zebra Wallet") == true)
            #expect(row.accessibilityLabel?.contains(EnglishNumbers.dateTime(
                Date(timeIntervalSince1970: 1_700_000_100)
            )) == true)
            #expect(list.delegate?.collectionView?(list, canPerformPrimaryActionForItemAt: first) == false)
        }
    }

    private var backups: [WalletCloudBackupDescriptor] {
        [
            WalletCloudBackupDescriptor(
                walletID: "restore-selection-alpha", walletName: "Alpha Wallet",
                backedUpAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            WalletCloudBackupDescriptor(
                walletID: "restore-selection-zebra", walletName: "Zebra Wallet محفظة اختبار",
                backedUpAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
        ]
    }

    private func makeDiscovery() -> ICloudWalletRestoreDiscoveryModel {
        let descriptors = backups
        return ICloudWalletRestoreDiscoveryModel(loadBackups: { descriptors })
    }

    private func makeHost(
        layout: NativeListTestLayout = .phone,
        flow: ICloudRestoreTestFlow = .onboarding,
        discovery: ICloudWalletRestoreDiscoveryModel? = nil
    ) throws -> NativeListTestHost {
        let database = try WalletDatabase.temporary()
        let model = discovery ?? makeDiscovery()
        let descriptors = backups
        let switcherModel = WalletSwitcherICloudDiscoveryModel(loadBackups: { descriptors })
        return try NativeListTestHost(layout: layout) {
            switch flow {
            case .onboarding:
                ICloudRestoreNavigationFixture(database: database, discovery: model)
            case .walletSwitcher:
                WalletSwitcherRestoreNavigationFixture(database: database, discovery: switcherModel)
            }
        }
    }

    private func loadedList(in host: NativeListTestHost) async throws -> UICollectionView {
        let list = try await host.list {
            $0.numberOfSections == 1 && $0.numberOfItems(inSection: 0) == 2
        }
        try await ICloudRestoreUIProbe.wait(in: host.rootView) {
            host.navigationController?.viewControllers.count == 2
                && host.navigationController?.transitionCoordinator == nil
                && ICloudRestoreUIProbe.element("icloud.restore.select", in: host.rootView) != nil
        }
        return list
    }

    private func requireTrailingSelect(in navigation: UINavigationController) throws {
        let item = try #require(navigation.topViewController?.navigationItem)
        #expect(item.trailingItemGroups.flatMap(\.barButtonItems).contains {
            ICloudRestoreUIProbe.matches("icloud.restore.select", item: $0)
        })
        #expect(!item.leadingItemGroups.flatMap(\.barButtonItems).contains {
            ICloudRestoreUIProbe.matches("icloud.restore.select", item: $0)
        })
    }
}

private struct WalletSwitcherRestoreNavigationFixture: View {
    let database: WalletDatabase
    let discovery: WalletSwitcherICloudDiscoveryModel
    @State private var path = [WalletSwitcherNavigationRoute.setup(.restoreICloud)]

    var body: some View {
        NavigationStack(path: $path) {
            Text("import.navigation.title")
                .navigationDestination(for: WalletSwitcherNavigationRoute.self) { route in
                    switch route {
                    case .setup(.restoreICloud):
                        WalletSwitcherICloudRestoreScreen(database: database, discovery: discovery)
                    case .setup(.restoreBackup(let backup)):
                        WalletSwitcherICloudBackupScreen(
                            walletID: backup.walletID, walletName: backup.walletName,
                            backedUpAt: backup.backedUpAt, hasPassphrase: backup.hasPassphrase
                        ) { _, _, _ in
                            Issue.record("Fixture restore must not be executed by selection tests")
                        }
                    default:
                        Text("import.navigation.title")
                    }
                }
        }
    }
}

private struct ICloudRestoreNavigationFixture: View {
    let database: WalletDatabase
    let discovery: ICloudWalletRestoreDiscoveryModel
    @State private var path = ["restore"]

    var body: some View {
        NavigationStack(path: $path) {
            Text("import.navigation.title")
                .navigationDestination(for: String.self) { _ in
                    ICloudWalletRestoreView(database: database, discovery: discovery) { _, _, _ in
                        Issue.record("Fixture restore must not be executed by selection tests")
                    }
                }
        }
    }
}

@MainActor
private enum ICloudRestoreUIProbe {
    static func matches(_ identifier: String, item: UIBarButtonItem) -> Bool {
        item.accessibilityIdentifier == identifier
            || item.customView.map { element(identifier, in: $0) != nil } == true
    }

    static func element(_ identifier: String, in root: NSObject) -> NSObject? {
        var visited: Set<ObjectIdentifier> = []
        return element(identifier, in: root, visited: &visited)
    }

    static func activate(_ identifier: String, in root: NSObject) throws {
        if let rootView = root as? UIView,
           let item = barButtonItem(identifier, in: rootView),
           let selector = item.action {
            #expect(
                UIApplication.shared.sendAction(
                    selector,
                    to: item.target,
                    from: item,
                    for: nil
                )
            )
            return
        }

        let action = try #require(element(identifier, in: root), "Missing control: \(identifier)")
        #expect(!action.accessibilityTraits.contains(.notEnabled))
        #expect(action.accessibilityActivate())
    }

    static func wait(
        in view: UIView,
        sourceLocation: SourceLocation = #_sourceLocation,
        until condition: () -> Bool
    ) async throws {
        for _ in 0..<150 {
            await Task.yield()
            view.layoutIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "Native iCloud restore state did not settle", sourceLocation: sourceLocation)
    }

    static func hasPositionAnimation(in layer: CALayer) -> Bool {
        (layer.animationKeys() ?? []).contains { key in
            layer.animation(forKey: key).map(isPositionAnimation) == true
        } || (layer.sublayers ?? []).contains { hasPositionAnimation(in: $0) }
    }

    private static func isPositionAnimation(_ animation: CAAnimation) -> Bool {
        if let property = animation as? CAPropertyAnimation,
           let path = property.keyPath,
           ["position", "bounds", "transform"].contains(where: { path.hasPrefix($0) }) { return true }
        return (animation as? CAAnimationGroup)?.animations?.contains(where: isPositionAnimation) == true
    }

    private static func element(
        _ identifier: String, in object: NSObject, visited: inout Set<ObjectIdentifier>
    ) -> NSObject? {
        guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
        // Native toolbar hosting views also inherit the identifier, but their
        // accessibility child owns the actual button action. Prefer that child.
        let count = object.accessibilityElementCount()
        if count > 0, count < 1_000 {
            for index in 0..<count {
                if let child = object.accessibilityElement(at: index) as? NSObject,
                   let result = element(identifier, in: child, visited: &visited) { return result }
            }
        }
        if let view = object as? UIView {
            for child in view.subviews {
                if let result = element(identifier, in: child, visited: &visited) { return result }
            }
        }
        if object.responds(to: #selector(getter: UIView.accessibilityIdentifier)),
           object.value(forKey: "accessibilityIdentifier") as? String == identifier { return object }
        return nil
    }

    private static func barButtonItem(
        _ identifier: String,
        in rootView: UIView
    ) -> UIBarButtonItem? {
        guard let rootController = rootView.window?.rootViewController else {
            return nil
        }

        var visited = Set<ObjectIdentifier>()
        return barButtonItem(
            identifier,
            in: rootController,
            visited: &visited
        )
    }

    private static func barButtonItem(
        _ identifier: String,
        in controller: UIViewController,
        visited: inout Set<ObjectIdentifier>
    ) -> UIBarButtonItem? {
        guard visited.insert(ObjectIdentifier(controller)).inserted else {
            return nil
        }

        let navigationItems: [UIBarButtonItem] =
            controller.navigationItem.leadingItemGroups
                .flatMap(\.barButtonItems)
            + controller.navigationItem.trailingItemGroups
                .flatMap(\.barButtonItems)
            + (controller.navigationItem.leftBarButtonItems ?? [])
            + (controller.navigationItem.rightBarButtonItems ?? [])
            + (controller.toolbarItems ?? [])

        if let match = navigationItems.first(where: {
            matches(identifier, item: $0)
        }) {
            return match
        }

        if let presented = controller.presentedViewController,
           let match = barButtonItem(
               identifier,
               in: presented,
               visited: &visited
           ) {
            return match
        }

        for child in controller.children {
            if let match = barButtonItem(
                identifier,
                in: child,
                visited: &visited
            ) {
                return match
            }
        }
        return nil
    }
}
