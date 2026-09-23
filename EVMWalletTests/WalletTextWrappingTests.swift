import CoreText
import Observation
import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct WalletTextWrappingTests {
    nonisolated private static let addresses = [
        SendEntryTestFixtures.address(for: .bitcoin),
        SendEntryTestFixtures.address(for: .ethereum),
        SendEntryTestFixtures.address(for: .stellar),
        SendEntryTestFixtures.address(for: .ton),
        String(repeating: "abcdef0123456789", count: 8)
    ]

    @Test(arguments: NativeListTestLayout.allCases)
    func prefilledRecipientHasNoHyphenationBeforeEditing(layout: NativeListTestLayout) async throws {
        let database = try WalletDatabase.temporary()
        let recipient = SendEntryTestFixtures.address(for: .bitcoin)
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendRecipientScreen(
                    database: database,
                    draft: SendEntryTestFixtures.draft(recipient: recipient)
                ) { _ in }
            }
        }
        defer { host.close() }
        let list = try await host.list()
        let cell = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        try await SendEntryUIProbe.wait(in: cell) {
            SendEntryUIProbe.views(UITextView.self, in: cell).contains { $0.text == recipient }
        }
        let input = try #require(SendEntryUIProbe.views(UITextView.self, in: cell).first { $0.text == recipient })
        #expect(!input.isFirstResponder)
        try expectUnhyphenated(input)
        #expect(input.text == recipient)
        #expect(input.bounds.width > 0)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func nativeTypingPreservesCharactersSelectionAndParagraphLayout(layout: NativeListTestLayout) async throws {
        let recorder = ListActionRecorder<String>()
        let initial = Self.addresses[3] // TON has real hyphens that must survive.
        let host = try NativeListTestHost(layout: layout) {
            WrappingInputFixture(initial: initial, onChange: { recorder.actions.append($0) })
                .walletTextInputConfiguration(layout.direction)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UITextView.self, in: host.rootView).contains { $0.text == initial }
        }
        let input = try #require(SendEntryUIProbe.views(UITextView.self, in: host.rootView).first)
        try expectUnhyphenated(input)
        let hadTextKit2 = input.textLayoutManager != nil
        input.becomeFirstResponder()
        input.selectedRange = NSRange(location: (initial as NSString).length, length: 0)
        input.insertText("A")
        try await SendEntryUIProbe.wait(in: host.rootView) { recorder.actions.last == initial + "A" }
        try expectUnhyphenated(input)
        #expect(input.text == initial + "A")
        #expect(input.selectedRange.location == (initial as NSString).length + 1)
        #expect((input.textLayoutManager != nil) == hadTextKit2)
        #expect(input.font != nil)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func exactIdentifierFitsNativeLayoutAndRetainsAccessibleValue(layout: NativeListTestLayout) async throws {
        let text = Self.addresses[4]
        let host = try NativeListTestHost(layout: layout) {
            WalletExactText(text, monospaced: true)
                .frame(width: 220)
                .fixedSize(horizontal: false, vertical: true)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UITextView.self, in: host.rootView).contains { $0.bounds.height > 0 }
        }
        let view = try #require(SendEntryUIProbe.views(UITextView.self, in: host.rootView).first)
        try expectUnhyphenated(view)
        #expect(view.text == text)
        #expect(view.accessibilityLabel == text)
        #expect(view.isSelectable)
        #expect(!view.isScrollEnabled)
        #expect(view.bounds.height >= view.sizeThatFits(CGSize(width: view.bounds.width, height: 10_000)).height - 1)
        let expected = UIFont.preferredFont(forTextStyle: .body, compatibleWith:
            UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(layout.textSize)))
        #expect(view.font?.pointSize == expected.pointSize)
        let color = try #require(view.textColor)
        #expect(color.resolvedColor(with: view.traitCollection)
            == UIColor.label.resolvedColor(with: view.traitCollection))
    }

    @Test
    func protectedExactValueCannotBeReadOrSelected() async throws {
        let host = try NativeListTestHost {
            WalletExactText("public-placeholder")
                .redacted(reason: .privacy)
                .environment(\.walletPrivacyShieldEnabled, true)
                .frame(width: 220)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            !SendEntryUIProbe.views(UITextView.self, in: host.rootView).isEmpty
        }
        let view = try #require(SendEntryUIProbe.views(UITextView.self, in: host.rootView).first)
        #expect(view.isHidden)
        #expect(!view.isSelectable)
        #expect(!view.isAccessibilityElement)
        #expect(view.accessibilityLabel == nil)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func updatingExactValueRemainsVisible(layout: NativeListTestLayout) async throws {
        let address = Self.addresses[0]
        let host = try NativeListTestHost(layout: layout) {
            WalletExactText(address)
                .redacted(reason: .invalidated)
                .frame(width: 220)
                .fixedSize(horizontal: false, vertical: true)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            !SendEntryUIProbe.views(UITextView.self, in: host.rootView).isEmpty
        }
        let view = try #require(SendEntryUIProbe.views(UITextView.self, in: host.rootView).first)
        #expect(!view.isHidden)
        #expect(view.isSelectable)
        #expect(view.accessibilityLabel == address)
        #expect(view.text == address)
    }

    @Test
    func exactValueReturnsAfterPrivacyAndPlaceholderMasking() async throws {
        let state = ExactTextRedactionTestState()
        let address = Self.addresses[3]
        let host = try NativeListTestHost {
            ExactTextRedactionTestView(address: address, state: state)
        }
        defer { host.close() }
        for reason in [RedactionReasons.privacy, .placeholder] {
            state.reasons = reason
            try await SendEntryUIProbe.wait(in: host.rootView) {
                SendEntryUIProbe.views(UITextView.self, in: host.rootView).first?.isHidden == true
            }
            let masked = try #require(SendEntryUIProbe.views(UITextView.self, in: host.rootView).first)
            #expect(!masked.isSelectable)
            #expect(!masked.isUserInteractionEnabled)
            #expect(!masked.isAccessibilityElement)
            #expect(masked.accessibilityLabel == nil)
            state.reasons = []
            try await SendEntryUIProbe.wait(in: host.rootView) {
                SendEntryUIProbe.views(UITextView.self, in: host.rootView).contains {
                    !$0.isHidden && $0.isSelectable && $0.accessibilityLabel == address
                        && $0.textLayoutManager?.textViewportLayoutController.viewportRange != nil
                }
            }
            #expect(masked.text == address)
            #expect(masked.isUserInteractionEnabled)
            #expect(masked.isAccessibilityElement)
            try expectUnhyphenated(masked)
        }
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func nativeTextPrivacyFollowsSettingsAndRestoresWithoutChangingValues(layout: NativeListTestLayout) async throws {
        let state = ExactTextPrivacyTestState()
        let host = try NativeListTestHost(layout: layout) { NativeTextPrivacyFixture(state: state) }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UITextView.self, in: host.rootView).count == 2
                && !SendEntryUIProbe.views(UITextField.self, in: host.rootView).isEmpty
        }
        let textViews = SendEntryUIProbe.views(UITextView.self, in: host.rootView)
        let field = try #require(SendEntryUIProbe.views(UITextField.self, in: host.rootView).first)
        let word = try #require(SendEntryUIProbe.views(UILabel.self, in: host.rootView).first { $0.text == "publicword" })
        let controls: [UIView] = textViews + [field, word]
        // Keep the system request in place while toggling the actual setting.
        // An inactive/snapshot request cannot override the user's Privacy off.
        for reason in [RedactionReasons.privacy, .invalidated, [.privacy, .invalidated], .placeholder] {
            state.reasons = reason
            for enabled in [false, true, false] {
                state.enabled = enabled
                let hidden = reason.contains(.placeholder) || (enabled && reason.contains(.privacy))
                try await SendEntryUIProbe.wait(in: host.rootView) {
                    controls.allSatisfy { $0.isHidden == hidden }
                }
                for text in textViews {
                    #expect(text.text == "public-address-0123456789")
                    #expect(text.isSelectable == !hidden)
                    #expect(text.isAccessibilityElement == !hidden)
                    try expectUnhyphenated(text)
                }
                #expect(field.text == "ham")
                #expect(word.text == "publicword")
            }
        }
        state.reasons = []
        try await SendEntryUIProbe.wait(in: host.rootView) { controls.allSatisfy { !$0.isHidden } }
    }

    @Test(arguments: addresses)
    func actualLineGlyphsDoNotGainHyphens(address: String) throws {
        let font = UIFont.monospacedSystemFont(ofSize: 22, weight: .regular)
        let attributed = WalletExactText.attributedText(address, font: font)
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed),
            CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 4_000), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        #expect(lines.count > 1)
        let visible = CTFrameGetVisibleStringRange(frame)
        #expect(visible.length == (address as NSString).length)
        var dash: UniChar = 45
        var dashGlyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font as CTFont, &dash, &dashGlyph, 1)
        var actualDashCount = 0
        for line in lines {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                actualDashCount += glyphs.filter { $0 == dashGlyph }.count
            }
        }
        #expect(actualDashCount == address.filter { $0 == "-" }.count)
        #expect(attributed.string == address)
    }

    @Test
    func exportedAddressLayoutKeepsTheFullOriginalValue() {
        let address = "sp1" + String(repeating: "abcdefghijk23456", count: 8)
        let layout = ReceiveShareAddressText.layout(address: address, width: 900)
        #expect(layout.attributedText.string == address)
        #expect(CTFrameGetVisibleStringRange(layout.frame).length == (address as NSString).length)
        #expect((CTFrameGetLines(layout.frame) as! [CTLine]).count <= 2)
        let paragraph = layout.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(paragraph?.usesDefaultHyphenation == false)
        #expect(paragraph?.hyphenationFactor == 0)
    }

    private func expectUnhyphenated(_ input: UITextView) throws {
        if let manager = input.textLayoutManager { #expect(!manager.usesHyphenation) }
        else { #expect(!input.layoutManager.usesDefaultHyphenation) }
        let style = try #require(input.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        #expect(!style.usesDefaultHyphenation)
        #expect(style.hyphenationFactor == 0)
        input.textStorage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: input.textStorage.length)) {
            value, _, _ in
            let style = value as? NSParagraphStyle
            #expect(style?.usesDefaultHyphenation == false)
            #expect(style?.hyphenationFactor == 0)
        }
    }
}

