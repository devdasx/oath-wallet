import Observation
import os
import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct WalletHomeBalanceCardTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func cardUsesOpaqueCharcoalAndWhiteText(scheme: ColorScheme) {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let surface = WalletTheme.balanceCardSurface.resolve(in: environment)
        #expect(surface.opacity == 1)
        let grid = WalletTheme.balanceCardGrid.resolve(in: environment)
        #expect(luminance(of: grid) > luminance(of: surface))
        let channels = [surface.red, surface.green, surface.blue]
        #expect(channels.allSatisfy { $0 > 0.05 && $0 < 0.2 })
        #expect((channels.max()! - channels.min()!) < 0.03)

        for color in [WalletTheme.balanceCardInk, WalletTheme.balanceCardSecondaryInk] {
            let text = color.resolve(in: environment)
            #expect(text.red == 1 && text.green == 1 && text.blue == 1)
            #expect(text.opacity == 1)
            #expect(contrast(text, surface) >= 7)
            #expect(contrast(text, grid) >= 7)
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func graphiteChipKeepsItsWhiteSymbolReadable(scheme: ColorScheme) {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let chip = WalletTheme.balanceCardChipSurface.resolve(in: environment)
        let ink = WalletTheme.balanceCardInk.resolve(in: environment)
        let border = WalletTheme.balanceCardChipBorder.resolve(in: environment)
        let card = WalletTheme.balanceCardSurface.resolve(in: environment)
        #expect(chip.opacity == 1 && border.opacity == 1)
        #expect(luminance(of: chip) > luminance(of: card))
        #expect(luminance(of: border) > luminance(of: chip))
        #expect(contrast(ink, chip) >= 4.5)
    }

    private func contrast(_ first: Color.Resolved, _ second: Color.Resolved) -> Double {
        let values = [luminance(of: first), luminance(of: second)]
        return (values.max()! + 0.05) / (values.min()! + 0.05)
    }

    private func luminance(of color: Color.Resolved) -> Double {
        func linear(_ value: Float) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    @Test(arguments: [CGFloat(320), 393, 744, 1_024], BalanceCardTestEnvironment.allCases)
    func cardFitsPhoneAndPadWithStandardProportionsAndAccessibleGrowth(
        width: CGFloat,
        environment: BalanceCardTestEnvironment
    ) async throws {
        let model = BalanceCardTestModel()
        let measurements = BalanceCardTextMeasurements()
        let host = try makeHost(width: width, environment: environment, model: model, measurements: measurements)
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            model.cardFrame.width > 0 && measurements.snapshot.count > 0
        }

        let expectedWidth = min(width - 40, CGFloat(440))
        #expect(abs(model.cardFrame.width - expectedWidth) <= 1)
        #expect(model.cardFrame.minX >= 20 - 1)
        #expect(model.cardFrame.maxX <= width - 20 + 1)
        let standardHeight = expectedWidth / (1536.0 / 969.0)
        if environment == .accessibilityRTL {
            #expect(model.cardFrame.height >= standardHeight - 1)
        } else {
            #expect(abs(model.cardFrame.height - standardHeight) <= 1)
        }
        #expect(!measurements.snapshot.contains { $0.isTruncated })
    }

    @Test(arguments: BalanceCardTestEnvironment.allCases)
    func giantBalanceFitsAndCardDoesNotJumpWhenTheAmountChanges(
        environment: BalanceCardTestEnvironment
    ) async throws {
        let model = BalanceCardTestModel()
        let measurements = BalanceCardTextMeasurements()
        let host = try makeHost(width: 320, environment: environment, model: model, measurements: measurements)
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            model.cardFrame.width > 0 && measurements.snapshot.count > 0
        }
        let initialSize = model.cardFrame.size
        for amount in ["211656098495.01", "999999999999999999999999999999999999.99", "1"] {
            measurements.clear()
            model.amount = try #require(Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")))
            try await SendEntryUIProbe.wait(in: host.rootView) {
                measurements.snapshot.count > 0
            }
            // Allow SwiftUI's native 0.3-second numeric transition to settle.
            try await Task.sleep(for: .milliseconds(350))
            let layouts = measurements.snapshot
            #expect(!layouts.contains { $0.isTruncated })
            #expect(layouts.allSatisfy { $0.width <= model.cardFrame.width + 1 })
            #expect(abs(model.cardFrame.width - initialSize.width) <= 1)
            #expect(abs(model.cardFrame.height - initialSize.height) <= 1)
        }
    }

    // Privacy and Receive are exercised with real taps in HomeBalanceCardUITests;
    // UIKit's in-process accessibility tree omits these custom-layout descendants.

    private func makeHost(
        width: CGFloat,
        environment: BalanceCardTestEnvironment,
        model: BalanceCardTestModel,
        measurements: BalanceCardTextMeasurements
    ) throws -> NativeListTestHost {
        try NativeListTestHost(layout: width > 393 ? .pad : .phone) {
            BalanceCardMeasurementHarness(
                width: width, environment: environment, model: model, measurements: measurements
            )
        }
    }
}

