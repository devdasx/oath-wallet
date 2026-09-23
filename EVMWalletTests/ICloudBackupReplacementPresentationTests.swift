import GRDB
import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct ICloudBackupReplacementPresentationTests {
    @Test(arguments: [false, true], [false, true])
    func enablingICloudUsesPasskeyWithoutAnotherAppAuthentication(
        isInline: Bool, cancelPasskey: Bool
    ) async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        let secret = try fixture.credential.encodedData()
        let reference = try WalletSecretVault.shared.store(secret, kind: .recoveryPhrase)
        defer { try? WalletSecretVault.shared.delete(reference: reference) }
        let database = try await fixture.database(secretReference: reference)
        let wallet = fixture.wallet
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE userSettings SET appLockEnabled = 1, biometricEnabled = 0")
            // Saving a real backup needs the canonical account as well as the
            // opaque secret reference used by the presentation-only fixtures.
            try DBWalletAccountRecord(
                id: wallet.id + ":ethereum", walletID: wallet.id,
                networkID: PrivateKeyImportNetwork.evm.networkID,
                address: wallet.address, normalizedAddress: wallet.address.lowercased(),
                label: nil, derivationPath: "m/44'/60'/0'/0/0", accountIndex: 0,
                publicKey: nil, isWatchOnly: false, isEnabled: true,
                createdAt: wallet.createdAt.timeIntervalSince1970,
                updatedAt: wallet.createdAt.timeIntervalSince1970
            ).insert(db)
        }
        #expect(try await database.managedWallet(walletID: wallet.id).address == wallet.address)
        let security = try await database.walletSecuritySettings()
        #expect(security.requiresAuthentication)
        // With app protection enabled, the old path would stop at an app-passcode
        // screen and never reach this passkey request. No app grant is supplied.
        fixture.authorizer.cancel = cancelPasskey
        var busy = false
        let host = try NativeListTestHost {
            NavigationStack {
                SettingsBackupMethodSelectionScreen(
                    database: database, walletID: fixture.wallet.id,
                    material: .recoveryPhrase, cloudBackupService: fixture.service,
                    isInline: isInline, onBusyChange: { busy = $0 }
                )
            }
        }
        defer { host.close() }
        let list = try await host.list {
            $0.numberOfSections > 0 && $0.numberOfItems(inSection: 0) == 2
        }
        if isInline {
            _ = try await host.cell(at: IndexPath(item: 0, section: 0), in: list)
            try await SendEntryUIProbe.wait(in: host.rootView) {
                SendEntryUIProbe.views(UISwitch.self, in: host.rootView).first?.isEnabled == true
            }
            let toggle = try #require(SendEntryUIProbe.views(UISwitch.self, in: host.rootView).first)
            #expect(!toggle.isOn)
            toggle.setOn(true, animated: false)
            toggle.sendActions(for: .valueChanged)
        } else {
            try await host.selectRow(IndexPath(item: 1, section: 0), in: list)
        }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            fixture.authorizer.registrationRequests == 1 && !busy
        }
        #expect(fixture.authorizer.registrations == (cancelPasskey ? 0 : 1))
        #expect(fixture.authorizer.assertions == 0)
        #expect(host.rootView.window?.rootViewController?.presentedViewController == nil)
        #expect(try await database.walletSecuritySettings() == security)
        let saved = try await database.managedWallet(walletID: fixture.wallet.id)
        #expect((saved.iCloudBackupUpdatedAt != nil) == !cancelPasskey)
        if isInline {
            let toggle = try #require(SendEntryUIProbe.views(UISwitch.self, in: host.rootView).first)
            #expect(toggle.isEnabled)
            #expect(toggle.isOn == !cancelPasskey)
        }
        if cancelPasskey {
            await #expect(throws: WalletCloudBackupError.backupNotFound) {
                _ = try await fixture.store.fetch(walletID: fixture.wallet.id)
            }
        } else {
            let document = try await fixture.store.fetch(walletID: fixture.wallet.id)
            #expect(document.encryptedPayload.range(of: secret) == nil)
            #expect(try fixture.files().count == 1)
            let restored = try await fixture.service.restore(walletID: fixture.wallet.id)
            #expect(restored.secret == secret)
        }
    }

    @Test
    func inlineOptionsStayReadyWhileICloudIsCheckedBehindTheScreen() async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        let database = try await fixture.database()
        let gate = DispatchGroup()
        gate.enter()
        var released = false
        defer { if !released { gate.leave() } }
        let root = fixture.root
        let delayedStore = WalletICloudDriveBackupStore(containerURLProvider: {
            _ = gate.wait(timeout: .now() + 10)
            return root
        })
        let service = fixture.service(using: delayedStore)
        let host = try NativeListTestHost {
            NavigationStack {
                SettingsBackupMethodSelectionScreen(
                    database: database, walletID: fixture.wallet.id,
                    material: .recoveryPhrase, cloudBackupService: service,
                    isInline: true
                )
            }
        }
        defer { host.close() }
        let list = try await host.list {
            $0.numberOfSections > 0 && $0.numberOfItems(inSection: 0) == 2
        }
        // The saved state is on screen while the gated store still holds the
        // iCloud check: both rows stay usable and neither shows a spinner.
        let cloudCell = try await host.cell(at: IndexPath(item: 0, section: 0), in: list)
        _ = try await host.cell(at: IndexPath(item: 1, section: 0), in: list)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UISwitch.self, in: host.rootView).first?.isEnabled == true
        }
        // No spinner stands in for the switch, and the manual row stays tappable.
        #expect(SendEntryUIProbe.views(UIActivityIndicatorView.self, in: host.rootView).isEmpty)
        #expect(list.delegate?.collectionView?(
            list, shouldHighlightItemAt: IndexPath(item: 1, section: 0)
        ) == true)
        let rowHeight = cloudCell.bounds.height

        gate.leave()
        released = true
        try await settle(host)
        #expect(list.numberOfItems(inSection: 0) == 2)
        #expect(cloudCell.bounds.height == rowHeight)
        #expect(SendEntryUIProbe.views(UIActivityIndicatorView.self, in: host.rootView).isEmpty)
        #expect(fixture.authorizer.registrations == 0)
    }

    @Test(arguments: [NativeListTestLayout.phone, .largeTextRTL], [false, true])
    func inlineSuccessOptionsReflectTheSavedWalletWithoutCreatingBackups(
        layout: NativeListTestLayout, backedUp: Bool
    ) async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        if backedUp { try await fixture.create() }
        let database = try await fixture.database()
        var busy = false
        let registrations = fixture.authorizer.registrations
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SettingsBackupMethodSelectionScreen(
                    database: database, walletID: fixture.wallet.id,
                    material: .recoveryPhrase, cloudBackupService: fixture.service,
                    isInline: true, onBusyChange: { busy = $0 }
                )
            }
        }
        defer { host.close() }
        let list = try await host.list {
            $0.numberOfSections > 0 && $0.numberOfItems(inSection: 0) == 2
        }
        let cloudCell = try await host.cell(at: IndexPath(item: 0, section: 0), in: list)
        let manualCell = try await host.cell(at: IndexPath(item: 1, section: 0), in: list)
        // Reconciling with iCloud runs behind the screen, so the switch settles on
        // the wallet's real state without the row ever reporting progress.
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UISwitch.self, in: host.rootView).first?.isOn == backedUp
        }
        let toggle = try #require(SendEntryUIProbe.views(UISwitch.self, in: host.rootView).first)
        #expect(toggle.isEnabled)
        // The options belong to the screen's own inset list: the system sizes the
        // rows, so neither the list nor a row carries a measured height.
        #expect(list.bounds.height > list.collectionViewLayout.collectionViewContentSize.height)
        #expect(cloudCell.bounds.height >= 44)
        #expect(manualCell.bounds.height >= 44)
        #expect(!busy)
        #expect(fixture.authorizer.registrations == registrations)
        #expect(fixture.authorizer.assertions == 0)
        #expect(presentedDialog(in: host) == nil)
        let saved = try await database.managedWallet(walletID: fixture.wallet.id)
        #expect((saved.iCloudBackupUpdatedAt != nil) == backedUp)
        #expect(saved.backupState == .notVerified)
    }

    @Test(arguments: [NativeListTestLayout.phone, .largeTextRTL])
    func completionScreenKeepsTheBackupOptionsInOneNativeList(
        layout: NativeListTestLayout
    ) async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        let database = try await fixture.database()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                WalletSuccessView(
                    kind: .imported,
                    backupContext: WalletSuccessBackupContext(
                        database: database, walletID: fixture.wallet.id
                    ),
                    onContinue: {}
                )
            }
        }
        defer { host.close() }
        let list = try await host.list {
            $0.numberOfSections > 0 && $0.numberOfItems(inSection: 0) == 2
        }
        // The confirmation rides along as the list's header, so the screen scrolls
        // once instead of nesting a fixed-height list inside its own scroll view.
        #expect(SendEntryUIProbe.views(UIScrollView.self, in: host.rootView)
            .allSatisfy { $0 === list })
        // The hero is the section's header supplementary view, above both rows.
        let header = try #require(list.visibleSupplementaryViews(
            ofKind: UICollectionView.elementKindSectionHeader
        ).first)
        let cloudCell = try await host.cell(at: IndexPath(item: 0, section: 0), in: list)
        _ = try await host.cell(at: IndexPath(item: 1, section: 0), in: list)
        #expect(header.bounds.height > cloudCell.bounds.height)
        #expect(header.frame.maxY <= cloudCell.frame.minY + 1)
    }

    /// The row carried "Last Backed Up: <date>" as a second line, which made it
    /// taller once a backup existed. Measuring both states is what proves it is gone;
    /// looking the text up by accessibility identifier would pass either way.
    @Test
    func iCloudRowIsTheSameHeightWhetherOrNotABackupExists() async throws {
        var heights: [Bool: CGFloat] = [:]
        for backedUp in [false, true] {
            let fixture = try ICloudReplacementFixture()
            defer { fixture.cleanUp() }
            if backedUp { try await fixture.create() }
            let database = try await fixture.database()
            let host = try NativeListTestHost {
                NavigationStack {
                    SettingsBackupMethodSelectionScreen(
                        database: database, walletID: fixture.wallet.id,
                        material: .recoveryPhrase, cloudBackupService: fixture.service,
                        isInline: true
                    )
                }
            }
            defer { host.close() }
            let list = try await host.list {
                $0.numberOfSections > 0 && $0.numberOfItems(inSection: 0) == 2
            }
            try await SendEntryUIProbe.wait(in: host.rootView) {
                SendEntryUIProbe.views(UISwitch.self, in: host.rootView).first?.isOn == backedUp
            }
            heights[backedUp] = try await host.cell(
                at: IndexPath(item: 0, section: 0), in: list
            ).bounds.height
        }
        #expect(heights[false] == heights[true])
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad])
    func reopenedPhraseBackupShowsReplacementChoicesWithoutChangingCloudData(
        layout: NativeListTestLayout
    ) async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        try await fixture.create()
        let original = try await fixture.store.fetch(walletID: fixture.wallet.id)
        let database = try await fixture.database()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SettingsBackupMethodSelectionScreen(
                    database: database, walletID: fixture.wallet.id,
                    material: .recoveryPhrase, cloudBackupService: fixture.service
                )
            }
        }
        defer { host.close() }
        let list = try await host.list {
            $0.numberOfSections > 0 && $0.numberOfItems(inSection: 0) == 2
        }
        try await host.selectRow(IndexPath(item: 1, section: 0), in: list)
        let dialog = try await replacementDialog(in: host)
        #expect(dialog.message == localized("phrase.message"))
        #expect(dialog.actions.contains { $0.title == localized("confirm") && $0.style == .destructive })
        #expect(dialog.actions.contains { $0.title == localized("keep") && $0.style == .cancel })
        #expect(fixture.authorizer.assertions == 0)
        #expect(try await fixture.store.fetch(walletID: fixture.wallet.id) == original)
        // Dismissing/keeping the prompt has no write or deletion side effects.
        await dismiss(dialog)
        #expect(try await fixture.store.fetch(walletID: fixture.wallet.id) == original)
        let reloaded = try await database.managedWallet(walletID: fixture.wallet.id)
        #expect(reloaded.iCloudBackupUpdatedAt != nil)
        try await host.selectRow(IndexPath(item: 1, section: 0), in: list)
        let repeated = try await replacementDialog(in: host)
        #expect(repeated.message == localized("phrase.message"))
        await dismiss(repeated)
    }

    @Test
    func deletingBackupElsewhereClearsThePreviousSuccessMessage() async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        try await fixture.create()
        let database = try await fixture.database()
        _ = try await WalletICloudPasskeyBackupCreation.existingBackup(
            database: database, wallet: fixture.wallet, service: fixture.service
        )
        let host = try NativeListTestHost {
            NavigationStack {
                SettingsBackupMethodSelectionScreen(
                    database: database, walletID: fixture.wallet.id,
                    material: .recoveryPhrase, cloudBackupService: fixture.service
                )
            }
        }
        defer { host.close() }
        let list = try await host.list {
            $0.numberOfSections == 2 && $0.numberOfItems(inSection: 0) == 2
        }
        try await fixture.service.removeBackup(walletID: fixture.wallet.id)
        fixture.authorizer.cancel = true
        try await host.selectRow(IndexPath(item: 1, section: 0), in: list)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            list.numberOfSections == 1
        }
        #expect(try await database.managedWallet(walletID: fixture.wallet.id).iCloudBackupUpdatedAt == nil)
        #expect(presentedDialog(in: host) == nil)
    }

    @Test
    func reopenedPrivateKeyBackupShowsKeySpecificReplacementChoices() async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        let key = try fixture.privateKeyConfiguration()
        try await key.createBackup(using: fixture.service)
        let original = try await fixture.store.fetch(walletID: key.cloudWalletID)
        let item = WalletPrivateKeyExportItem(
            id: "replacement-evm", titleKey: "network.ethereum",
            logoSource: .nativeCoin(blockchain: .ethereum), backupNetwork: .evm,
            detail: .derivationPath("m/44'/60'/0'/0/0"),
            privateKey: String(repeating: "0", count: 63) + "1"
        )
        let host = try NativeListTestHost {
            NavigationStack {
                WalletPrivateKeyExportDisplayScreen(
                    wallet: fixture.wallet, item: item, cloudBackupService: fixture.service
                )
            }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 3 }
        _ = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UISwitch.self, in: host.rootView).first?.isEnabled == true
        }
        let toggle = try #require(SendEntryUIProbe.views(UISwitch.self, in: host.rootView).first)
        #expect(toggle.isOn)
        toggle.setOn(false, animated: false)
        toggle.sendActions(for: .valueChanged)
        let dialog = try await replacementDialog(in: host)
        #expect(dialog.message == localized("private_key.message"))
        #expect(dialog.actions.contains { $0.title == localized("confirm") })
        #expect(try await fixture.store.fetch(walletID: key.cloudWalletID) == original)
        await dismiss(dialog)
        #expect(try await fixture.store.fetch(walletID: key.cloudWalletID) == original)
    }

    /// Gives the screen a few run-loop turns to react to work that finished
    /// behind it, without a spinner or another visible signal to wait on.
    private func settle(_ host: NativeListTestHost) async throws {
        for _ in 0..<12 {
            await Task.yield()
            host.rootView.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func replacementDialog(in host: NativeListTestHost) async throws -> UIAlertController {
        try await SendEntryUIProbe.wait(in: host.rootView) { presentedDialog(in: host) != nil }
        return try #require(presentedDialog(in: host))
    }

    private func presentedDialog(in host: NativeListTestHost) -> UIAlertController? {
        var controller = host.rootView.window?.rootViewController
        while let next = controller?.presentedViewController { controller = next }
        return controller as? UIAlertController
    }

    private func dismiss(_ dialog: UIAlertController) async {
        await withCheckedContinuation { continuation in
            dialog.dismiss(animated: false) { continuation.resume() }
        }
        await Task.yield()
    }

    private func localized(_ suffix: String) -> String {
        WalletAppLanguage.localizedBundle(for: "en").localizedString(
            forKey: "settings.wallets.backup.replace." + suffix, value: nil, table: nil
        )
    }
}
