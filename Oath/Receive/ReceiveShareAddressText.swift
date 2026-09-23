import CoreText
import SwiftUI
import UIKit

/// Core Text also keeps exported address artwork free of inserted hyphens.
/// ImageRenderer cannot render the UIKit-backed selectable on-screen control.
struct ReceiveShareAddressText: View {
    let address: String
    let width: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let color = UIColor.label.resolvedColor(with: UITraitCollection(
            userInterfaceStyle: colorScheme == .dark ? .dark : .light
        ))
        let layout = Self.layout(address: address, width: width, color: color)
        Canvas { context, size in
            context.withCGContext { cg in
                cg.textMatrix = .identity
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                CTFrameDraw(layout.frame, cg)
            }
        }
        .frame(width: width, height: layout.height)
        .accessibilityLabel(Text(verbatim: address))
    }

    struct Layout {
        let frame: CTFrame
        let height: CGFloat
        let attributedText: NSAttributedString
    }

    static func layout(address: String, width: CGFloat, color: UIColor = .label) -> Layout {
        var pointSize: CGFloat = 27
        while true {
            let font = UIFont.monospacedSystemFont(ofSize: pointSize, weight: .medium)
            let text = WalletExactText.attributedText(
                address, font: font, alignment: .center, foregroundColor: color
            )
            let setter = CTFramesetterCreateWithAttributedString(text)
            let measured = CTFramesetterSuggestFrameSizeWithConstraints(
                setter, CFRange(location: 0, length: 0), nil,
                CGSize(width: width, height: .greatestFiniteMagnitude), nil
            )
            // Keep the existing export's two-line size and minimum font scale.
            // Only layout changes: QR payloads and source addresses stay exact.
            if measured.height <= font.lineHeight * 2 + 1 || pointSize <= 27 * 0.54 {
                let height = ceil(measured.height) + 1
                let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
                return Layout(frame: frame, height: height, attributedText: text)
            }
            pointSize = max(27 * 0.54, pointSize - 0.5)
        }
    }
}
