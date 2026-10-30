import Foundation

/// All passcode flows use the unlock screen's stack and circular key sizes.
/// Only a wide window or reserved hardware region separates it into two panes.
struct OathPasscodeLayout {
    enum Regions: Equatable {
        case stacked(CGRect)
        case split(introduction: CGRect, keypad: CGRect)
    }

    static let horizontalPadding: CGFloat = 24
    static let verticalPadding: CGFloat = 18
    static let maximumContentWidth: CGFloat = 460

    let regions: Regions
    let keypadSize: CGSize

    init(size: CGSize, preferredKeyDiameter: CGFloat = OathKeypadGeometry.circularDiameter,
         divisions: [CGRect] = [], occlusions: [CGRect] = [], rightToLeft: Bool = false) {
        let size = OathLayoutGeometry.finiteSize(size)
        let bounds = CGRect(origin: .zero, size: size)
        let divisions = divisions.filter { OathLayoutGeometry.isUsable($0) && $0.intersects(bounds) }
        let occlusions = occlusions.filter { OathLayoutGeometry.isUsable($0) && $0.intersects(bounds) }
        let preferredSize = OathKeypadGeometry.circularSize(diameter: preferredKeyDiameter)
        let adaptive = OathOnboardingLayout(size: size, actionHeight: preferredSize.height,
                                            introductionHeight: 240, divisions: divisions,
                                            occlusions: occlusions, rightToLeft: rightToLeft)
        let availableWidth: CGFloat
        if adaptive.arrangement == .stacked && divisions.isEmpty && occlusions.isEmpty {
            regions = .stacked(bounds)
            availableWidth = min(Self.maximumContentWidth, max(0, size.width - Self.horizontalPadding * 2))
        } else {
            regions = .split(introduction: adaptive.introduction, keypad: adaptive.actions)
            availableWidth = adaptive.actions.width
        }
        keypadSize = OathKeypadGeometry.size(fittingWidth: availableWidth, preferredDiameter: preferredKeyDiameter)
    }
}
