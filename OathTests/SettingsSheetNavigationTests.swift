import GRDB
import Observation
import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct SettingsSheetNavigationTests {
    @Test
    func standaloneRootIsRemovedFromItsChildPath() {
        #expect(SettingsSheetNavigationPath.relative([.security], to: .security).isEmpty)
        #expect(SettingsSheetNavigationPath.relative(
            [.security, .deviceMigrationExport], to: .security
        ) == [.deviceMigrationExport])
        #expect(SettingsSheetNavigationPath.relative(
            [.security, .deviceMigrationExport], to: .root
        ) == [.security, .deviceMigrationExport])
    }

    @Test(arguments: [WalletSettingsSearchRoute.root, .security, .backupAndKeys],
          [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func optionEntryHasCloseAndNoParentWhileChildrenCanReturn(
        route: WalletSettingsSearchRoute,
        layout: NativeListTestLayout
    ) async throws {
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        let model = SettingsSheetTestModel()
        let host = try NativeListTestHost(layout: layout) {
            SettingsSheetNavigationContainer(
                path: Binding(get: { model.path }, set: { model.path = $0 }),
                securityDidExit: { model.securityExits += 1 },
                onClose: { model.closeCount += 1 }
            ) {
                switch route {
                case .security:
                    SecuritySettingsView(database: database, initialSettings: .secureDefault)
                case .backupAndKeys:
                    SettingsBackupWalletSelectionScreen(database: database, onWalletSelected: { _ in })
                default:
                    WalletSettingsView()
                }
            } destination: { _ in
                AppearanceSettingsView()
            }
            .environment(settings)
        }
        defer { host.close() }
        _ = try await host.list()
        let navigation = try #require(host.navigationController)
        #expect(navigation.viewControllers.count == 1)
        let item = try #require(navigation.topViewController?.navigationItem)
        try #require(closeControl(in: host), "Missing Close in native bar: \(item)")
        let visibleToolbarLabels = SendEntryUIProbe.views(UILabel.self, in: navigation.navigationBar)
            .filter { !$0.isHidden && $0.alpha > 0 && $0.bounds.width > 0 }
            .compactMap(\.text)
        for key in ["common.close", "common.cancel", "common.done"] {
            #expect(!visibleToolbarLabels.contains(WalletLocalization.string(key)))
        }
        let popped = navigation.popViewController(animated: false)
        #expect(popped == nil)
        #expect(model.path.isEmpty)

        model.path = [.appearance]
        try await SendEntryUIProbe.wait(in: host.rootView) {
            navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil
        }
        navigation.popViewController(animated: false)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            model.path.isEmpty && navigation.viewControllers.count == 1 && closeControl(in: host) != nil
        }
        #expect(model.securityExits == 0)
        let close = try #require(closeControl(in: host))
        let action = try #require(close.action)
        let activated = UIApplication.shared.sendAction(action, to: close.target, from: close, for: nil)
        #expect(activated)
        #expect(model.closeCount == 1)
    }

    @Test(arguments: [1, 2], NativeListTestLayout.allCases)
    func onlyWalletShortcutIsSeparateFromExplicitSelection(
        walletCount: Int, layout: NativeListTestLayout
    ) async throws {
        let database = try WalletDatabase.temporary()
        try await database.pool.write { db in
            for index in 0..<walletCount {
                try DBWalletRecord(
                    id: "option-wallet-\(index)", profileID: WalletDatabase.defaultProfileID,
                    name: "Option Wallet \(index)", kind: DatabaseWalletKind.created.rawValue,
                    secretKeyReference: nil, isSelected: index == 0, sortOrder: index,
                    createdAt: 1, updatedAt: 1, lastOpenedAt: nil, archivedAt: nil
                ).insert(db)
            }
        }
        let settings = WalletSettingsStore(database: database)
        let automatic = ListActionRecorder<ManagedWallet>()
        let explicit = ListActionRecorder<ManagedWallet>()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SettingsBackupWalletSelectionScreen(
                    database: database,
                    onWalletSelected: { explicit.actions.append($0) },
                    onOnlyWalletSelected: { automatic.actions.append($0) }
                )
            }
            .environment(settings)
        }
        defer { host.close() }
        if walletCount == 1 {
            try await SendEntryUIProbe.wait(in: host.rootView) { automatic.actions.count == 1 }
            #expect(automatic.actions.map(\.id) == ["option-wallet-0"])
            #expect(automatic.actions.first?.name == "Option Wallet 0")
            #expect(explicit.actions.isEmpty)
        } else {
            let list = try await host.list { $0.numberOfItems(inSection: 0) == walletCount }
            #expect(automatic.actions.isEmpty)
            let cell = try await host.cell(at: IndexPath(item: 0, section: 0), in: list)
            #expect(cell.bounds.width <= list.bounds.width)
            #expect(cell.bounds.height >= 44)
            try await host.selectRow(IndexPath(item: 0, section: 0), in: list)
            #expect(explicit.actions.map(\.id) == ["option-wallet-0"])
            #expect(explicit.actions.first?.name == "Option Wallet 0")
            #expect(automatic.actions.isEmpty)
        }
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func backupTitleDoesNotDependOnDestinationDatabaseLoad(
        layout: NativeListTestLayout
    ) async throws {
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        settings.setLanguageIdentifier(layout.direction == .rightToLeft ? "ar" : "en")
        // The destination database deliberately has no wallet. A refresh failure
        // must not replace the identity already selected in the preceding screen.
        let wallet = ManagedWallet(
            id: "selected-backup-wallet", name: "Selected Wallet", kind: .created,
            address: "", fiatUSDBalance: 0, isSelected: false,
            notificationsEnabledWhenInactive: false, backupState: .notVerified,
            backupVerifiedAt: nil, iCloudBackupUpdatedAt: nil,
            mnemonicWordCount: 12, createdAt: Date(timeIntervalSince1970: 1),
            appearanceColor: .orange
        )
        let route = WalletSettingsSearchRoute.backupMaterial(wallet: wallet)
        guard case let .backupMaterial(selected) = route else {
            Issue.record("Expected the selected wallet in the backup route")
            return
        }
        #expect(selected.name == wallet.name)
        #expect(selected.appearanceColor == .orange)
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SettingsBackupMaterialSelectionScreen(
                    database: database, wallet: selected, onRecoveryPhraseSelected: {}
                )
            }
            .environment(settings)
        }
        defer { host.close() }
        _ = try await host.list()
        let item = try #require(host.navigationController?.topViewController?.navigationItem)
        #expect(item.title == EnglishNumbers.localized(
            "settings.wallets.backup.wallet.title_format", wallet.name
        ))
        #expect(item.title != WalletLocalization.string("settings.wallets.backup.section"))
    }

    private func closeControl(in host: NativeListTestHost) -> UIBarButtonItem? {
        guard let item = host.navigationController?.topViewController?.navigationItem else { return nil }
        // SwiftUI's cancellation action is a native bar item; its button
        // accessibility identifier is not forwarded to UIBarButtonItem.
        let controls = item.leadingItemGroups.flatMap(\.barButtonItems)
            + (item.leftBarButtonItems ?? [])
        var seen = Set<ObjectIdentifier>()
        let unique = controls.filter { seen.insert(ObjectIdentifier($0)).inserted }
        return unique.count == 1 ? unique.first : nil
    }
}

@MainActor
@Observable
private final class SettingsSheetTestModel {
    var path: [WalletSettingsSearchRoute] = []
    var closeCount = 0
    var securityExits = 0
}
