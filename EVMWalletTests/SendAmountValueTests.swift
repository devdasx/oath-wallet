import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct SendAmountValueTests {
    @Test(arguments: ["", "0", "1.2300", "0.000000000000000000000001", String(repeating: "9", count: 200)])
    func initialValueIsExactAndDoesNotAnimate(value: String) {
        let model = SendAmountGlyphPresentation(input: .init(value: value, typingRevision: 0))
        #expect(model.input.value == value)
        #expect(model.input.text == (value.isEmpty ? "0" : value))
        #expect(!model.usesNumericTransition)
    }

    @Test
    func everyTypedLengthChangeUsesOneNativeNumericTransition() {
        var model = SendAmountGlyphPresentation(input: .init(value: "11", typingRevision: 0))
        let firstAnimated = model.update(
            to: .init(value: "111", typingRevision: 1),
            animate: true
        )
        #expect(firstAnimated)
        #expect(model.usesNumericTransition)
        #expect(!model.countsDown)
        let secondAnimated = model.update(
            to: .init(value: "1111", typingRevision: 2),
            animate: true
        )
        #expect(secondAnimated)
        #expect(model.usesNumericTransition)
        #expect(!model.countsDown)
        #expect(model.input.text == "1111")
    }

    @Test
    func decimalLeadingZeroAndReplacementUseNativeCountingDirection() {
        var model = SendAmountGlyphPresentation(input: .init(value: "", typingRevision: 0))
        let decimalAnimated = model.update(
            to: .init(value: "0.", typingRevision: 1),
            animate: true
        )
        #expect(decimalAnimated)
        #expect(!model.countsDown)
        let fractionAnimated = model.update(
            to: .init(value: "0.0", typingRevision: 2),
            animate: true
        )
        #expect(fractionAnimated)
        #expect(!model.countsDown)
        let programmaticAnimated = model.update(
            to: .init(value: "0", typingRevision: 2),
            animate: true
        )
        #expect(!programmaticAnimated)
        let replacementAnimated = model.update(
            to: .init(value: "7", typingRevision: 3),
            animate: true
        )
        #expect(replacementAnimated)
        #expect(model.usesNumericTransition)
        #expect(!model.countsDown)
    }

    @Test
    func rapidDeleteAndRetypeUpdatesOneTransitionState() {
        var model = SendAmountGlyphPresentation(input: .init(value: "1", typingRevision: 0))
        let firstAdditionAnimated = model.update(
            to: .init(value: "12", typingRevision: 1),
            animate: true
        )
        #expect(firstAdditionAnimated)
        #expect(!model.countsDown)
        let deletionAnimated = model.update(
            to: .init(value: "1", typingRevision: 2),
            animate: true
        )
        #expect(deletionAnimated)
        #expect(model.countsDown)
        let secondAdditionAnimated = model.update(
            to: .init(value: "12", typingRevision: 3),
            animate: true
        )
        #expect(secondAdditionAnimated)
        #expect(!model.countsDown)
        #expect(model.input.text == "12")
    }

    @Test
    func maxConversionAndRestoredAmountsDoNotReplayTypingAnimations() {
        var model = SendAmountGlyphPresentation(input: .init(value: "12", typingRevision: 0))
        model.update(to: .init(value: "123", typingRevision: 1), animate: true)
        for value in ["12", "1", "", "0.000000000000000000000001", "1200.00", "1200.0001"] {
            let animated = model.update(
                to: .init(value: value, typingRevision: 1),
                animate: true
            )
            #expect(!animated)
            #expect(!model.usesNumericTransition)
            #expect(model.input.value == value)
        }
    }

    @Test(arguments: ["12", "0.01", "0.00", "1.", String(repeating: "9", count: 199)])
    func backspaceUsesNativeNumericTransitionAndCountsDown(value: String) {
        var model = SendAmountGlyphPresentation(input: .init(
            value: value, typingRevision: 0, currencyPrefix: "$"
        ))
        let animated = model.update(to: .init(
            value: String(value.dropLast()), typingRevision: 1, currencyPrefix: "$"
        ), animate: true)
        #expect(animated)
        #expect(model.countsDown)
        #expect(model.usesNumericTransition)
        #expect(model.input.text == "$" + String(value.dropLast()))
    }

    @Test
    func replacingZeroAndDeletingFinalDigitUseNativeNumericTransition() {
        var model = SendAmountGlyphPresentation(input: .init(value: "", typingRevision: 0))
        model.update(to: .init(value: "9", typingRevision: 1), animate: true)
        #expect(model.usesNumericTransition)
        #expect(!model.countsDown)
        model.update(to: .init(value: "", typingRevision: 2), animate: true)
        #expect(model.input.text == "0")
        #expect(model.usesNumericTransition)
        #expect(model.countsDown)
    }

    @Test(arguments: ["$", "€", "£", "AED\u{00a0}", "CHF\u{00a0}"])
    func currencyPrefixChangeNeverTriggersATypingTransition(prefix: String) {
        var model = SendAmountGlyphPresentation(input: .init(
            value: "1", typingRevision: 0, currencyPrefix: prefix
        ))
        let additionAnimated = model.update(
            to: .init(value: "12", typingRevision: 1, currencyPrefix: prefix),
            animate: true
        )
        #expect(additionAnimated)
        #expect(model.usesNumericTransition)
        let deletionAnimated = model.update(
            to: .init(value: "1", typingRevision: 2, currencyPrefix: prefix),
            animate: true
        )
        #expect(deletionAnimated)
        #expect(model.countsDown)
        // Currency selection is a programmatic change, never a typing/counting animation.
        let currencyChangeAnimated = model.update(
            to: .init(value: "3.6725", typingRevision: 2, currencyPrefix: "AED "),
            animate: true
        )
        #expect(!currencyChangeAnimated)
        #expect(!model.usesNumericTransition)
    }

    @Test
    func reduceMotionAndInterruptedPresentationAreImmediate() {
        var model = SendAmountGlyphPresentation(input: .init(value: "1", typingRevision: 0))
        model.update(to: .init(value: "12", typingRevision: 1), animate: true)
        #expect(model.usesNumericTransition)
        model.update(to: .init(value: "123", typingRevision: 2), animate: false)
        #expect(!model.usesNumericTransition)
        #expect(model.input.value == "123")
        model.update(to: .init(value: "1234", typingRevision: 3), animate: true)
        #expect(model.usesNumericTransition)
        model.finishTransition()
        #expect(!model.usesNumericTransition)
        #expect(model.input.value == "1234")
    }

    @Test
    func rapidTypingKeepsOnlyTheLatestExactInput() {
        var model = SendAmountGlyphPresentation(input: .init(value: "", typingRevision: 0))
        for index in 1...200 {
            let animated = model.update(
                to: .init(value: String(repeating: "1", count: index), typingRevision: index), animate: true
            )
            #expect(animated)
            #expect(model.usesNumericTransition)
            #expect(!model.countsDown)
        }
        #expect(model.input.value == String(repeating: "1", count: 200))
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func nativeGlyphLayoutIsCenteredAndKeepsDecimalOrderInEveryDirection(
        layout: NativeListTestLayout
    ) async throws {
        let model = AmountValueTestModel(value: "12.345")
        let observation = AmountValueLayoutObservation()
        let host = try NativeListTestHost(layout: layout) {
            AmountValueTestHarness(model: model, observation: observation)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) { !observation.snapshots.isEmpty }
        let snapshot = try #require(observation.snapshots.first)
        let glyphs = amountGlyphs(in: snapshot.layout)
        #expect(glyphs.map(\.offset) == Array(0..<6))
        let glyphFrames = glyphs.map { $0.slice.typographicBounds.rect }
        for (left, right) in zip(glyphFrames, glyphFrames.dropFirst()) {
            #expect(left.minX < right.minX, "ASCII amount order must come from native text shaping")
        }
        let ink = glyphFrames.reduce(CGRect.null) { $0.union($1) }
        #expect(abs(snapshot.origin.x + ink.midX - snapshot.size.width / 2) < 3)
        #expect(ink.height > 0)
        if layout == .phone { #expect(ink.height > 60, "The amount uses a 64-point rounded base font") }
        #expect(ink.width <= snapshot.size.width)
        let value = try #require(SendEntryUIProbe.element("sendAmountValue", in: host.rootView))
        #expect(value.accessibilityValue == "12.345 ETH")
        #expect(value.accessibilityElementCount() <= 0)
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func nativeTransitionKeepsOneFittedTextLayoutDuringRapidEdits(
        layout: NativeListTestLayout
    ) async throws {
        let model = AmountValueTestModel(value: "12.3")
        let observation = AmountValueLayoutObservation()
        let host = try NativeListTestHost(layout: layout) {
            AmountValueTestHarness(model: model, observation: observation)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) { observation.snapshots.count == 1 }
        model.value = "12.34"
        model.typingRevision += 1
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendAmountValue", in: host.rootView)?
                .accessibilityValue == "12.34 ETH"
        }
        #expect(observation.snapshots.count == 1)
        model.value = "12.344"
        model.typingRevision += 1
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendAmountValue", in: host.rootView)?
                .accessibilityValue == "12.344 ETH"
        }
        #expect(observation.snapshots.count == 1)
        #expect(SendEntryUIProbe.element("sendAmountValue", in: host.rootView)?.accessibilityValue == "12.344 ETH")
        model.value = "12.34"
        model.typingRevision += 1
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendAmountValue", in: host.rootView)?.accessibilityValue == "12.34 ETH"
        }
        #expect(observation.snapshots.count == 1)

        // A typed digit can be replaced by Max and immediately followed by a
        // different typed digit without retaining a stale fitted layer.
        model.value = "12.344"
        model.typingRevision += 1
        model.value = "100"
        model.value = "1001"
        model.typingRevision += 1
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendAmountValue", in: host.rootView)?
                .accessibilityValue == "1001 ETH"
        }
        #expect(observation.snapshots.count == 1)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func longAmountsPreserveExactAccessibleValueWithoutOverflowOrAnimation(
        layout: NativeListTestLayout
    ) async throws {
        let value = "0." + String(repeating: "1234567890", count: 19)
        let model = AmountValueTestModel(value: value)
        let observation = AmountValueLayoutObservation()
        let host = try NativeListTestHost(layout: layout) {
            AmountValueTestHarness(model: model, observation: observation)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) { observation.snapshots.count == 1 }
        let element = try #require(SendEntryUIProbe.element("sendAmountValue", in: host.rootView))
        #expect(element.accessibilityValue == value + " ETH")
        #expect(element.accessibilityFrame.width <= host.rootView.bounds.width)
        let snapshot = try #require(observation.snapshots.first)
        #expect(snapshot.layout.count == 1)
        #expect(amountGlyphs(in: snapshot.layout).count == value.count,
                "Never truncate the amount to an ellipsis or wrap it to another line")
        // Programmatic Max/conversion updates do not increment typingRevision.
        model.value = value + "1"
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendAmountValue", in: host.rootView)?.accessibilityValue == value + "1 ETH"
        }
        #expect(observation.snapshots.count == 1)
    }

    @Test(arguments: NativeListTestLayout.allCases, ["$", "€", "AED\u{00a0}"])
    func currencyAndAmountFitTogetherOnOneLineInNativeReadingOrder(
        layout: NativeListTestLayout, prefix: String
    ) async throws {
        let model = AmountValueTestModel(value: "123.4500", currencyPrefix: prefix)
        let observation = AmountValueLayoutObservation()
        let host = try NativeListTestHost(layout: layout) {
            AmountValueTestHarness(model: model, observation: observation)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) { observation.snapshots.count == 1 }
        let short = try #require(observation.snapshots.first)
        let glyphs = amountGlyphs(in: short.layout)
        #expect(short.layout.count == 1)
        #expect(Set(glyphs.map(\.offset)) == Set(0..<(prefix.count + model.value.count)))
        let prefixFrame = glyphs.filter { $0.offset < prefix.count }
            .reduce(CGRect.null) { $0.union($1.slice.typographicBounds.rect) }
        let digitsFrame = glyphs.filter { $0.offset >= prefix.count }
            .reduce(CGRect.null) { $0.union($1.slice.typographicBounds.rect) }
        #expect(prefixFrame.maxX <= digitsFrame.minX + 1)

        model.value = String(repeating: "9", count: 200)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            observation.snapshots.first.map {
                amountGlyphs(in: $0.layout).count == prefix.count + 200
            } == true
        }
        let long = try #require(observation.snapshots.first)
        #expect(long.layout.count == 1)
        let longFrame = amountGlyphs(in: long.layout)
            .reduce(CGRect.null) { $0.union($1.slice.typographicBounds.rect) }
        #expect(abs(long.size.width - short.size.width) < 1)
        #expect(abs(long.size.height - short.size.height) < 1)
        #expect(longFrame.width <= long.size.width + 1)
        #expect(longFrame.height < digitsFrame.height, "More digits must reduce the native fitted font size")
    }
}

