import GRDB
import SwiftUI
import Testing
import UIKit
@testable import Aperture

extension NativeListInteractionTests {
    @Test(arguments: NativeListTestLayout.allCases, WalletIconBadgeTestCase.allCases)
    func badgedWalletTilesKeepNativeRowsAndSeparateInfoActions(
        layout: NativeListTestLayout, badges: WalletIconBadgeTestCase
    ) async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost(layout: layout) {
            List {
                Section {
                    ZStack(alignment: .trailing) {
                        // Both Wallets and the wallet-switcher sheet render this
                        // production row; the icon must not change its actions.
                        WalletSettingsManagementRow(
                            wallet: badges.wallet, walletCount: 2, isBalanceHidden: false,
                            onSelect: { recorder.actions.append("select") }
                        )
                        WalletRowInformationButton { recorder.actions.append("info") }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        defer { host.close() }
        let list = try await host.list()
        let path = IndexPath(item: 0, section: 0)
        let cell = try await host.cell(at: path, in: list)
        let iconHost = UIHostingController(rootView: WalletIdentityIcon(
            color: .cyan, isSelected: badges.isSelected, showsBackupWarning: badges.needsBackup
        ).environment(\.dynamicTypeSize, layout.textSize))
        let iconSize = iconHost.sizeThatFits(in: CGSize(width: 500, height: 500))
        #expect(cell.bounds.height >= iconSize.height)
        #expect(cell.bounds.width <= list.bounds.width)

        try await host.selectRow(path, in: list)
        #expect(recorder.actions == ["select"])
        recorder.actions.removeAll()

        let bundle = WalletAppLanguage.localizedBundle(
            for: layout.direction == .rightToLeft ? "ar" : "en"
        )
        let label = bundle.localizedString(
            forKey: "settings.wallets.wallet_settings", value: nil, table: nil
        )
        let info = try #require(host.accessibilityAction(label: label, in: cell))
        #expect(!info.accessibilityTraits.contains(.notEnabled))
        #expect(info.accessibilityActivate())
        #expect(recorder.actions == ["info"])
    }
}

enum WalletIconBadgeTestCase: CaseIterable, Sendable {
    case none, selected, needsBackup, selectedAndNeedsBackup

    var isSelected: Bool { self == .selected || self == .selectedAndNeedsBackup }
    var needsBackup: Bool { self == .needsBackup || self == .selectedAndNeedsBackup }

    var wallet: ManagedWallet {
        ManagedWallet(
            id: "wallet-icon-layout-test", name: "Wallet • محفظة طويلة للاختبار",
            kind: .created, address: NativeListTestFixtures.address,
            fiatUSDBalance: 123, isSelected: isSelected,
            notificationsEnabledWhenInactive: false,
            backupState: needsBackup ? .notVerified : .verified,
            backupVerifiedAt: nil, iCloudBackupUpdatedAt: nil,
            mnemonicWordCount: 12, createdAt: Date(timeIntervalSince1970: 1),
            appearanceColor: .cyan
        )
    }
}

@MainActor
@Suite(.serialized)
struct WalletSwitcherNativeReorderingTests {
    @Test(arguments: [NativeListTestLayout.phone, .largeTextRTL])
    func productionSwitcherSupportsNativeMoveAndSeparateActions(
        layout: NativeListTestLayout
    ) async throws {
        let database = try WalletDatabase.temporary()
        try await database.pool.write { db in
            for index in 0..<2 {
                let id = "switcher-test-\(index)"
                try DBWalletRecord(
                    id: id, profileID: WalletDatabase.defaultProfileID,
                    name: id, kind: DatabaseWalletKind.created.rawValue,
                    secretKeyReference: nil, isSelected: index == 0,
                    sortOrder: index, createdAt: 1, updatedAt: 1,
                    lastOpenedAt: nil, archivedAt: nil
                ).insert(db)
                try DBWalletAccountRecord(
                    id: "\(id):tron:0", walletID: id,
                    networkID: TronConstants.networkID,
                    address: NativeListTestFixtures.address,
                    normalizedAddress: NativeListTestFixtures.address,
                    label: nil, derivationPath: nil, accountIndex: 0,
                    publicKey: "test", isWatchOnly: false, isEnabled: true,
                    createdAt: 1, updatedAt: 1, lastSyncedAt: nil
                ).insert(db)
            }
        }
        let actions = ListActionRecorder<String>()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                WalletSwitcherView(
                    database: database, isAppSwitcherPrivacyActive: false,
                    refreshGeneration: UUID(),
                    onWalletSelected: { wallet, _ in
                        actions.actions.append(wallet.id)
                        return true
                    },
                    onWalletSettingsRequested: { actions.actions.append("info:" + $0.id) },
                    onAddWalletRequested: { _ in },
                    onDismissRequested: { actions.actions.append("dismiss") }
                )
            }
            .environment(WalletSettingsStore(database: database))
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfItems(inSection: 0) == 2 }
        let first = IndexPath(item: 0, section: 0)
        let second = IndexPath(item: 1, section: 0)
        _ = try await host.cell(at: first, in: list)
        #expect(list.dataSource?.collectionView?(list, canMoveItemAt: first) == true)
        #expect(list.dataSource?.collectionView?(
            list, canMoveItemAt: IndexPath(item: 0, section: 1)
        ) != true)

