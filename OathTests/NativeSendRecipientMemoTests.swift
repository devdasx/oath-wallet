import SwiftUI
import Testing
import UIKit
@testable import Aperture

/// Tests the real SwiftUI List, native cell highlighting, text fields and
/// Continue action. No screenshot capture, private wallet or network broadcast.
@MainActor
@Suite(.serialized)
struct NativeSendRecipientMemoTests {
    private typealias Fixtures = SendRecipientHistoryTestFixtures

    @Test(arguments: NativeListTestLayout.allCases)
    func recipientUsesTheSameNativeRowInsetsAsTheMemoField(
        layout: NativeListTestLayout
    ) async throws {
        let database = try WalletDatabase.temporary()
        let asset = try Fixtures.asset(networkID: "stellar")
        _ = try await Fixtures.seed(database, asset: asset)
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendRecipientScreen(
                    database: database,
                    draft: SendEntryTestFixtures.draft(asset: asset, recipient: "")
                ) { _ in }
            }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 3 }
        let inputCell = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UITextView.self, in: inputCell).first?.bounds.width ?? 0 > 0
        }
        let input = try #require(SendEntryUIProbe.views(UITextView.self, in: inputCell).first)
        let inputFrame = input.convert(input.bounds, to: inputCell)
        let inputLeadingInset = inputFrame.minX - inputCell.bounds.minX
        let inputTrailingInset = inputCell.bounds.maxX - inputFrame.maxX

        host.rootView.endEditing(true)
        let memoCell = try await host.cell(at: IndexPath(item: 0, section: 2), in: list)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UITextField.self, in: memoCell).first?.bounds.width ?? 0 > 0
        }
        let memo = try #require(SendEntryUIProbe.views(UITextField.self, in: memoCell).first)
        let memoFrame = memo.convert(memo.bounds, to: memoCell)
        let nativeLeadingInset = memoFrame.minX - memoCell.bounds.minX
        let nativeTrailingInset = memoCell.bounds.maxX - memoFrame.maxX

        // Compare actual native controls rather than hardcoding iPhone insets;
        // UIKit owns the adaptive margins for iPad, rotation and Dynamic Type.
        #expect(abs(inputLeadingInset - nativeLeadingInset) < 1,
                "Recipient inset \(inputLeadingInset) must match native inset \(nativeLeadingInset)")
        #expect(abs(inputTrailingInset - nativeTrailingInset) < 1,
                "Recipient inset \(inputTrailingInset) must match native inset \(nativeTrailingInset)")
        #expect(nativeLeadingInset > 0 && nativeTrailingInset > 0)
    }

    @Test(arguments: ["xrp", "stellar", "ton", "solana"], NativeListTestLayout.allCases)
    func nativeRecentRowsRestoreAndDistinguishRecipientRouting(
        networkID: String, layout: NativeListTestLayout
    ) async throws {
        let database = try WalletDatabase.temporary()
        let asset = try Fixtures.asset(networkID: networkID)
        let scope = try await Fixtures.seed(database, asset: asset)
        try await Fixtures.broadcast(in: database, asset: asset, hash: "old-no-memo", date: 5)
        try await Fixtures.broadcast(in: database, asset: asset, hash: "one", memo: "123", date: 10)
        try await Fixtures.broadcast(in: database, asset: asset, hash: "two", memo: "123", date: 20)
        try await Fixtures.broadcast(in: database, asset: asset, hash: "different", memo: "456", date: 30)
        let saved = try await database.sendRecipientHistorySnapshot(scope: scope).recentRecipients
        let recorder = ListActionRecorder<SendDraft>()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendRecipientScreen(
                    database: database,
                    draft: SendEntryTestFixtures.draft(asset: asset, recipient: "", amount: "1.25", memo: "999")
                ) { recorder.actions.append($0) }
            }
        }
        defer { host.close() }
        let hasMemoField = networkID == "xrp" || networkID == "stellar"
        let section = hasMemoField ? 3 : 2
        let list = try await host.list { $0.numberOfSections == section + 1 }
        try await SendEntryUIProbe.wait(in: host.rootView) { list.numberOfItems(inSection: section) == 3 }
        host.rootView.endEditing(true)

        for (index, expected) in saved.enumerated() {
            let path = IndexPath(item: index, section: section)
            var cell = try await host.cell(at: path, in: list)
            try await SendEntryUIProbe.wait(in: host.rootView) {
                cell = list.cellForItem(at: path) ?? cell
                return SendEntryUIProbe.element("sendRecentRecipient", in: cell) != nil
            }
            let row = try #require(SendEntryUIProbe.element("sendRecentRecipient", in: cell))
            #expect(row.accessibilityLabel == expected.address)
            #expect(row.accessibilityValue == expected.accessibilityValue)
            #expect(row.accessibilityValue?.contains(expected.memoText ?? "") == true)
            // Calls the native list primary action and verifies that UIKit
            // still owns selection and highlight, including RTL/large text.
            try await host.selectRow(path, in: list)
            let input = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
            try await SendEntryUIProbe.wait(in: host.rootView) {
                SendEntryUIProbe.element("sendRecipientHistoryAssessment", in: host.rootView)?.accessibilityLabel
                    == SendRecipientHistoryAssessment.previouslySent(count: expected.sendCount).message
            }
            let addressField = try #require(SendEntryUIProbe.views(UITextView.self, in: input).first)
            #expect(addressField.text == expected.address)
            if hasMemoField {
                let memoCell = try await host.cell(at: IndexPath(item: 0, section: 2), in: list)
                try await SendEntryUIProbe.wait(in: host.rootView) {
                    SendEntryUIProbe.views(UITextField.self, in: memoCell).first?.text == (expected.networkMemo ?? "")
                }
                let memoField = try #require(SendEntryUIProbe.views(UITextField.self, in: memoCell).first)
                #expect(memoField.text == (expected.networkMemo ?? ""))
                if networkID == "xrp" { #expect(memoField.keyboardType == .asciiCapableNumberPad) }
            }
            try SendEntryUIProbe.activate("sendRecipientContinue", in: host.rootView)
            let draft = try #require(recorder.actions.last)
            #expect(draft.recipient == expected.address)
            #expect(draft.request.memo == expected.networkMemo)
            #expect(draft.amount == "1.25")
        }
        #expect(recorder.actions.count == 3)
        #expect(recorder.actions.map { $0.request.memo } == ["456", "123", nil])
    }
}
