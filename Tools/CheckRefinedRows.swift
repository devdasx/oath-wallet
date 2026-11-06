import AppKit
import SwiftUI
import Vision

// python3 Tools/CheckRefinedRows.py

// Host-only UIKit/font bridges; the row layout and amount formatter below are
// production sources. This checks sizing, not the iOS glass renderer or font.
@MainActor enum OathSurfaceColors {
    static let field = NSColor.controlBackgroundColor
    static let networkBadge = NSColor.controlBackgroundColor
}
extension NSColor { static var separator: NSColor { .separatorColor } }
extension Color { init(uiColor: NSColor) { self.init(nsColor: uiColor) } }
extension View {
    func oathFont(_ style: Font.TextStyle, weight: Font.Weight = .regular,
                  size: CGFloat? = nil, alreadyScaled: Bool = false) -> some View {
        font(size.map { .system(size: $0, weight: weight) } ?? .system(style).weight(weight))
    }
}
struct OathNetworkLogo: View {
    let asset: String
    let size: CGFloat
    var body: some View { Color.blue.frame(width: size, height: size) }
}
enum RowStringKey { case balanceHidden }
struct RowLocalizer: Sendable {
    func text(_ key: RowStringKey) -> String { "Balance hidden" }
}
private struct RowLocalizerKey: EnvironmentKey { static let defaultValue = RowLocalizer() }
extension EnvironmentValues {
    var oathLocalizer: RowLocalizer { self[RowLocalizerKey.self] }
}

@main struct CheckRefinedRows {
    @MainActor static func main() throws {
        let format = OathAssetAmountFormat(locale: Locale(identifier: "en_US"))
        var checks = 0
        for width: CGFloat in [320, 393, 440] {
            for rtl in [false, true] {
                for title in ["Bitcoin", "NEAR Protocol", "A very long token name that needs truncation"] {
                    for balance in ["0", "0.578460528618856998992951", "1234567890.123456789012345678", "0.000000000000000000000001"] {
                        let native = format.nativeSummary(Decimal(string: balance)!, ticker: "NEAR")
                        let row = OathRefinedListRow(title: title, subtitle: native, value: "$3.28") { size in
                            Color.blue.frame(width: size, height: size)
                        }
                        .frame(width: width)
                        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                        let renderer = ImageRenderer(content: row)
                        renderer.scale = 2
                        guard let image = renderer.cgImage else { preconditionFailure("Row failed to render") }
                        precondition(image.width == Int(width * 2), "Row overflows the viewport")
                        precondition(image.height == 156, "Long native balances must not add extra rows")
                        checks += 2
                    }
                }
            }
        }
        // Rendering the real row catches zero-width fiat labels that a formatter
        // or viewport-size assertion cannot detect. Artwork/font bridges only
        // differ from iOS; production row layout and formatting are unchanged.
        for width: CGFloat in [320, 393, 440] {
            for scheme: ColorScheme in [.light, .dark] {
                for rtl in [false, true] {
                    for title in ["Sent USDT", "Self transfer BTC", "Bridge USDT → USDe"] {
                        let richTitle: AnyView? = title.hasPrefix("Bridge") ? AnyView(
                            HStack(spacing: 4) {
                                Text("Bridge")
                                OathNetworkLogo(asset: "bnb", size: 14).fixedSize()
                                Text("USDT")
                                Image(systemName: "arrow.forward").imageScale(.small)
                                OathNetworkLogo(asset: "robinhood", size: 14).fixedSize()
                                Text("USDe")
                            }
                        ) : nil
                        let row = OathRefinedListRow(
                            title: title, subtitle: "12:48 AM", value: "+$98.80",
                            detail: "+98.86468926 USDe", customTitle: richTitle
                        ) { size in Color.blue.frame(width: size, height: size) }
                        .frame(width: width)
                        .background(scheme == .dark ? Color.black : Color.white)
                        .environment(\.colorScheme, scheme)
                        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                        let renderer = ImageRenderer(content: row)
                        renderer.scale = 3
                        guard let image = renderer.cgImage else { preconditionFailure("History row failed to render") }
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.usesLanguageCorrection = false
                        try VNImageRequestHandler(cgImage: image).perform([request])
                        let visibleText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                        guard visibleText.contains("98.80") else {
                            throw NSError(domain: "HistoryRowLayout", code: 1, userInfo: [NSLocalizedDescriptionKey:
                                "Fiat amount missing at width \(width), \(scheme), RTL=\(rtl), \(title): \(visibleText)"])
                        }
                        checks += 1
                    }
                }
            }
        }
        for width: CGFloat in [320, 393, 440] {
            for rtl in [false, true] {
                for price in ["$0.62", "Price Untracked", "Preis wird nicht erfasst"] {
                    let subtitle = AnyView(Label(price, systemImage: "exclamationmark.circle"))
                    let row = OathRefinedListRow(title: "THORChain", subtitle: price, value: "$84.11",
                        primaryFontWeight: .medium, detail: "136.18908816 RUNE",
                        emphasizesBalanceSubtitle: true, customSubtitle: subtitle, emphasizesBalanceDetail: true
                    ) { size in Color.blue.frame(width: size, height: size) }
                    .frame(width: width).background(.white)
                    .environment(\.colorScheme, .light)
                    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                    let renderer = ImageRenderer(content: row)
                    renderer.scale = 3
                    guard let image = renderer.cgImage else { preconditionFailure("Asset price row failed to render") }
                    precondition(image.width == Int(width * 3), "Asset price row overflows viewport")
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    precondition(text.contains("84.11") && text.contains("136.18908816") && text.contains("RUNE"),
                        "Asset balances disappear or truncate: width=\(width), RTL=\(rtl), price=\(price): \(text)")
                    if price == "Price Untracked" { precondition(text.contains(price), "Untracked action must remain readable") }
                    checks += 1
                }
            }
        }
        print("Passed \(checks) production row sizing and visible amount/price checks (host fonts; no simulator)")
    }
}
