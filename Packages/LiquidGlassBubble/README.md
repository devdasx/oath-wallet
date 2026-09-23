# LiquidGlassBubble

`LiquidGlassBubble` is a reusable SwiftUI component for a draggable circular
surface. On iOS 26 it uses Apple's native interactive clear Liquid Glass. The
view follows the finger with a damped spring, remains inside caller-provided
bounds, preserves physical drag direction in both LTR and RTL interfaces, and
returns to its resting center with a separate spring on release.

```swift
import LiquidGlassBubble

LiquidGlassBubble(
    diameter: 88,
    restingCenter: CGPoint(x: 200, y: 180),
    movementBounds: CGRect(x: 0, y: 0, width: 400, height: 700)
) {
    Image("BrandLogo")
        .resizable()
        .scaledToFit()
}
```

Pass any SwiftUI content through the view builder. Use
`LiquidGlassBubbleMotion` when a future screen needs a different amount of
finger-follow resistance or return bounce. Set `surfaceStyle: .contentOnly`
to reuse the same drag physics and circular hit area without rendering a
Liquid Glass surface behind the content.
