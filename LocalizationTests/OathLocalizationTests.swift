import XCTest
import UIKit
import SwiftUI
@testable import OathAtmosphere

final class OathLocalizationTests: XCTestCase {
    @MainActor func testArabicFontsAreRegisteredByIOS() throws {
        for face in OathArabicFont.allCases {
            let font = try XCTUnwrap(UIFont(name: face.rawValue, size: 17))
            XCTAssertEqual(font.fontName, face.rawValue)
            XCTAssertTrue(font.familyName.contains("IBM Plex Sans Arabic"))
            let scaled = face.uiFont(size: 17, relativeTo: .body)
            XCTAssertEqual(scaled.fontName, face.rawValue)
        }
    }

    @MainActor func testCompiledCatalogInAllLanguages() throws {
        let bundle = Bundle(for: OathKeypadView.self)
        for language in OathLanguage.allCases {
            let strings = OathLocalizer(language, bundle: bundle)
            // Looking up a value through OathLocalizer alone could hide a missing
            // translation behind English fallback. Inspect this locale's actual
            // compiled table as well. The host catalog audit checks review states,
            // shared spellings, format arguments and legal links before the build.
            let directory = try XCTUnwrap(bundle.url(forResource: language.rawValue, withExtension: "lproj"))
            let data = try Data(contentsOf: directory.appendingPathComponent("Localizable.strings"))
            let compiled = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            for key in OathStringKey.allCases {
                XCTAssertNotEqual(strings.text(key), key.rawValue)
                XCTAssertFalse(strings.text(key).isEmpty)
                XCTAssertEqual(compiled[key.rawValue], strings.text(key), "Missing direct compiled translation: \(language.rawValue)/\(key.rawValue)")
            }
            XCTAssertEqual(language.isRightToLeft, ["ar", "fa", "he", "sd", "ur"].contains(language.rawValue))
        }
        XCTAssertEqual(OathLocalizer(.arabic, bundle: bundle).text(.createWallet), "إنشاء محفظة جديدة")
    }
}

/// The override getter traps when the trait is absent, including on the fresh
/// window used during scene startup. Exercise the production helper directly.
final class OathLayoutDirectionTests: XCTestCase {
    @MainActor func testFreshViewsAndWindowsAcceptEitherInitialDirection() {
        for language in [OathLanguage.english, .arabic] {
            for view in [UIView(frame: .zero), UIWindow(frame: .zero)] {
                XCTAssertFalse(view.traitOverrides.contains(UITraitLayoutDirection.self))
                OathLayoutDirection.apply(language, to: view)
                assertDirection(language, on: view)
            }
        }
    }

    @MainActor func testFreshControllerAndItsViewAcceptEitherInitialDirection() {
        for language in [OathLanguage.english, .arabic] {
            let controller = UIViewController()
            XCTAssertFalse(controller.traitOverrides.contains(UITraitLayoutDirection.self))
            XCTAssertFalse(controller.isViewLoaded)
            OathLayoutDirection.apply(language, to: controller)
            XCTAssertTrue(controller.traitOverrides.contains(UITraitLayoutDirection.self))
            XCTAssertEqual(controller.traitCollection.layoutDirection,
                           language.isRightToLeft ? .rightToLeft : .leftToRight)
            assertDirection(language, on: controller.view)
        }
    }

    @MainActor func testReapplicationLanguageChangesAndRemovedOverrides() {
        let controller = UIViewController()
        for language in OathLanguage.allCases.filter(\.isRightToLeft).flatMap({ [$0, $0, .english, .english] }) {
            OathLayoutDirection.apply(language, to: controller)
            XCTAssertTrue(controller.traitOverrides.contains(UITraitLayoutDirection.self))
            XCTAssertEqual(controller.traitCollection.layoutDirection,
                           language.isRightToLeft ? .rightToLeft : .leftToRight)
            assertDirection(language, on: controller.view)
        }
        controller.traitOverrides.remove(UITraitLayoutDirection.self)
        controller.view.traitOverrides.remove(UITraitLayoutDirection.self)
        OathLayoutDirection.apply(.english, to: controller)
        XCTAssertTrue(controller.traitOverrides.contains(UITraitLayoutDirection.self))
        assertDirection(.english, on: controller.view)
    }

    @MainActor func testMatchingInheritedDirectionStillGetsExplicitOverride() {
        let parent = UIView(frame: .zero)
        let child = UIView(frame: .zero)
        parent.addSubview(child)
        OathLayoutDirection.apply(.arabic, to: parent)
        XCTAssertEqual(child.traitCollection.layoutDirection, .rightToLeft)
        XCTAssertFalse(child.traitOverrides.contains(UITraitLayoutDirection.self))
        OathLayoutDirection.apply(.arabic, to: child)
        OathLayoutDirection.apply(.english, to: parent)
        assertDirection(.arabic, on: child)
    }

    @MainActor private func assertDirection(_ language: OathLanguage, on view: UIView,
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(view.traitOverrides.contains(UITraitLayoutDirection.self), file: file, line: line)
        XCTAssertEqual(view.traitCollection.layoutDirection,
                       language.isRightToLeft ? .rightToLeft : .leftToRight, file: file, line: line)
        XCTAssertEqual(view.semanticContentAttribute,
                       language.isRightToLeft ? .forceRightToLeft : .forceLeftToRight, file: file, line: line)
    }
}

