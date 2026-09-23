import GRDB
import SwiftUI
import Testing
import UIKit
@testable import Aperture

/// Drives the production screen's native list and clipboard controls. No
/// screenshots, wallet secrets, network submissions, or mocked UI components.
@MainActor
@Suite(.serialized)
struct NativeSendRecipientHistoryTests {
    private typealias Fixtures = SendRecipientHistoryTestFixtures

    @Test(arguments: ["eth", "xrp", "stellar"], NativeListTestLayout.allCases)
    func emptyRecentHistoryHidesSectionUntilAppSendAndAfterLedgerCleared(
        networkID: String, layout: NativeListTestLayout
    ) async throws {
        let database = try WalletDatabase.temporary()
        let asset = try Fixtures.asset(networkID: networkID)
        let scope = try await Fixtures.seed(database, asset: asset)
        let recipient = networkID == "eth" ? Fixtures.recipient
            : SendEntryTestFixtures.address(for: asset.blockchain)
        // API-imported history must not make the app-send section appear.
        try await Fixtures.save([
            Fixtures.transaction(scope: scope, address: recipient)
        ], in: database)
        let recorder = ListActionRecorder<SendDraft>()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendRecipientScreen(
                    database: database,
                    draft: SendEntryTestFixtures.draft(asset: asset, recipient: recipient)
                ) { recorder.actions.append($0) }
            }
        }
        defer { host.close() }
        let recentSection = networkID == "eth" ? 2 : 3
        let recentIndex = IndexPath(item: 0, section: recentSection)
        let list = try await host.list { $0.numberOfSections == recentSection }
        _ = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendRecipientHistoryAssessment", in: host.rootView)?.accessibilityLabel
                == SendRecipientHistoryAssessment.newRecipient.message
        }
        host.rootView.endEditing(true)
        #expect(list.numberOfSections == recentSection)
        expectNoRecentHistory(in: list)
        #expect(recorder.actions.isEmpty)

        try await Fixtures.broadcast(in: database, asset: asset, address: recipient)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            list.numberOfSections == recentSection + 1
        }
        var recentCell = try await host.cell(at: recentIndex, in: list)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            recentCell = list.cellForItem(at: recentIndex) ?? recentCell
            return SendEntryUIProbe.element("sendRecentRecipient", in: recentCell) != nil
        }
        #expect(list.numberOfSections == recentSection + 1)
        #expect(list.numberOfItems(inSection: recentSection) == 1)
        #expect(SendEntryUIProbe.element("sendRecentRecipient", in: recentCell)?.accessibilityLabel == recipient)
        #expect(SendEntryUIProbe.element("sendRecipientHistoryEmpty", in: recentCell) == nil)

        // Remove only this temporary database's fixture ledger, then verify
        // that live observation removes the whole section, including its header.
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM sendRecipientBroadcasts WHERE walletID = ? AND networkID = ?",
                arguments: [scope.walletID, networkID]
            )
        }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            list.numberOfSections == recentSection
        }
        #expect(recorder.actions.isEmpty)
        _ = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendRecipientHistoryAssessment", in: host.rootView)?.accessibilityLabel
                == SendRecipientHistoryAssessment.newRecipient.message
                && list.visibleCells.allSatisfy {
                    SendEntryUIProbe.element("sendRecentRecipient", in: $0) == nil
                }
        }
        #expect(list.numberOfSections == recentSection)
        expectNoRecentHistory(in: list)
        try SendEntryUIProbe.activate("sendRecipientContinue", in: host.rootView)
        #expect(recorder.actions.count == 1)
        #expect(recorder.actions.first?.recipient == recipient)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func unavailableHistoryHidesOptionalSectionWithoutBlockingRecipient(
        layout: NativeListTestLayout
    ) async throws {
        let database = try WalletDatabase.temporary()
        let recorder = ListActionRecorder<SendDraft>()
        let draft = SendEntryTestFixtures.draft()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendRecipientScreen(database: database, draft: draft) {
                    recorder.actions.append($0)
                }
            }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 2 }
        _ = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        host.rootView.endEditing(true)
        // Exercise the real missing-account failure independently, so silence
        // in this optional section cannot masquerade as a successful history read.
        let history = SendRecipientHistoryModel()
        await history.observe(database: database, asset: draft.asset)
        #expect(history.errorMessage != nil)
        #expect(list.numberOfSections == 2)
        expectNoRecentHistory(in: list)
        #expect(SendEntryUIProbe.element("sendRecipientHistoryAssessment", in: host.rootView) == nil)
        #expect(host.accessibilityAction(label: WalletLocalization.string("common.retry"), in: list) == nil)
        try SendEntryUIProbe.activate("sendRecipientContinue", in: host.rootView)
        #expect(recorder.actions.first?.recipient == draft.recipient)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func filledEntryAndRecentRowsRemainIndependentAccessibleNativeControls(
        layout: NativeListTestLayout
    ) async throws {
        let regularSizes = try await regularGlassControlSizes(layout: layout)
        let database = try WalletDatabase.temporary()
        _ = try await Fixtures.seed(database)
        try await Fixtures.broadcast(in: database, hash: "one")
        try await Fixtures.broadcast(in: database, hash: "two")
        try await Fixtures.broadcast(in: database, hash: "older", address: Fixtures.anotherRecipient, date: 50)
        let recorder = ListActionRecorder<SendDraft>()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendRecipientScreen(
                    database: database, draft: SendEntryTestFixtures.draft(recipient: "")
                ) { recorder.actions.append($0) }
            }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 3 }
        try await SendEntryUIProbe.wait(in: host.rootView) { list.numberOfItems(inSection: 2) == 2 }
        let inputCell = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendRecipientPaste", in: inputCell) != nil
                && SendEntryUIProbe.element("sendRecipientScan", in: inputCell) != nil
        }
        let paste = try #require(SendEntryUIProbe.element("sendRecipientPaste", in: inputCell))
        let scan = try #require(SendEntryUIProbe.element("sendRecipientScan", in: inputCell))
        let field = try #require(SendEntryUIProbe.views(UITextView.self, in: inputCell).first)
        #expect(field.text.isEmpty)
        let bundle = WalletAppLanguage.localizedBundle(
            for: layout.direction == .rightToLeft ? "ar" : "en"
        )
        let cellFrame = inputCell.convert(inputCell.bounds, to: nil)
        for (control, key, regularSize) in [
            (paste, "common.paste", regularSizes.paste),
            (scan, "common.scan", regularSizes.scan)
        ] {
            #expect(control.accessibilityTraits.contains(.button))
            #expect(control.accessibilityLabel == bundle.localizedString(forKey: key, value: nil, table: nil))
            #expect(control.accessibilityFrame.height >= regularSize.height + 4,
                    "Paste and Scan must be modestly taller than an unpadded regular control")
            #expect(control.accessibilityFrame.width >= regularSize.width + 12,
                    "Paste and Scan must be modestly wider than an unpadded regular control")
            #expect(control.accessibilityFrame.minX >= cellFrame.minX)
            #expect(control.accessibilityFrame.maxX <= cellFrame.maxX)
        }
        #expect(!paste.accessibilityFrame.intersects(scan.accessibilityFrame))
        #expect(abs(paste.accessibilityFrame.height - scan.accessibilityFrame.height) < 1)
        if layout.textSize == .large {
            #expect(abs(paste.accessibilityFrame.midY - scan.accessibilityFrame.midY) < 1)
            #expect(paste.accessibilityFrame.maxX < scan.accessibilityFrame.minX)
        }
        #expect(SendEntryUIProbe.element("sendAmountBalance", in: host.rootView) == nil)
        #expect(SendEntryUIProbe.element("sendRecipientSelectedAsset", in: host.rootView) != nil)
        #expect(SendEntryUIProbe.element("sendRecipientHistoryAssessment", in: host.rootView) == nil)
        let toolbar = try #require(host.navigationController?.navigationBar)
        #expect(SendEntryUIProbe.element("sendRecipientPaste", in: toolbar) == nil)
        #expect(SendEntryUIProbe.element("sendRecipientScan", in: toolbar) == nil)
        #expect(SendEntryUIProbe.element("sendRecipientOptions", in: toolbar) == nil)

        // List rows must receive UIKit's native highlight/primary action, not a
        // tap gesture that steals taps from neighboring input, Paste, or Scan controls.
        host.rootView.endEditing(true)
        let recentIndex = IndexPath(item: 0, section: 2)
        var recentCell = try await host.cell(at: recentIndex, in: list)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            recentCell = list.cellForItem(at: recentIndex) ?? recentCell
            return SendEntryUIProbe.element("sendRecentRecipient", in: recentCell) != nil
        }
        let recent = try #require(SendEntryUIProbe.element("sendRecentRecipient", in: recentCell))
        #expect(recent.accessibilityLabel == Fixtures.recipient)
        #expect(recent.accessibilityValue == EnglishNumbers.localized("send.recipient.history.sent_count", "2"))
        let secondCell = try await host.cell(at: IndexPath(item: 1, section: 2), in: list)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendRecentRecipient", in: secondCell) != nil
        }
        let second = try #require(SendEntryUIProbe.element("sendRecentRecipient", in: secondCell))
        #expect(second.accessibilityLabel == Fixtures.anotherRecipient)
        #expect(second.accessibilityValue == WalletLocalization.string("send.recipient.history.sent_once"))
        try await host.selectRow(recentIndex, in: list)
        _ = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendRecipientHistoryAssessment", in: host.rootView)?.accessibilityLabel
                == SendRecipientHistoryAssessment.previouslySent(count: 2).message
        }
        #expect(field.text == Fixtures.recipient)
        #expect(recorder.actions.isEmpty)
        try SendEntryUIProbe.activate("sendRecipientContinue", in: host.rootView)
        #expect(recorder.actions.first?.recipient == Fixtures.recipient)
        #expect(recorder.actions.first?.amount == nil)
    }

    @Test
    func nativePasteShowsNewRecipientWarningThenLiveHistoryCountAndRejectsWrongNetwork() async throws {
        let database = try WalletDatabase.temporary()
        _ = try await Fixtures.seed(database)
        // Imported activity must not establish a previous app send, even when
        // the provider reports a confirmed outgoing transfer to this address.
        try await Fixtures.save([
            Fixtures.transaction(hash: "api-history", address: Fixtures.anotherRecipient)
        ], in: database)
        let recorder = ListActionRecorder<SendDraft>()
        let host = try NativeListTestHost {
            NavigationStack {
                SendRecipientScreen(
                    database: database, draft: SendEntryTestFixtures.draft(recipient: "")
                ) { recorder.actions.append($0) }
            }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 2 }
        let inputCell = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendRecipientPaste", in: inputCell) != nil
                && list.numberOfSections == 2
        }
        UIPasteboard.general.items = []
        defer { UIPasteboard.general.items = [] }
        UIPasteboard.general.string = Fixtures.anotherRecipient
        try SendEntryUIProbe.activate("sendRecipientPaste", in: inputCell)
        host.rootView.endEditing(true)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendRecipientHistoryAssessment", in: host.rootView)?.accessibilityLabel
                == SendRecipientHistoryAssessment.newRecipient.message
        }
        let field = try #require(SendEntryUIProbe.views(UITextView.self, in: inputCell).first)
        #expect(field.text == Fixtures.anotherRecipient)
        #expect(recorder.actions.isEmpty)
        #expect(SendRecipientHistoryAssessment.newRecipient.message
            == "This is a new recipient. Verify the address carefully.")

        try await Fixtures.broadcast(in: database, address: Fixtures.anotherRecipient)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendRecipientHistoryAssessment", in: host.rootView)?.accessibilityLabel
                == SendRecipientHistoryAssessment.previouslySent(count: 1).message
        }
        UIPasteboard.general.string = "bitcoin:" + SendEntryTestFixtures.address(for: .bitcoin)
        try SendEntryUIProbe.activate("sendRecipientPaste", in: inputCell)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendRecipientHistoryAssessment", in: host.rootView) == nil
        }
        #expect(field.text == Fixtures.anotherRecipient)
        #expect(recorder.actions.isEmpty)
        #expect(SendEntryUIProbe.element("sendRecipientContinue", in: host.rootView)?
            .accessibilityTraits.contains(.notEnabled) == true)
    }

    private func expectNoRecentHistory(in list: UICollectionView) {
        // The caller checks the native section count, including offscreen rows.
        // Walking every subview also visits UIKit's reusable cells and their
        // cached accessibility nodes after deletion. Check the active native
        // cells and supplementary views for visible headers/empty content.
        let supplementaryViews = (list.collectionViewLayout.layoutAttributesForElements(in: list.bounds) ?? [])
            .compactMap { attributes -> UICollectionReusableView? in
                guard let kind = attributes.representedElementKind else { return nil }
                return list.supplementaryView(forElementKind: kind, at: attributes.indexPath)
            }
        #expect(!list.visibleCells.isEmpty)
        for view in list.visibleCells as [UIView] + supplementaryViews {
            for identifier in [
                "sendRecipientHistoryTitle", "sendRecipientHistoryEmpty",
                "sendRecentRecipient", "sendRecipientHistoryError"
            ] {
                #expect(SendEntryUIProbe.element(identifier, in: view) == nil)
            }
        }
    }

    private func regularGlassControlSizes(
        layout: NativeListTestLayout
    ) async throws -> (paste: CGSize, scan: CGSize) {
        // Compare with an actual native reference control at the same Dynamic
        // Type size, rather than forcing a fixed pixel height into production.
        let host = try NativeListTestHost(layout: layout) {
            HStack {
                Button("common.paste") { }
                    .accessibilityIdentifier("regularPasteGlassReference")
                Button("common.scan") { }
                    .accessibilityIdentifier("regularScanGlassReference")
            }
                .font(.subheadline.weight(.semibold))
                .walletAdaptiveGlassButtonStyle(tint: WalletTheme.accent)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            let paste = SendEntryUIProbe.element("regularPasteGlassReference", in: host.rootView)
            let scan = SendEntryUIProbe.element("regularScanGlassReference", in: host.rootView)
            return paste?.accessibilityFrame.height ?? 0 > 0
                && scan?.accessibilityFrame.height ?? 0 > 0
        }
        let paste = try #require(SendEntryUIProbe.element("regularPasteGlassReference", in: host.rootView))
        let scan = try #require(SendEntryUIProbe.element("regularScanGlassReference", in: host.rootView))
        return (paste.accessibilityFrame.size, scan.accessibilityFrame.size)
    }
}
