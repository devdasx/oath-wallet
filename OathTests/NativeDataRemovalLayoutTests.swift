import GRDB
import SwiftUI
import Testing
import UIKit
@testable import Aperture

/// Runs the production introductions in native Lists without starting a
/// destructive action or capturing app screenshots.
@Suite(.serialized)
@MainActor
struct NativeDataRemovalLayoutTests {
    @Test(arguments: NativeListTestLayout.allCases)
    func resetShowsOnlyTheThreeRequestedRows(layout: NativeListTestLayout) async throws {
        let database = try WalletDatabase.temporary()
        let walletID = try await seedWallet(in: database, kind: .watchOnly)
        let settings = WalletSettingsStore(database: database)
        let previousLanguageIdentifier =
            WalletRuntimePreferences.shared.languageIdentifier
        WalletRuntimePreferences.shared.setLanguageIdentifier(
            layout.direction == .rightToLeft ? "ar" : "en"
        )
        defer {
            WalletRuntimePreferences.shared.setLanguageIdentifier(
                previousLanguageIdentifier
            )
        }
        let actions = ListActionRecorder<String>()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                ResetAppIntroductionScreen(
                    database: database,
                    onResetComplete: { actions.actions.append("reset") },
                    onNotNow: { actions.actions.append("cancel") }
                )
            }
            .environment(settings)
        }
        defer { host.close() }

        let list = try await host.list {
            $0.numberOfSections == 1 && $0.numberOfItems(inSection: 0) == 3
        }
        // No introductory row, preferences row, or iCloud informational section.
        #expect(list.numberOfSections == 1)
        try await verifyRows([
            ("settings.reset.contents.wallets", "settings.reset.contents.wallets.detail"),
            ("settings.reset.contents.security", "settings.reset.contents.security.detail"),
            ("settings.reset.contents.activity", "settings.reset.contents.activity.detail")
        ], layout: layout, host: host, list: list)

        try verifyWarningAboveActions(
            layout: layout,
            host: host,
            continueKey: "common.continue",
            notNowKey: "common.not_now",
            learnMoreIdentifier: "resetAppLearnMore"
        )
        #expect(actions.actions.isEmpty)
        try activateNotNow(key: "common.not_now", layout: layout, host: host)
        #expect(actions.actions == ["cancel"])
        #expect(try await database.managedWallet(walletID: walletID).id == walletID)
    }

    @Test(arguments: NativeListTestLayout.allCases, [
        DatabaseWalletKind.created, .importedRecoveryPhrase,
        .importedPrivateKey, .watchOnly, .hardware
    ])
    func walletRemovalKeepsKindSpecificRowsAndBackupControls(
        layout: NativeListTestLayout, kind: DatabaseWalletKind
    ) async throws {
        let database = try WalletDatabase.temporary()
        let walletID = try await seedWallet(in: database, kind: kind)
        let previousLanguageIdentifier =
            WalletRuntimePreferences.shared.languageIdentifier
        WalletRuntimePreferences.shared.setLanguageIdentifier(
            layout.direction == .rightToLeft ? "ar" : "en"
        )
        defer {
            WalletRuntimePreferences.shared.setLanguageIdentifier(
                previousLanguageIdentifier
            )
        }
        let actions = ListActionRecorder<String>()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                RemoveWalletIntroductionScreen(
                    database: database, walletID: walletID,
                    onRemoved: { _ in actions.actions.append("removed") },
                    onNotNow: { actions.actions.append("cancel") }
                )
            }
        }
        defer { host.close() }

        var rows: [(String, String?)] = [
            ("settings.wallets.remove.contents.accounts.title", "settings.wallets.remove.contents.accounts")
        ]
        switch kind {
        case .created, .importedRecoveryPhrase:
            rows.append((
                "settings.wallets.remove.contents.recovery_phrase.title",
                "settings.wallets.remove.contents.recovery_phrase"
            ))
        case .importedPrivateKey:
            rows.append((
                "settings.wallets.remove.contents.private_key.title",
                "settings.wallets.remove.contents.private_key"
            ))
        case .watchOnly, .hardware:
            break
        }
        rows.append((
            "settings.wallets.remove.contents.activity.title",
            "settings.wallets.remove.contents.activity"
        ))

        let list = try await host.list {
            $0.numberOfSections == 2 && $0.numberOfItems(inSection: 0) == rows.count
        }
        try await verifyRows(rows, layout: layout, host: host, list: list)
        #expect(list.numberOfItems(inSection: 1) == 1)
        let backupCell = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        let backupSwitch = nativeSwitch(in: backupCell)
        switch kind {
        case .created, .importedRecoveryPhrase, .importedPrivateKey:
            #expect(try #require(backupSwitch).isOn == false)
        case .watchOnly, .hardware:
            #expect(backupSwitch == nil)
        }

        try verifyWarningAboveActions(
            layout: layout,
            host: host,
            continueKey: "common.continue",
            notNowKey: "common.not_now",
            learnMoreIdentifier: "removeWalletLearnMore"
        )
        #expect(actions.actions.isEmpty)
        try activateNotNow(key: "common.not_now", layout: layout, host: host)
        #expect(actions.actions == ["cancel"])
        #expect(try await database.managedWallet(walletID: walletID).id == walletID)
    }

    @Test
    func resetLearnMoreExplainsConsequencesWithoutStartingReset() async throws {
        let database = try WalletDatabase.temporary()
        let walletID = try await seedWallet(
            in: database,
            kind: .watchOnly
        )
        let actions = ListActionRecorder<String>()
        let host = try NativeListTestHost {
            NavigationStack {
                ResetAppIntroductionScreen(
                    database: database,
                    onResetComplete: { actions.actions.append("reset") },
                    onNotNow: { actions.actions.append("cancel") }
                )
            }
            .environment(WalletSettingsStore(database: database))
        }
        defer { host.close() }

        _ = try await host.list {
            $0.numberOfSections == 1
                && $0.numberOfItems(inSection: 0) == 3
        }
        let root = try #require(
            host.rootView.window?.rootViewController
        )
        let learnMore = try #require(
            SendEntryUIProbe.element(
                "resetAppLearnMore",
                in: host.rootView
            )
        )
        #expect(learnMore.accessibilityActivate())

        let sheet = try await presentedSheet(
            from: root,
            contentIdentifier: "resetAppLearnMoreNext"
        )
        #expect(
            SendEntryUIProbe.element(
                "resetAppLearnMoreNext",
                in: sheet.view
            )?.accessibilityLabel
                == WalletLocalization.string(
                    "settings.reset.learn_more.next.message"
                )
        )
        #expect(actions.actions.isEmpty)
        #expect(
            try await database.managedWallet(walletID: walletID).id
                == walletID
        )
        sheet.dismiss(animated: false)
    }

    @Test
    func walletRemovalLearnMoreExplainsBackupRiskWithoutRemoving() async throws {
        let database = try WalletDatabase.temporary()
        let walletID = try await seedWallet(
            in: database,
            kind: .watchOnly
        )
        let actions = ListActionRecorder<String>()
        let host = try NativeListTestHost {
            NavigationStack {
                RemoveWalletIntroductionScreen(
                    database: database,
                    walletID: walletID,
                    onRemoved: { _ in actions.actions.append("removed") },
                    onNotNow: { actions.actions.append("cancel") }
                )
            }
            .environment(WalletSettingsStore(database: database))
        }
        defer { host.close() }

        _ = try await host.list {
            $0.numberOfSections == 2
                && $0.numberOfItems(inSection: 0) == 2
        }
        let root = try #require(
            host.rootView.window?.rootViewController
        )
        let learnMore = try #require(
            SendEntryUIProbe.element(
                "removeWalletLearnMore",
                in: host.rootView
            )
        )
        #expect(learnMore.accessibilityActivate())

        let sheet = try await presentedSheet(
            from: root,
            contentIdentifier: "removeWalletLearnMoreNext"
        )
        #expect(
            SendEntryUIProbe.element(
                "removeWalletLearnMoreNext",
                in: sheet.view
            )?.accessibilityLabel
                == WalletLocalization.string(
                    "settings.wallets.remove.learn_more.next.message"
                )
        )
        #expect(actions.actions.isEmpty)
        #expect(
            try await database.managedWallet(walletID: walletID).id
                == walletID
        )
        sheet.dismiss(animated: false)
    }

    @Test(arguments: WalletDataRemovalIcon.allCases)
    func iconsUseTheSameScaledTileAndGlyphMetricsAsSettings(icon: WalletDataRemovalIcon) throws {
        let symbol = try #require(UIImage(
            systemName: icon.systemImage,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: SettingsIconMetrics.symbolPointSize, weight: .semibold, scale: .medium
            )
        ))
        #expect(symbol.size.width > 0 && symbol.size.width <= SettingsIconMetrics.size - 4)
        #expect(symbol.size.height > 0 && symbol.size.height <= SettingsIconMetrics.size - 4)

        for textSize: DynamicTypeSize in [.small, .large, .xxxLarge, .accessibility3, .accessibility5] {
            let removal = UIHostingController(rootView: WalletDataRemovalIconTile(icon: icon)
                .environment(\.dynamicTypeSize, textSize))
            let settings = UIHostingController(rootView: SettingsIconTile(icon: .wallets)
                .environment(\.dynamicTypeSize, textSize))
            let proposal = CGSize(width: 500, height: 500)
            let actual = removal.sizeThatFits(in: proposal)
            let expected = settings.sizeThatFits(in: proposal)
            #expect(abs(actual.width - expected.width) < 0.01)
            #expect(abs(actual.height - expected.height) < 0.01)
        }
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func destructiveProgressBarKeepsItsPositionAcrossCopyLengths(
        layout: NativeListTestLayout
    ) async throws {
        let copies = [
            WalletDestructiveProgressCopy(
                id: "short",
                titleKey: "Preparing",
                detailKey: "Preparing data."
            ),
            WalletDestructiveProgressCopy(
                id: "long",
                titleKey:
                    "Preparing Every Wallet Credential for Secure Removal",
                detailKey:
                    "Preparing recovery phrases, private keys, accounts, and locally stored wallet information before secure removal."
            ),
        ]

        let shortFrame = try await progressBarFrame(
            activeCopy: copies[0],
            stableCopies: copies,
            layout: layout
        )
        let longFrame = try await progressBarFrame(
            activeCopy: copies[1],
            stableCopies: copies,
            layout: layout
        )

        #expect(abs(shortFrame.minY - longFrame.minY) < 0.5)
        #expect(abs(shortFrame.height - longFrame.height) < 0.5)
    }

    @Test(arguments: [
        DynamicTypeSize.small,
        .large,
        .accessibility3,
        .accessibility5,
    ])
    func destructiveCompletionActionRetainsItsLayoutSlot(
        textSize: DynamicTypeSize
    ) {
        let proposal = CGSize(width: 520, height: 500)
        let running = destructiveActionHost(status: .running, textSize: textSize)
            .sizeThatFits(in: proposal)
        let completed = destructiveActionHost(status: .completed, textSize: textSize)
            .sizeThatFits(in: proposal)
        let failed = destructiveActionHost(status: .failed, textSize: textSize)
            .sizeThatFits(in: proposal)

        #expect(abs(running.width - completed.width) < 0.5)
        #expect(abs(running.height - completed.height) < 0.5)
        #expect(failed.height > completed.height)
    }

    @Test
    func destructiveProgressUsesNativeMediumSheetPresentation() async throws {
        let database = try WalletDatabase.temporary()
        let host = try NativeListTestHost {
            WalletDestructiveProgressPresentationProbe()
                .environment(WalletSettingsStore(database: database))
        }
        defer { host.close() }
        let root = try #require(
            host.rootView.window?.rootViewController
        )
        let sheet = try await presentedSheet(
            from: root,
            contentIdentifier: "destructiveProgressPresentationProbe"
        )
        let presentation = try #require(
            sheet.sheetPresentationController
        )

        #expect(presentation.detents.map(\.identifier) == [.medium])
        #expect(presentation.prefersGrabberVisible)
        #expect(sheet.isModalInPresentation)
    }

    private func verifyRows(
        _ rows: [(String, String?)], layout: NativeListTestLayout,
        host: NativeListTestHost, list: UICollectionView
    ) async throws {
        #expect(list.numberOfItems(inSection: 0) == rows.count)
        let tileHost = UIHostingController(rootView: WalletDataRemovalIconTile(icon: .wallets)
            .environment(\.dynamicTypeSize, layout.textSize))
        let tileSize = tileHost.sizeThatFits(in: CGSize(width: 500, height: 500))

        for (index, expectation) in rows.enumerated() {
            let path = IndexPath(item: index, section: 0)
            let cell = try await host.cell(at: path, in: list)
            let title = localized(expectation.0, layout: layout)
            var visited: Set<ObjectIdentifier> = []
            let row = try #require(accessibilityElement(containing: title, in: cell, visited: &visited))
            #expect(!row.accessibilityTraits.contains(.button))
            if let detail = expectation.1 {
                #expect(row.accessibilityLabel?.contains(localized(detail, layout: layout)) == true)
            } else {
                // Rows without a flow-provided detail expose only their title.
                #expect(row.accessibilityLabel == title)
            }
            #expect(cell.bounds.height >= tileSize.height)
            #expect(cell.bounds.width > 0 && cell.bounds.width <= list.bounds.width)
            list.delegate?.collectionView?(list, performPrimaryActionForItemAt: path)
            await Task.yield()
        }
    }

    private func progressBarFrame(
        activeCopy: WalletDestructiveProgressCopy,
        stableCopies: [WalletDestructiveProgressCopy],
        layout: NativeListTestLayout
    ) async throws -> CGRect {
        let host = try NativeListTestHost(layout: layout) {
            WalletDestructiveProgressContent(
                status: .running,
                transitionIdentity: activeCopy.id,
                titleKey: activeCopy.titleKey,
                detailKey: activeCopy.detailKey,
                stableCopies: stableCopies,
                progressAccessibilityKey:
                    "settings.reset.progress.animation.accessibility",
                stepLocalizationKey: "settings.reset.progress.step",
                step: 2,
                totalSteps: 6
            )
            .frame(maxWidth: 520)
            .padding(.horizontal, 28)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        defer { host.close() }

        for _ in 0..<50 {
            await Task.yield()
            host.rootView.layoutIfNeeded()
            if let progress = SendEntryUIProbe.element(
                "walletDestructiveProgressBar",
                in: host.rootView
            ), !progress.accessibilityFrame.isEmpty {
                return progress.accessibilityFrame
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let progress = try #require(
            SendEntryUIProbe.element(
                "walletDestructiveProgressBar",
                in: host.rootView
            )
        )
        return progress.accessibilityFrame
    }

    private func destructiveActionHost(
        status: WalletDestructiveProgressStatus,
        textSize: DynamicTypeSize
    ) -> UIHostingController<some View> {
        UIHostingController(rootView:
            WalletDestructiveProgressActionHost(status: status) {
                PrimaryWalletButton(title: "common.done") {}
            } failure: {
                VStack(spacing: 10) {
                    PrimaryWalletButton(
                        title: "settings.reset.progress.failed.retry"
                    ) {}
                    SecondaryWalletButton(
                        title: "settings.reset.progress.failed.cancel"
                    ) {}
                }
            }
            .environment(\.dynamicTypeSize, textSize)
        )
    }

    private func activateNotNow(key: String, layout: NativeListTestLayout, host: NativeListTestHost) throws {
        let action = try #require(host.accessibilityAction(label: localized(key, layout: layout), in: host.rootView))
        #expect(!action.accessibilityTraits.contains(.notEnabled))
        #expect(action.accessibilityActivate())
    }

    private func verifyWarningAboveActions(
        layout: NativeListTestLayout,
        host: NativeListTestHost,
        continueKey: String,
        notNowKey: String,
        learnMoreIdentifier: String
    ) throws {
        let message = localized("settings.reset.review.irreversible", layout: layout)
        let learnMoreTitle = localized(
            "common.learn_more.inline",
            layout: layout
        )
        var visited: Set<ObjectIdentifier> = []
        let warning = try #require(accessibilityElement(
            containing: message, in: host.rootView, visited: &visited
        ))
        let continueAction = try #require(host.accessibilityAction(
            label: localized(continueKey, layout: layout),
            in: host.rootView
        ))
        let notNow = try #require(host.accessibilityAction(
            label: localized(notNowKey, layout: layout),
            in: host.rootView
        ))
        let learnMore = try #require(SendEntryUIProbe.element(
            learnMoreIdentifier,
            in: host.rootView
        ))

        #expect(warning.accessibilityLabel == message)
        #expect(!warning.accessibilityTraits.contains(.button))
        #expect(learnMore.accessibilityLabel == learnMoreTitle)
        #expect(learnMore.accessibilityTraits.contains(.button))
        #expect(!warning.accessibilityFrame.isEmpty)
        #expect(learnMore.accessibilityFrame.height.rounded() >= 44)
        #expect(
            max(
                warning.accessibilityFrame.maxY,
                learnMore.accessibilityFrame.maxY
            ) <= continueAction.accessibilityFrame.minY
        )
        #expect(continueAction.accessibilityFrame.maxY <= notNow.accessibilityFrame.minY)
        let visibleBounds = host.rootView.convert(host.rootView.bounds, to: nil)
        #expect(visibleBounds.contains(warning.accessibilityFrame))
        #expect(visibleBounds.contains(learnMore.accessibilityFrame))
    }

    private func presentedSheet(
        from root: UIViewController,
        contentIdentifier: String
    ) async throws -> UIViewController {
        for _ in 0..<150 {
            await Task.yield()
            root.view.window?.layoutIfNeeded()
            if let presented = root.presentedViewController {
                presented.view.layoutIfNeeded()
                if SendEntryUIProbe.element(
                    contentIdentifier,
                    in: presented.view
                ) != nil {
                    return presented
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(root.presentedViewController)
    }

    private func localized(_ key: String, layout: NativeListTestLayout) -> String {
        let english = WalletAppLanguage.localizedBundle(for: "en")
            .localizedString(forKey: key, value: nil, table: nil)
        return WalletAppLanguage.localizedBundle(for: layout.direction == .rightToLeft ? "ar" : "en")
            .localizedString(forKey: key, value: english, table: nil)
    }

    private func accessibilityElement(
        containing title: String, in object: NSObject, visited: inout Set<ObjectIdentifier>
    ) -> NSObject? {
        guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
        if object.isAccessibilityElement, object.accessibilityLabel?.contains(title) == true {
            return object
        }
        let count = object.accessibilityElementCount()
        if count > 0, count < 1_000 {
            for index in 0..<count {
                if let child = object.accessibilityElement(at: index) as? NSObject,
                   let match = accessibilityElement(containing: title, in: child, visited: &visited) {
                    return match
                }
            }
        }
        if let view = object as? UIView {
            for child in view.subviews {
                if let match = accessibilityElement(containing: title, in: child, visited: &visited) {
                    return match
                }
            }
        }
        return nil
    }

    private func nativeSwitch(in view: UIView) -> UISwitch? {
        if let toggle = view as? UISwitch { return toggle }
        for child in view.subviews {
            if let toggle = nativeSwitch(in: child) { return toggle }
        }
        return nil
    }

    private func seedWallet(in database: WalletDatabase, kind: DatabaseWalletKind) async throws -> String {
        let walletID = "removal-layout-\(UUID().uuidString)"
        try await database.pool.write { db in
            try DBWalletRecord(
                id: walletID, profileID: WalletDatabase.defaultProfileID,
                name: "Removal Layout Fixture", kind: kind.rawValue,
                secretKeyReference: nil, isSelected: true, sortOrder: 0,
                createdAt: 1, updatedAt: 1, lastOpenedAt: nil, archivedAt: nil
            ).insert(db)
            let address = "0x1111111111111111111111111111111111111111"
            try DBWalletAccountRecord(
                id: "\(walletID):eth:0", walletID: walletID, networkID: "eth",
                address: address, normalizedAddress: address,
                label: nil, derivationPath: nil, accountIndex: 0, publicKey: nil,
                isWatchOnly: kind == .watchOnly, isEnabled: true,
                createdAt: 1, updatedAt: 1, lastSyncedAt: nil
            ).insert(db)
        }
        return walletID
    }
}

private struct WalletDestructiveProgressPresentationProbe: View {
    @State private var isPresented = true

    var body: some View {
        Color.clear
            .sheet(isPresented: $isPresented) {
                Text(verbatim: "Progress presentation probe")
                    .accessibilityIdentifier(
                        "destructiveProgressPresentationProbe"
                    )
                    .walletDestructiveProgressSheetPresentation()
            }
    }
}
