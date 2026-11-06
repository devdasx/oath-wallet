import AppKit
import SwiftUI

/// Host rendering of the production branded indicator and the SF symbol
/// families used by the app. Universal marks retain their shape; directional
/// navigation/flow symbols follow RTL, as required by Apple's RTL guidance.
/// Compile with BrandedRefreshIndicator, RefreshIndicatorModel, RefreshCycle
/// and OathRefreshMark from Packages/OathNativeRefresh/Sources/OathNativeRefresh.
@main struct CheckRTLIndicators {
    @MainActor static func main() {
        var checks = 0
        func checkUnchanged<V: View>(_ name: String, @ViewBuilder view: () -> V) {
            let left = render(view(), direction: .leftToRight)
            let right = render(view(), direction: .rightToLeft)
            precondition(difference(left, right, mirror: false) < 0.0001,
                         "\(name) is a universal mark and must not be reflected")
            checks += 1
        }
        func checkMirror<V: View>(_ name: String, @ViewBuilder view: () -> V) {
            let left = render(view(), direction: .leftToRight)
            let right = render(view(), direction: .rightToLeft)
            let mirrored = difference(left, right, mirror: true)
            let unchanged = difference(left, right, mirror: false)
            precondition(unchanged > 0.002, "\(name) must visibly change direction")
            precondition(mirrored < unchanged * 0.15, "\(name) has the wrong handedness: \(mirrored) / \(unchanged)")
            checks += 1
        }
        for acknowledged in [false, true] {
            let model = RefreshIndicatorModel()
            precondition(model.cycle.begin())
            if acknowledged { model.cycle.acknowledge() }
            else { model.cycle.complete(succeeded: true) }
            checkUnchanged(acknowledged ? "Refresh acknowledgement" : "Refresh success") {
                BrandedRefreshIndicator(model: model)
            }
        }
        for symbol in ["checkmark", "checkmark.circle", "checkmark.circle.fill", "checkmark.circle.dotted", "checkmark.shield", "checkmark.icloud"] {
            checkUnchanged(symbol) {
                Image(systemName: symbol).font(.system(size: 44))
            }
        }
        for symbol in ["arrow.forward", "arrow.up.forward", "arrow.down.backward", "arrow.up.forward.square", "chevron.forward"] {
            checkMirror(symbol) { Image(systemName: symbol).font(.system(size: 44)) }
        }
        #if OATH_SETTINGS_FIXTURE
        checkMirror("Settings text alignment") { OathSettingsIcon(symbol: "text.alignleft", color: .black) }
        checkUnchanged("Settings success mark") { OathSettingsIcon(symbol: "checkmark.circle", color: .black) }
        #endif
        print("Passed \(checks) rendered RTL refresh and symbol checks on the host; no simulator.")
    }

    @MainActor private static func render<V: View>(_ view: V, direction: LayoutDirection) -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view
            .foregroundStyle(.white).frame(width: 96, height: 96).background(.black)
            .environment(\.layoutDirection, direction)
            .environment(\.locale, Locale(identifier: direction == .rightToLeft ? "ar" : "en")))
        renderer.scale = 2
        guard let image = renderer.cgImage else { preconditionFailure("Indicator did not render") }
        return NSBitmapImageRep(cgImage: image)
    }

    private static func difference(_ left: NSBitmapImageRep, _ right: NSBitmapImageRep, mirror: Bool) -> Double {
        precondition(left.pixelsWide == right.pixelsWide && left.pixelsHigh == right.pixelsHigh)
        var total = 0.0
        for y in 0..<left.pixelsHigh {
            for x in 0..<left.pixelsWide {
                let lhs = left.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                let rhs = right.colorAt(x: mirror ? right.pixelsWide - x - 1 : x, y: y)!.usingColorSpace(.sRGB)!
                total += abs(lhs.redComponent - rhs.redComponent)
            }
        }
        return total / Double(left.pixelsWide * left.pixelsHigh)
    }
}