private struct AmountGlyph {
    let offset: Int
    let slice: Text.Layout.RunSlice
}

private func amountGlyphs(in layout: Text.Layout) -> [AmountGlyph] {
    let runs = layout.flatMap { $0 }
    guard let start = runs.flatMap(\.characterIndices).min() else {
        return []
    }
    return runs.flatMap { run in
        zip(run.indices, run.characterIndices).map {
            index, characterIndex in
            AmountGlyph(
                offset: start.distance(to: characterIndex),
                slice: run[index]
            )
        }
    }
}

@MainActor @Observable
private final class AmountValueTestModel {
    var value: String
    var typingRevision = 0
    var currencyPrefix: String
    init(value: String, currencyPrefix: String = "") {
        self.value = value
        self.currencyPrefix = currencyPrefix
    }
}

@MainActor
private final class AmountValueLayoutObservation {
    struct Snapshot: Equatable {
        let layout: Text.Layout
        let origin: CGPoint
        let size: CGSize
    }
    var snapshots: [Snapshot] = []
}

/// Native layout preferences and accessibility only; no image rendering/capture.
private struct AmountValueTestHarness: View {
    let model: AmountValueTestModel
    let observation: AmountValueLayoutObservation

    var body: some View {
        List {
            Section { amount }
        }
        .listStyle(.insetGrouped)
    }

    private var amount: some View {
        SendAmountValue(
            value: model.value, unit: "ETH", typingRevision: model.typingRevision,
            currencyPrefix: model.currencyPrefix
        )
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { geometry in
                    let snapshots = layouts.map {
                        AmountValueLayoutObservation.Snapshot(
                            layout: $0.layout, origin: geometry[$0.origin], size: geometry.size
                        )
                    }
                    Color.clear
                        .onAppear { observation.snapshots = snapshots }
                        .onChange(of: snapshots) { _, updated in observation.snapshots = updated }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}
