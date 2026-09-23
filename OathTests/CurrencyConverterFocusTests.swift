import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct CurrencyConverterFocusTests {
    @Test(arguments: [false, true], [NativeListTestLayout.phone, .pad, .phoneLandscape, .largeTextRTL])
    func focusesLastUsedCurrencyAndRemembersUserEdits(
        settingsFlow: Bool,
        layout: NativeListTestLayout
    ) async throws {
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        try await database.saveCurrencyConverterSelection(CurrencyConverterSelection(
            unitIDs: ["fiat:EUR", "fiat:USD"],
            lastUsedUnitID: "fiat:USD"
        ))
        let host = try makeHost(database: database, settings: settings, settingsFlow: settingsFlow, layout: layout)
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            field("USD", in: host)?.isFirstResponder == true
        }
        // Restore the saved editing currency without reordering the rows.
        #expect(field("EUR", in: host)?.isFirstResponder != true)
        let list = try await host.list()
        _ = try await host.cell(at: IndexPath(item: 0, section: list.numberOfSections - 1), in: list)
        let euro = try #require(field("EUR", in: host))
        #expect(euro.becomeFirstResponder())
        euro.insertText("2")
        try await waitForSavedFocus("fiat:EUR", database: database)
        #expect(try await database.currencyConverterSelection()?.unitIDs == ["fiat:EUR", "fiat:USD"])

        // Dismissing editing must not trigger the one-time restoration again.
        try await SendEntryUIProbe.wait(in: host.rootView) {
            euro.isFirstResponder && euro.inputAccessoryView is WalletKeyboardAccessoryView
        }
        let accessory = try #require(euro.inputAccessoryView as? WalletKeyboardAccessoryView)
        accessory.confirmButton.sendActions(for: .touchUpInside)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            !SendEntryUIProbe.views(UITextField.self, in: host.rootView).contains(where: \.isFirstResponder)
        }
        host.rootView.setNeedsLayout()
        host.rootView.layoutIfNeeded()
        await Task.yield()
        #expect(!euro.isFirstResponder)
        host.close()

        let reopened = try makeHost(database: database, settings: settings, settingsFlow: settingsFlow, layout: layout)
        defer { reopened.close() }
        try await SendEntryUIProbe.wait(in: reopened.rootView) {
            field("EUR", in: reopened)?.isFirstResponder == true
        }
        #expect(field("USD", in: reopened)?.isFirstResponder != true)
    }

    @Test
    func firstOpeningUsesFirstCurrency() async throws {
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        let host = try makeHost(database: database, settings: settings, settingsFlow: false, layout: .phone)
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            field("EUR", in: host)?.isFirstResponder == true
        }
    }

    @Test
    func homeSheetFocusesDuringNativePresentation() async throws {
        let database = try WalletDatabase.temporary()
        try await database.saveCurrencyConverterSelection(CurrencyConverterSelection(
            unitIDs: ["fiat:EUR", "fiat:USD"], lastUsedUnitID: "fiat:USD"
        ))
        let host = try NativeListTestHost {
            Color.clear.sheet(isPresented: .constant(true)) {
                NavigationStack {
                    HomeCurrencyConverterSheet(database: database)
                }
                .environment(\.walletCurrencyContext, WalletCurrencyContext(code: "EUR", ratePerUSD: 0.9))
            }
        }
        defer { host.close() }
        let window = try #require(host.rootView.window)
        try await SendEntryUIProbe.wait(in: window) {
            SendEntryUIProbe.views(UITextField.self, in: window).contains(where: \.isFirstResponder)
        }
        let focusedInput = SendEntryUIProbe.views(UITextField.self, in: window).first { $0.isFirstResponder }
        let input = try #require(focusedInput)
        let list = try #require(SendEntryUIProbe.views(UICollectionView.self, in: window).first)
        let matchingCell = list.visibleCells.first { input.isDescendant(of: $0) }
        let cell = try #require(matchingCell)
        #expect(list.indexPath(for: cell)?.item == 1)
        #expect(input.keyboardType == .decimalPad)
        #expect(host.rootView.window?.rootViewController?.presentedViewController != nil)
    }

    @Test(arguments: [false, true], NativeListTestLayout.allCases)
    func typedAmountRemainsVisible(settingsFlow: Bool, layout: NativeListTestLayout) async throws {
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        let host = try makeHost(database: database, settings: settings,
                                settingsFlow: settingsFlow, layout: layout)
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            field("EUR", in: host)?.isFirstResponder == true
        }
        let input = try #require(field("EUR", in: host))
        input.selectedTextRange = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)
        input.insertText("")
        for character in "50000" {
            input.insertText(String(character))
            await Task.yield()
            host.rootView.layoutIfNeeded()
        }
        #expect(input.text == "50000")
        #expect(input.bounds.width >= input.font?.pointSize ?? 0)
        // Continue editing, delete, replace a selection, and refocus: the same
        // field must retain both its value and a visible insertion point.
        input.insertText(".25")
        input.deleteBackward()
        await Task.yield()
        host.rootView.layoutIfNeeded()
        #expect(input.text == "50000.2")
        input.selectedTextRange = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)
        input.insertText("125.5")
        input.resignFirstResponder()
        #expect(input.becomeFirstResponder())
        await Task.yield()
        host.rootView.layoutIfNeeded()
        #expect(input.text == "125.5")
        #expect((input.textColor?.cgColor.alpha ?? 0) > 0,
                "Text color \(String(describing: input.textColor)), attributes \(String(describing: input.attributedText))")
        if let text = input.attributedText {
            text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                if let color = value as? UIColor {
                    #expect(color.cgColor.alpha > 0, "Invisible glyphs \(range), attributes \(text)")
                }
            }
        }
        try expectAmountStartsAtLeft(input)
        // Converted results and the active input must share the same alignment.
        let converted = try #require(field("USD", in: host))
        try expectAmountStartsAtLeft(converted)
        #expect(converted.becomeFirstResponder())
        await Task.yield()
        host.rootView.layoutIfNeeded()
        try expectAmountStartsAtLeft(input)
        try expectAmountStartsAtLeft(converted)
        #expect(input.becomeFirstResponder())
        await Task.yield()
        host.rootView.layoutIfNeeded()
        let range = try #require(input.textRange(from: input.beginningOfDocument, to: input.endOfDocument))
        let textRect = input.firstRect(for: range)
        let caret = input.caretRect(for: input.endOfDocument)
        #expect(input.bounds.insetBy(dx: -2, dy: -2).intersects(caret))
        #expect(input.bounds.intersects(textRect), "Text \(textRect), caret \(caret), bounds \(input.bounds), color \(String(describing: input.textColor)), attributes \(String(describing: input.attributedText))")
    }

    private func expectAmountStartsAtLeft(_ input: UITextField) throws {
        // Inspect actual glyph geometry, not only the configured alignment.
        let end = try #require(input.position(from: input.beginningOfDocument, offset: 1))
        let firstCharacter = try #require(input.textRange(from: input.beginningOfDocument, to: end))
        let glyph = input.firstRect(for: firstCharacter)
        #expect(abs(glyph.minX - input.bounds.minX) <= 4,
                "Amount starts at \(glyph.minX) instead of left edge \(input.bounds.minX)")
    }

    private func makeHost(
        database: WalletDatabase,
        settings: WalletSettingsStore,
        settingsFlow: Bool,
        layout: NativeListTestLayout
    ) throws -> NativeListTestHost {
        try NativeListTestHost(layout: layout) {
            NavigationStack {
                if settingsFlow {
                    CurrencyConverterView(database: database)
                } else {
                    HomeCurrencyConverterSheet(database: database)
                }
            }
            .walletTextInputConfiguration(layout.direction)
            .environment(settings)
            .environment(\.walletCurrencyContext, WalletCurrencyContext(code: "EUR", ratePerUSD: 0.9))
        }
    }

    private func field(_ code: String, in host: NativeListTestHost) -> UITextField? {
        // SwiftUI owns the accessibility identifier; inspect the UIKit input
        // inside the known fixture row to verify real first-responder status.
        guard let list = SendEntryUIProbe.views(UICollectionView.self, in: host.rootView).first,
              list.numberOfSections > 0,
              let cell = list.cellForItem(at: IndexPath(
                item: code == "EUR" ? 0 : 1, section: list.numberOfSections - 1
              )) else { return nil }
        return SendEntryUIProbe.views(UITextField.self, in: cell).first
    }

    private func waitForSavedFocus(_ unitID: String, database: WalletDatabase) async throws {
        for _ in 0..<100 {
            if try await database.currencyConverterSelection()?.lastUsedUnitID == unitID { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await database.currencyConverterSelection()?.lastUsedUnitID == unitID)
    }
}