final class OathSurfaceColorTests: XCTestCase {
    @MainActor func testNavigationSurfacesResolveOnBackgroundRenderer() async {
        let colors = [OathSurfaceColors.canvas, OathSurfaceColors.groupedCanvas,
                      OathSurfaceColors.card, OathSurfaceColors.field,
                      OathSurfaceColors.sheet, OathSurfaceColors.sheetCard]
        let expected = colors.flatMap { color in
            [UIUserInterfaceStyle.light, .dark].map { style in
                color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).cgColor.components
            }
        }
        let rendered = await Task.detached {
            dispatchPrecondition(condition: .notOnQueue(.main))
            return colors.flatMap { color in
                [UIUserInterfaceStyle.light, .dark].map { style in
                    color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).cgColor.components
                }
            }
        }.value
        XCTAssertEqual(rendered, expected, "Both appearances must keep the same colors on the renderer")
    }
}

/// Exercises the actual SwiftUI sheet -> UIKit -> UIHostingController boundary
/// on an English device, including changing the app language without dismissal.
final class OathSheetDirectionTests: XCTestCase {
    @MainActor func testPresentedContentTracksEveryRTLLanguage() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let state = SheetDirectionState()
        let host = UIHostingController(rootView: SheetDirectionFixture(state: state))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        state.presented = true
        let rtl = ["ar", "fa", "he", "sd", "ur"]
        // Return to English after each RTL language to catch stale hosting or
        // UIKit direction, rather than only testing an initially Arabic sheet.
        for code in rtl.flatMap({ [$0, "en"] }) {
            let language = try XCTUnwrap(OathLanguage(rawValue: code))
            state.language = language
            for _ in 0..<50 {
                if state.leading?.language == code, state.trailing?.language == code,
                   state.leading?.direction == (language.isRightToLeft ? .rightToLeft : .leftToRight),
                   state.leading?.locale == language.locale.identifier,
                   let leading = state.leading, let trailing = state.trailing,
                   (leading.x > trailing.x) == language.isRightToLeft,
                   state.invariantLeading?.language == code,
                   state.invariantTrailing?.language == code { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let leading = try XCTUnwrap(state.leading)
            let trailing = try XCTUnwrap(state.trailing)
            XCTAssertEqual(leading.language, code)
            XCTAssertEqual(leading.locale, language.locale.identifier)
            XCTAssertEqual(leading.direction, language.isRightToLeft ? .rightToLeft : .leftToRight, code)
            XCTAssertEqual(leading.x > trailing.x, language.isRightToLeft,
                           "\(code): native leading/trailing positions must mirror, leading=\(leading.x), trailing=\(trailing.x)")
            let invariantLeading = try XCTUnwrap(state.invariantLeading)
            let invariantTrailing = try XCTUnwrap(state.invariantTrailing)
            XCTAssertEqual(invariantLeading.direction, .leftToRight)
            XCTAssertLessThan(invariantLeading.x, invariantTrailing.x,
                              "Addresses and recovery words must retain their intentional LTR layout")
            let presented = try XCTUnwrap(host.presentedViewController)
            let navigation = try XCTUnwrap(findNavigation(in: presented))
            XCTAssertEqual(navigation.navigationBar.effectiveUserInterfaceLayoutDirection,
                           language.isRightToLeft ? .rightToLeft : .leftToRight, code)
            let direction: UITraitEnvironmentLayoutDirection = language.isRightToLeft ? .rightToLeft : .leftToRight
            XCTAssertEqual(window.traitCollection.layoutDirection, direction, code)
            XCTAssertEqual(presented.traitCollection.layoutDirection, direction, code)
            for controller in descendants(of: navigation) {
                XCTAssertEqual(controller.traitCollection.layoutDirection, direction, "\(code): \(type(of: controller))")
            }
            XCTAssertEqual(navigation.navigationBar.traitCollection.layoutDirection, direction, code)
            let back = try XCTUnwrap(navigation.topViewController?.navigationItem.leftBarButtonItem)
            try assertBackArrow(back, language: language, in: window)
            if testRun?.failureCount != 0 { return }
        }
    }

    @MainActor func testNativeLanguageSheetTracksDirectionChanges() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        func configuration(_ language: OathLanguage) -> OathLanguageSheetConfiguration {
            .init(strings: OathLocalizer(language), preference: .language(language),
                  onChoose: { _ in }, onBack: {}, onClose: {}, style: .sheet)
        }
        let navigation = OathLanguageSelectionController(configuration: configuration(.english))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        for language in OathLanguage.allCases.filter(\.isRightToLeft).flatMap({ [$0, .english] }) {
            navigation.update(configuration: configuration(language))
            navigation.view.layoutIfNeeded()
            let table = try XCTUnwrap(navigation.topViewController as? UITableViewController)
            let direction: UITraitEnvironmentLayoutDirection = language.isRightToLeft ? .rightToLeft : .leftToRight
            XCTAssertEqual(navigation.traitCollection.layoutDirection, direction)
            XCTAssertEqual(table.traitCollection.layoutDirection, direction)
            XCTAssertEqual(table.tableView.effectiveUserInterfaceLayoutDirection,
                           language.isRightToLeft ? .rightToLeft : .leftToRight)
            let cell = try XCTUnwrap(table.tableView.cellForRow(at: IndexPath(row: 0, section: 0)))
            XCTAssertEqual(cell.traitCollection.layoutDirection, direction)
            XCTAssertEqual(cell.effectiveUserInterfaceLayoutDirection,
                           language.isRightToLeft ? .rightToLeft : .leftToRight)
            let back = try XCTUnwrap(table.navigationItem.leftBarButtonItem)
            try assertBackArrow(back, language: language, in: window)
            if testRun?.failureCount != 0 { return }
        }
    }