        // Exercise the native collection's move callback, not a copied model helper.
        list.dataSource?.collectionView?(list, moveItemAt: first, to: second)
        for _ in 0..<100 {
            if try await database.managedWallets().map(\.id) == ["switcher-test-1", "switcher-test-0"] { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await database.managedWallets().map(\.id) == ["switcher-test-1", "switcher-test-0"])
        #expect(actions.actions.isEmpty)
        #expect(try await database.managedWallets().first(where: \.isSelected)?.id == "switcher-test-0")

        let cell = try await host.cell(at: first, in: list)
        let label = WalletAppLanguage.localizedBundle(
            for: layout.direction == .rightToLeft ? "ar" : "en"
        ).localizedString(forKey: "settings.wallets.wallet_settings", value: nil, table: nil)
        let info = try #require(host.accessibilityAction(label: label, in: cell))
        #expect(info.accessibilityActivate())
        #expect(actions.actions == ["info:switcher-test-1"])
        actions.actions.removeAll()

        try await host.selectRow(first, in: list)
        for _ in 0..<100 {
            if actions.actions.contains("dismiss") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(actions.actions == ["switcher-test-1", "dismiss"])
        #expect(try await database.managedWallets().first(where: \.isSelected)?.id == "switcher-test-1")
    }
}

@MainActor
@Suite(.serialized)
struct WalletDetailsPresentationTests {
    @Test(arguments: [false, true])
    func statusSwitchSelectsWalletAndBackupOpensDedicatedPage(inSwitcher: Bool) async throws {
        let database = try await fixtureDatabase()
        let selected = ListActionRecorder<String>()
        let host = try makeHost(database: database, walletID: "details-1", inSwitcher: inSwitcher,
                                selected: selected)
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 5 }
        #expect(list.numberOfItems(inSection: 0) == 2) // Name and Date Added.
        #expect(list.numberOfItems(inSection: 1) == 2) // Status switch and logo color.
        #expect(list.numberOfItems(inSection: 3) == 1) // One backup navigation entry.
        let statusCell = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        let statusSwitch = try #require(SendEntryUIProbe.views(UISwitch.self, in: statusCell).first)
        #expect(!statusSwitch.isOn)
        #expect(statusSwitch.isEnabled)
        statusSwitch.setOn(true, animated: false)
        statusSwitch.sendActions(for: .valueChanged)
        for _ in 0..<100 {
            if !selected.actions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(selected.actions.count == 1)
        #expect(try await database.managedWallets().filter(\.isSelected).map(\.id) == ["details-1"])
        #expect(statusSwitch.isOn)

        try await host.selectNavigationRow(IndexPath(item: 0, section: 3), in: list)
        var backupList: UICollectionView?
        for _ in 0..<150 {
            host.rootView.layoutIfNeeded()
            if let page = host.navigationController?.topViewController?.view {
                backupList = SendEntryUIProbe.views(UICollectionView.self, in: page).first {
                    $0.numberOfSections == 1 && $0.numberOfItems(inSection: 0) == 4
                }
            }
            if backupList != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let backup = try #require(backupList)
        #expect(host.navigationController?.topViewController?.navigationItem.title ==
                WalletLocalization.string("settings.wallets.backup.wallet"))
        for row in 0..<4 {
            let cell = try await host.cell(at: IndexPath(item: row, section: 0), in: backup)
            // The native iCloud switch must be last, after all three protected actions.
            #expect(SendEntryUIProbe.views(UISwitch.self, in: cell).count == (row == 3 ? 1 : 0))
        }
    }