private struct BalanceCardMeasurementHarness: View {
    let width: CGFloat
    let environment: BalanceCardTestEnvironment
    let model: BalanceCardTestModel
    let measurements: BalanceCardTextMeasurements

    var body: some View {
        VStack(spacing: 0) {
            WalletHomeBalanceCard(
                usdValue: model.amount,
                currencyContext: WalletCurrencyContext(code: "IRR", ratePerUSD: 1),
                isHidden: model.isHidden,
                onTogglePrivacy: {
                    model.privacyToggleCount += 1
                    model.isHidden.toggle()
                },
                onReceive: { model.receiveCount += 1 }
            )
            .textRenderer(BalanceCardMeasurementRenderer(measurements: measurements))
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("balance-card-test-container"))
            } action: { model.cardFrame = $0 }
            .padding(.horizontal, 20)
        }
        .frame(width: width)
        .coordinateSpace(name: "balance-card-test-container")
        .environment(\.layoutDirection, environment.direction)
        .environment(\.dynamicTypeSize, environment.textSize)
        .environment(\.locale, Locale(identifier: environment.direction == .rightToLeft ? "ar" : "en"))
    }
}

enum BalanceCardTestEnvironment: CaseIterable, Sendable {
    case regular, regularRTL, accessibilityRTL

    var direction: LayoutDirection { self == .regular ? .leftToRight : .rightToLeft }
    var textSize: DynamicTypeSize { self == .accessibilityRTL ? .accessibility3 : .large }
}

@MainActor
@Observable
private final class BalanceCardTestModel {
    var amount: Decimal = 1
    var isHidden = false
    var privacyToggleCount = 0
    var receiveCount = 0
    var cardFrame: CGRect = .zero
}

private struct BalanceCardTextMeasurement: Sendable {
    let width: CGFloat
    let isTruncated: Bool
}

private final class BalanceCardTextMeasurements: Sendable {
    private let values = OSAllocatedUnfairLock<[BalanceCardTextMeasurement]>(initialState: [])
    var snapshot: [BalanceCardTextMeasurement] { values.withLock { $0 } }
    func clear() { values.withLock { $0.removeAll() } }
    func record(_ measurement: BalanceCardTextMeasurement) {
        values.withLock {
            if $0.count == 128 { $0.removeFirst() }
            $0.append(measurement)
        }
    }
}

/// Inspects SwiftUI's rendered text metrics without creating a screenshot.
private struct BalanceCardMeasurementRenderer: TextRenderer {
    let measurements: BalanceCardTextMeasurements

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let bounds = layout.reduce(CGRect.null) {
            $0.union($1.typographicBounds.rect.applying(context.transform))
        }
        measurements.record(BalanceCardTextMeasurement(width: bounds.width, isTruncated: layout.isTruncated))
        for line in layout { context.draw(line) }
    }
}
