import SwiftUI

public struct LiquidGlassBubbleMotion: Sendable, Equatable {
    public let followResponse: Double
    public let followDampingFraction: Double
    public let returnResponse: Double
    public let returnDampingFraction: Double
    public let pressedScale: CGFloat

    public init(
        followResponse: Double,
        followDampingFraction: Double,
        returnResponse: Double,
        returnDampingFraction: Double,
        pressedScale: CGFloat
    ) {
        self.followResponse = max(0.01, followResponse)
        self.followDampingFraction = min(
            1,
            max(0.01, followDampingFraction)
        )
        self.returnResponse = max(0.01, returnResponse)
        self.returnDampingFraction = min(
            1,
            max(0.01, returnDampingFraction)
        )
        self.pressedScale = min(1, max(0.8, pressedScale))
    }

    public static let resistant = LiquidGlassBubbleMotion(
        followResponse: 0.34,
        followDampingFraction: 0.82,
        returnResponse: 0.62,
        returnDampingFraction: 0.70,
        pressedScale: 0.965
    )
}

public enum LiquidGlassBubbleSurfaceStyle: Sendable, Equatable {
    case clearGlass
    case contentOnly
}

public enum LiquidGlassBubblePhysics {
    static func physicalDragTranslation(
        _ translation: CGSize,
        layoutDirection: LayoutDirection
    ) -> CGSize {
        CGSize(
            width: layoutDirection == .rightToLeft
                ? -translation.width
                : translation.width,
            height: translation.height
        )
    }

    public static func constrainedOffset(
        proposedOffset: CGSize,
        restingCenter: CGPoint,
        movementBounds: CGRect,
        diameter: CGFloat,
        edgePadding: CGFloat
    ) -> CGSize {
        guard !movementBounds.isNull,
              !movementBounds.isInfinite,
              movementBounds.width > 0,
              movementBounds.height > 0 else {
            return .zero
        }

        let radius = max(0, diameter) / 2
        let inset = radius + max(0, edgePadding)
        let proposedCenter = CGPoint(
            x: restingCenter.x + proposedOffset.width,
            y: restingCenter.y + proposedOffset.height
        )
        let center = CGPoint(
            x: constrainedCoordinate(
                proposedCenter.x,
                minimum: movementBounds.minX + inset,
                maximum: movementBounds.maxX - inset,
                fallback: movementBounds.midX
            ),
            y: constrainedCoordinate(
                proposedCenter.y,
                minimum: movementBounds.minY + inset,
                maximum: movementBounds.maxY - inset,
                fallback: movementBounds.midY
            )
        )

        return CGSize(
            width: center.x - restingCenter.x,
            height: center.y - restingCenter.y
        )
    }

    private static func constrainedCoordinate(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        fallback: CGFloat
    ) -> CGFloat {
        guard minimum <= maximum else { return fallback }
        return min(maximum, max(minimum, value))
    }
}

public struct LiquidGlassBubble<Content: View>: View {
    private let diameter: CGFloat
    private let restingCenter: CGPoint
    private let movementBounds: CGRect
    private let edgePadding: CGFloat
    private let motion: LiquidGlassBubbleMotion
    private let surfaceStyle: LiquidGlassBubbleSurfaceStyle
    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var offset: CGSize = .zero
    @State private var dragOrigin: CGSize?
    @State private var isDragging = false

    public init(
        diameter: CGFloat,
        restingCenter: CGPoint,
        movementBounds: CGRect,
        edgePadding: CGFloat = 8,
        motion: LiquidGlassBubbleMotion = .resistant,
        surfaceStyle: LiquidGlassBubbleSurfaceStyle = .clearGlass,
        @ViewBuilder content: () -> Content
    ) {
        self.diameter = max(1, diameter)
        self.restingCenter = restingCenter
        self.movementBounds = movementBounds
        self.edgePadding = max(0, edgePadding)
        self.motion = motion
        self.surfaceStyle = surfaceStyle
        self.content = content()
    }

    public var body: some View {
        nativeGlassSurface
            .contentShape(Circle())
            .gesture(dragGesture)
            .scaleEffect(isDragging ? motion.pressedScale : 1)
            .position(
                x: restingCenter.x + offset.width,
                y: restingCenter.y + offset.height
            )
    }

    @ViewBuilder
    private var nativeGlassSurface: some View {
        let surface = ZStack {
            Color.clear

            content
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
        }
        .frame(width: diameter, height: diameter)

        switch surfaceStyle {
        case .contentOnly:
            surface
        case .clearGlass:
            if #available(iOS 26.0, macOS 26.0, *) {
                surface.glassEffect(
                    .clear.interactive(),
                    in: Circle()
                )
            } else {
                surface.background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let origin = beginDragIfNeeded()
                let translation =
                    LiquidGlassBubblePhysics.physicalDragTranslation(
                        value.translation,
                        layoutDirection: layoutDirection
                    )
                let proposedOffset = CGSize(
                    width: origin.width + translation.width,
                    height: origin.height + translation.height
                )
                let constrainedOffset =
                    LiquidGlassBubblePhysics.constrainedOffset(
                        proposedOffset: proposedOffset,
                        restingCenter: restingCenter,
                        movementBounds: movementBounds,
                        diameter: diameter,
                        edgePadding: edgePadding
                    )

                updateOffsetDuringDrag(constrainedOffset)
            }
            .onEnded { _ in
                dragOrigin = nil
                returnHome()
            }
    }

    private func beginDragIfNeeded() -> CGSize {
        if let dragOrigin {
            return dragOrigin
        }

        dragOrigin = offset
        if reduceMotion {
            isDragging = true
        } else {
            withAnimation(.easeOut(duration: 0.12)) {
                isDragging = true
            }
        }
        return offset
    }

    private func updateOffsetDuringDrag(_ newOffset: CGSize) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                offset = newOffset
            }
            return
        }

        withAnimation(
            .interactiveSpring(
                response: motion.followResponse,
                dampingFraction: motion.followDampingFraction,
                blendDuration: 0.12
            )
        ) {
            offset = newOffset
        }
    }

    private func returnHome() {
        if reduceMotion {
            offset = .zero
            isDragging = false
            return
        }

        withAnimation(
            .interactiveSpring(
                response: motion.returnResponse,
                dampingFraction: motion.returnDampingFraction,
                blendDuration: 0.18
            )
        ) {
            offset = .zero
            isDragging = false
        }
    }
}