    @Test(arguments: [NativeListTestLayout.phone, .largeTextRTL])
    func selectedWalletAndInactiveAlertsHaveIndependentNativeSwitches(layout: NativeListTestLayout) async throws {
        let database = try await fixtureDatabase()
        let host = try makeHost(database: database, walletID: "details-0", inSwitcher: false,
                                selected: ListActionRecorder<String>(), layout: layout)
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 5 }
        let statusCell = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        let active = try #require(SendEntryUIProbe.views(UISwitch.self, in: statusCell).first)
        #expect(active.isOn)
        #expect(!active.isEnabled) // Selecting another wallet is how the active wallet changes.
        let alertCell = try await host.cell(at: IndexPath(item: 0, section: 2), in: list)
        let alerts = try #require(SendEntryUIProbe.views(UISwitch.self, in: alertCell).first)
        #expect(!alerts.isOn)
        #expect(alerts.isEnabled)
        alerts.setOn(true, animated: false)
        alerts.sendActions(for: .valueChanged)
        for _ in 0..<100 {
            if try await database.managedWallet(walletID: "details-0").notificationsEnabledWhenInactive { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await database.managedWallet(walletID: "details-0").notificationsEnabledWhenInactive)
        #expect(try await database.managedWallets().filter(\.isSelected).map(\.id) == ["details-0"])
        #expect(alertCell.bounds.width <= list.bounds.width)
    }

    private func makeHost(
        database: WalletDatabase, walletID: String, inSwitcher: Bool,
        selected: ListActionRecorder<String>, layout: NativeListTestLayout = .phone
    ) throws -> NativeListTestHost {
        try NativeListTestHost(layout: layout) {
            NavigationStack {
                if inSwitcher {
                    WalletSwitcherSettingsView(
                        database: database, walletID: walletID,
                        onWalletSelected: { selected.actions.append($0) },
                        onWalletRenamed: { _, _ in }, onWalletAppearanceChanged: { _, _ in },
                        onWalletChanged: {}, onRemoveWalletRequested: { _ in }
                    )
                } else {
                    WalletDetailSettingsView(
                        database: database, walletID: walletID,
                        onWalletSelected: { selected.actions.append($0) },
                        onWalletRenamed: { _, _ in }, onWalletAppearanceChanged: { _, _ in },
                        onWalletChanged: {}, onRemoveWalletRequested: { _ in }
                    )
                }
            }
            .environment(WalletSettingsStore(database: database))
        }
    }

    private func fixtureDatabase() async throws -> WalletDatabase {
        let database = try WalletDatabase.temporary()
        try await database.pool.write { db in
            for index in 0..<2 {
                let id = "details-\(index)"
                try DBWalletRecord(
                    id: id, profileID: WalletDatabase.defaultProfileID,
                    name: "Wallet \(index + 1)", kind: DatabaseWalletKind.created.rawValue,
                    secretKeyReference: nil, isSelected: index == 0, sortOrder: index,
                    createdAt: 1_790_000_000, updatedAt: 1_790_000_000,
                    lastOpenedAt: nil, archivedAt: nil
                ).insert(db)
                try DBWalletAccountRecord(
                    id: "\(id):tron:0", walletID: id, networkID: TronConstants.networkID,
                    address: NativeListTestFixtures.address,
                    normalizedAddress: NativeListTestFixtures.address,
                    label: nil, derivationPath: nil, accountIndex: 0,
                    publicKey: "test", isWatchOnly: false, isEnabled: true,
                    createdAt: 1, updatedAt: 1, lastSyncedAt: nil
                ).insert(db)
            }
        }
        return database
    }
}

@MainActor
@Suite(.serialized)
struct WalletDarkAppearanceTests {
    @Test
    func darkTextMaintainsContrastAcrossBaseAndElevatedSurfaces() {
        for level in [UIUserInterfaceLevel.base, .elevated] {
            for contrast in [UIAccessibilityContrast.normal, .high] {
                let traits = UITraitCollection(traitsFrom: [
                    UITraitCollection(userInterfaceStyle: .dark),
                    UITraitCollection(userInterfaceLevel: level),
                    UITraitCollection(accessibilityContrast: contrast)
                ])
                let backgrounds = [WalletSurfacePalette.background, WalletSurfacePalette.groupedBackground,
                                   WalletSurfacePalette.surface, WalletSurfacePalette.groupedSurface]
                for background in backgrounds {
                    let bg = luminance(background.resolvedColor(with: traits))
                    #expect(bg > 0) // Never a pure-black content canvas.
                    for foreground in [WalletSurfacePalette.primaryLabel, WalletSurfacePalette.secondaryLabel,
                                       WalletSurfacePalette.tertiaryLabel, WalletSurfacePalette.link] {
                        let fg = luminance(foreground.resolvedColor(with: traits))
                        #expect((max(fg, bg) + 0.05) / (min(fg, bg) + 0.05) >= 4.5)
                    }
                }
                #expect(luminance(WalletSurfacePalette.surface.resolvedColor(with: traits)) >
                        luminance(WalletSurfacePalette.background.resolvedColor(with: traits)))
            }
        }
    }