    /// Measure the rendered glyph, not just which side holds its button. The
    /// original extra image flip passed layout tests but pointed the wrong way.
    @MainActor private func assertBackArrow(_ item: UIBarButtonItem, language: OathLanguage,
                                           in window: UIWindow, file: StaticString = #filePath,
                                           line: UInt = #line) throws {
        let image = try XCTUnwrap(item.image, file: file, line: line)
        let glyph = UIImageView(image: image)
        glyph.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        glyph.contentMode = .center
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)
        glyph.tintColor = .black
        OathLayoutDirection.apply(language, to: glyph)
        window.addSubview(glyph)
        defer { glyph.removeFromSuperview() }
        glyph.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: glyph.bounds.size, format: format).image { context in
            glyph.layer.render(in: context.cgContext)
        }
        let cgImage = try XCTUnwrap(rendered.cgImage, file: file, line: line)
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), file: file, line: line)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let points = (0..<64).flatMap { y in
            (0..<64).compactMap { x in pixels[(y * 64 + x) * 4 + 3] > 127 ? CGPoint(x: x, y: y) : nil }
        }
        let top = try XCTUnwrap(points.map(\.y).min(), file: file, line: line)
        let bottom = try XCTUnwrap(points.map(\.y).max(), file: file, line: line)
        let mid = (top + bottom) / 2
        let center = points.filter { abs($0.y - mid) <= (bottom - top) * 0.1 }
        let arm = points.filter { $0.y <= top + (bottom - top) * 0.2 }
        let centerX = center.reduce(0) { $0 + $1.x } / CGFloat(center.count)
        let armX = arm.reduce(0) { $0 + $1.x } / CGFloat(arm.count)
        XCTAssertEqual(centerX > armX, language.isRightToLeft,
                       "\(language.rawValue): back glyph must point toward the leading edge", file: file, line: line)
    }

    @MainActor private func descendants(of controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap { descendants(of: $0) }
    }

    @MainActor private func findNavigation(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.compactMap { findNavigation(in: $0) }.first
    }
}

@MainActor @Observable private final class SheetDirectionState {
    var language = OathLanguage.english
    var presented = false
    var leading: SheetDirectionSample?
    var trailing: SheetDirectionSample?
    var invariantLeading: SheetDirectionSample?
    var invariantTrailing: SheetDirectionSample?
}

private struct SheetDirectionSample: Equatable {
    let language: String
    let locale: String
    let direction: LayoutDirection
    let x: CGFloat
}

private struct SheetDirectionFixture: View {
    @Bindable var state: SheetDirectionState
    var body: some View {
        Color.clear
            .sheet(isPresented: $state.presented) {
                SheetDirectionContent(state: state).oathLanguage(state.language)
            }
            .oathLanguage(state.language)
            .background {
                OathSceneAppearance(appearance: .system, language: state.language).frame(width: 0, height: 0)
            }
    }
}

private struct SheetDirectionContent: View {
    let state: SheetDirectionState
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathContentSizedSheet(contentID: "direction", navigation: .init(
            strings: strings, title: .walletSettings, backIdentifier: "test.back",
            onBack: {}, onClose: {}
        )) {
            VStack {
                HStack {
                    SheetDirectionProbe(title: "Leading", onSample: { state.leading = $0 })
                    Spacer()
                    SheetDirectionProbe(title: "Trailing", onSample: { state.trailing = $0 })
                }
                HStack {
                    SheetDirectionProbe(title: "Address", onSample: { state.invariantLeading = $0 })
                    Spacer()
                    SheetDirectionProbe(title: "Suffix", onSample: { state.invariantTrailing = $0 })
                }
                .environment(\.layoutDirection, .leftToRight)
            }
            .padding(20)
        }
    }
}

private struct SheetDirectionProbe: View {
    let title: String
    let onSample: (SheetDirectionSample) -> Void
    @Environment(\.oathLanguage) private var language
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var direction
    var body: some View {
        let languageCode = language.rawValue
        let localeIdentifier = locale.identifier
        let direction = direction
        Text(title).onGeometryChange(for: SheetDirectionSample.self, of: {
            SheetDirectionSample(language: languageCode, locale: localeIdentifier,
                                 direction: direction, x: $0.frame(in: .global).midX)
        }, action: onSample)
    }
}