private struct WrappingInputFixture: View {
    @State var text: String
    let onChange: (String) -> Void

    init(initial: String, onChange: @escaping (String) -> Void) {
        _text = State(initialValue: initial)
        self.onChange = onChange
    }

    var body: some View {
        TextField("", text: $text, axis: .vertical)
            .walletTextInputDirection()
            .walletNonHyphenatingInput()
            .lineLimit(3...5)
            .frame(width: 220)
            .onChange(of: text) { _, value in onChange(value) }
    }
}

@MainActor
@Observable
private final class ExactTextRedactionTestState {
    var reasons: RedactionReasons = []
}

private struct ExactTextRedactionTestView: View {
    let address: String
    let state: ExactTextRedactionTestState

    var body: some View {
        WalletExactText(address)
            .redacted(reason: state.reasons)
            .environment(\.walletPrivacyShieldEnabled, true)
            .frame(width: 220)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
@Observable
private final class ExactTextPrivacyTestState {
    var reasons: RedactionReasons = []
    var enabled = false
}

private struct NativeTextPrivacyFixture: View {
    let state: ExactTextPrivacyTestState

    var body: some View {
        VStack {
            WalletExactText("public-address-0123456789")
            ReceiveAddressText("public-address-0123456789")
            RecoveryPhraseWordLabel(word: "publicword")
            RecoveryPhraseInlineInput(
                text: "ham", completion: { _ in nil }, hasOtherWords: false,
                isFocused: false, selectionRequest: nil, onFocusChange: { _ in },
                onChange: { $0 }, onDeleteBackward: { _ in nil }, onSubmit: { _ in false }
            )
        }
        .frame(width: 220)
        .redacted(reason: state.reasons)
        .environment(\.walletPrivacyShieldEnabled, state.enabled)
    }
}