    @Test
    func lightAppearanceRetainsSystemSemanticColors() {
        for level in [UIUserInterfaceLevel.base, .elevated] {
            let traits = UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: .light),
                                                      UITraitCollection(userInterfaceLevel: level)])
            for (color, original) in [(WalletSurfacePalette.background, UIColor.systemBackground),
                                      (WalletSurfacePalette.groupedBackground, .systemGroupedBackground),
                                      (WalletSurfacePalette.groupedSurface, .secondarySystemGroupedBackground),
                                      (WalletSurfacePalette.primaryLabel, .label),
                                      (WalletSurfacePalette.secondaryLabel, .secondaryLabel)] {
                #expect(color.resolvedColor(with: traits) == original.resolvedColor(with: traits))
            }
        }
    }

    @Test
    func nativeListRendersCharcoalRowsAndPreservesTransparentHero() async throws {
        let host = try NativeListTestHost(layout: .pad, size: NativeListTestLayout.phone.size) {
            NavigationStack {
                List {
                    Group {
                        Section {
                            Text("settings.wallets.title")
                                .foregroundStyle(WalletTheme.primaryLabel)
                        }
                        Section {
                            Text("settings.wallets.details.section")
                                .foregroundStyle(WalletTheme.primaryLabel)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .walletListRowSurface()
                }
                .walletListAppearance()
                .listStyle(.insetGrouped)
            }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 2 }
        let row = try await host.cell(at: IndexPath(item: 0, section: 0), in: list)
        let hero = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        host.rootView.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.rootView.bounds).image { _ in
            host.rootView.drawHierarchy(in: host.rootView.bounds, afterScreenUpdates: true)
        }
        let rowPoint = row.convert(CGPoint(x: row.bounds.width - 30, y: row.bounds.midY), to: host.rootView)
        let heroPoint = hero.convert(CGPoint(x: hero.bounds.width - 30, y: hero.bounds.midY), to: host.rootView)
        let rowColor = try pixel(image, at: rowPoint)
        let heroColor = try pixel(image, at: heroPoint)
        #expect(abs(rowColor.0 - 32) <= 2 && abs(rowColor.1 - 37) <= 2 && abs(rowColor.2 - 45) <= 2)
        #expect(abs(heroColor.0 - 20) <= 2 && abs(heroColor.1 - 23) <= 2 && abs(heroColor.2 - 28) <= 2)
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad])
    func fullHeightSettingsKeepsCardsSeparateFromCanvas(layout: NativeListTestLayout) async throws {
        let database = try WalletDatabase.temporary()
        let host = try NativeListTestHost(layout: layout, size: NativeListTestLayout.phone.size) {
            SettingsSheetNavigationContainer(
                path: .constant([]), securityDidExit: {}, onClose: {}
            ) {
                WalletSettingsView()
            } destination: { _ in
                EmptyView()
            }
            .walletSheetBackground(nativeGlass: false)
            // A new grouped presentation must also reset an inherited glass surface.
            .environment(\.walletNativeSheetSurface, true)
            .environment(WalletSettingsStore(database: database))
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections >= 4 }
        let row = try await host.cell(at: IndexPath(item: 0, section: 0), in: list)
        host.rootView.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.rootView.bounds).image { _ in
            host.rootView.drawHierarchy(in: host.rootView.bounds, afterScreenUpdates: true)
        }
        let point = row.convert(CGPoint(x: row.bounds.width - 60, y: row.bounds.midY), to: host.rootView)
        let card = try pixel(image, at: point)
        let canvas = try pixel(image, at: CGPoint(x: 5, y: point.y))
        if layout.colorScheme == .light {
            #expect(card.0 >= 250 && card.1 >= 250 && card.2 >= 250)
            #expect(canvas.0 < 248 && canvas.1 < 248)
            #expect(card.0 - canvas.0 >= 8 && card.1 - canvas.1 >= 8)
        } else {
            #expect(card.0 > canvas.0 && card.1 > canvas.1 && card.2 > canvas.2)
            #expect(canvas.0 > 0 && canvas.0 < 50)
        }
        // Store the actual native List rendering for visual inspection.
        let name = layout.colorScheme == .light ? "light" : "dark"
        try image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oath-settings-contrast-\(name).png"))
    }

    @Test
    func presentedSettingsRetainsCardContrastWhenAppearanceChanges() async throws {
        let database = try WalletDatabase.temporary()
        let appearance = WalletSheetAppearanceProbeState()
        let settings = WalletSettingsStore(database: database)
        settings.setAppearance(.light)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: NativeListTestLayout.phone.size)
        let root = UIHostingController(rootView: WalletSheetAppearanceProbe(state: appearance)
            .environment(settings))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            WalletAppearanceWindowCoordinator.apply(.system)
        }
        for _ in 0..<150 {
            if let sheet = root.presentedViewController,
               !SendEntryUIProbe.views(UICollectionView.self, in: sheet.view).isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let sheet = try #require(root.presentedViewController)
        try await Task.sleep(for: .milliseconds(500))
        #expect(sheet.sheetPresentationController?.detents.map(\.identifier) == [.large])
        for (index, scheme) in [ColorScheme.dark, .light, .dark].enumerated() {
            appearance.path = [.appearance]
            try await Task.sleep(for: .milliseconds(400))
            settings.setAppearance(scheme == .dark ? .dark : .light)
            try await Task.sleep(for: .milliseconds(500))
            appearance.path = []
            try await Task.sleep(for: .milliseconds(400))
            sheet.view.layoutIfNeeded()
            let list = try #require(SendEntryUIProbe.views(UICollectionView.self, in: sheet.view).first)
            let row = try #require(list.cellForItem(at: IndexPath(item: 0, section: 0)))
            let image = UIGraphicsImageRenderer(bounds: sheet.view.bounds).image { _ in
                sheet.view.drawHierarchy(in: sheet.view.bounds, afterScreenUpdates: true)
            }
            let point = row.convert(CGPoint(x: row.bounds.width - 60, y: row.bounds.midY), to: sheet.view)
            let card = try pixel(image, at: point)
            let canvas = try pixel(image, at: CGPoint(x: 5, y: point.y))
            print("Sheet contrast \(index): \(scheme) card=\(card) canvas=\(canvas), traits=\(row.traitCollection.userInterfaceLevel.rawValue)")
            if scheme == .dark {
                #expect(card.0 - canvas.0 >= 8 && card.1 - canvas.1 >= 8 && card.2 - canvas.2 >= 8)
                #expect(canvas.0 > 0 && canvas.0 < 50)
            } else {
                #expect(card.0 >= 250 && card.1 >= 250 && card.2 >= 250)
                #expect(card.0 - canvas.0 >= 8 && card.1 - canvas.1 >= 8)
            }
            try image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("oath-presented-settings-\(index).png"))
        }
    }

    private func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ v: CGFloat) -> Double {
            let n = Double(v)
            return n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> (Int, Int, Int) {
        let cg = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
                                            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let rect = CGRect(x: Int(point.x * image.scale), y: Int(point.y * image.scale), width: 1, height: 1)
        let sample = try #require(cg.cropping(to: rect))
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }
}

@MainActor @Observable
private final class WalletSheetAppearanceProbeState {
    var path: [WalletSettingsSearchRoute] = []
}

private struct WalletSheetAppearanceProbe: View {
    @Environment(WalletSettingsStore.self) private var settings
    let state: WalletSheetAppearanceProbeState
    @State private var presented = false

    var body: some View {
        WalletTheme.background
            .sheet(isPresented: $presented) {
                SettingsSheetNavigationContainer(
                    path: Binding(get: { state.path }, set: { state.path = $0 }),
                    securityDidExit: {}, onClose: {}
                ) {
                    WalletSettingsView()
                } destination: { _ in
                    AppearanceSettingsView()
                }
                .walletSheetBackground(nativeGlass: false)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .preferredColorScheme(settings.appearance.preferredColorScheme)
            .task(id: settings.appearance) {
                WalletAppearanceWindowCoordinator.apply(settings.appearance)
            }
            .task { presented = true }
    }
}
