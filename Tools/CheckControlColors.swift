import AppKit
import SwiftUI

// Host-only UIKit/localization bridges. The controls and settings rows below
// compile from production sources; no simulator or device is launched.
@MainActor enum OathSurfaceColors { static let field = NSColor.controlBackgroundColor }
enum OathOnboardingColors { static let blue = Color(red: 0.12, green: 0.30, blue: 0.90) }
extension NSColor {
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var separator: NSColor { .separatorColor }
}
extension Color { init(uiColor: NSColor) { self.init(nsColor: uiColor) } }
enum OathStringKey: String { case close, done, paste, clear, createWallet, importWallet, importPrivateKey, restoreICloud }
struct OathLocalizer { func text(_ key: OathStringKey) -> String { key.rawValue } }
private struct LocalizerKey: EnvironmentKey { static let defaultValue = OathLocalizer() }
extension EnvironmentValues {
    var oathLocalizer: OathLocalizer {
        get { self[LocalizerKey.self] }
        set { self[LocalizerKey.self] = newValue }
    }
}
extension View {
    func oathFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        font(.system(style).weight(weight))
    }
}
struct OathNetworkLogo: View {
    let asset: String
    let size: CGFloat
    var body: some View { Color.clear.frame(width: size, height: size) }
}

@main struct CheckControlColors {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        func pixels<V: View>(_ content: V, tint: Color, dark: Bool) -> (colored: Int, blue: Int, painted: Int) {
            let renderer = ImageRenderer(content: content
                // NavigationLink/Button styles can introduce both a foreground
                // style and a tint. Exercise hostile inherited accents too.
                .foregroundStyle(tint).tint(tint)
                .padding(8).frame(width: 360)
                .background(dark ? Color.black : Color.white)
                .environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 2
            guard let image = renderer.cgImage else { preconditionFailure("Control did not render") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            var colored = 0, blue = 0, painted = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                    if max(r, g, b) - min(r, g, b) > 0.12 {
                        colored += 1
                        // Antialiasing blends the same blue hue toward the
                        // canvas; do not mistake low-coverage edges for a leak.
                        if b > r + 0.02 && b > g + 0.02 { blue += 1 }
                    }
                    if dark ? max(r, g, b) > 0.3 : min(r, g, b) < 0.7 { painted += 1 }
                }
            }
            return (colored, blue, painted)
        }

        for dark in [false, true] {
            for tint in [Color.blue, Color.red, Color.green] {
                let neutral = pixels(OathSettingsRow(title: "Networks", icon: "globe", value: "Any",
                    subtitle: "Choose networks"), tint: tint, dark: dark)
                check(neutral.painted > 100, "Neutral row must remain visible")
                check(neutral.colored == 0, "Row title, icon, subtitle, value or chevron inherited an accent")

                for accessory in [OathSettingsRow.Accessory.selection(true), .none] {
                    let selected = pixels(OathSettingsRow(title: "Ethereum", isSelected: true,
                        accessory: accessory), tint: tint, dark: dark)
                    check(selected.blue > 20, "Selection check must remain blue")
                    check(selected.colored == selected.blue, "Selection inherited a non-blue accent")
                }

                let close = pixels(OathCloseButton {}.buttonStyle(.plain), tint: tint, dark: dark)
                check(close.painted > 20, "Close symbol must remain visible")
                check(close.colored == 0, "Close symbol inherited an accent")

                let action = pixels(Button("Filter", systemImage: "line.3.horizontal.decrease") {}
                    .oathNeutralControl(), tint: tint, dark: dark)
                check(action.painted > 20, "Neutral toolbar control must remain visible")
                check(action.colored == 0, "Neutral control inherited an accent")
            }

            // Native glass is composited by iOS, so a Mac ImageRenderer cannot
            // verify its fill. Exercise the actual interaction modifier with
            // the production row style that reads the same isEnabled value.
            let reset = Button {} label: {
                OathSettingsRow(title: "Reset App", icon: "trash", color: .red)
            }.buttonStyle(OathSettingsRowButtonStyle())
            let export = Button {} label: {
                OathSettingsRow(title: "View recovery phrase", icon: "key")
            }.buttonStyle(OathSettingsRowButtonStyle())
            let ready = pixels(reset.environment(\.scenePhase, .active), tint: .blue, dark: dark)
            let exportReady = pixels(export.environment(\.scenePhase, .active), tint: .blue, dark: dark)
            check(ready.colored > 20, "The destructive row must remain red")
            check(exportReady.painted > 100, "The export row must remain visible")
            for phase in [ScenePhase.active, .inactive, .background] {
                for pending in [false, true] {
                    let transitioning = pixels(reset.oathInteractionBlocked(pending)
                        .environment(\.scenePhase, phase), tint: .blue, dark: dark)
                    check(transitioning == ready, "Authentication suspension must not gray out the reset row")
                    let exportPixels = pixels(export.oathInteractionBlocked(pending)
                        .environment(\.scenePhase, phase), tint: .blue, dark: dark)
                    check(exportPixels == exportReady, "Authentication suspension must preserve export colors")
                    let unavailable = pixels(reset.oathInteractionBlocked(pending).disabled(true)
                        .environment(\.scenePhase, phase), tint: .blue, dark: dark)
                    check(unavailable != ready, "Real unavailable states must still look disabled")
                }
            }
        }
        print("Passed \(checks) production control color checks on the Mac host (not an iOS visual check)")
    }
}
