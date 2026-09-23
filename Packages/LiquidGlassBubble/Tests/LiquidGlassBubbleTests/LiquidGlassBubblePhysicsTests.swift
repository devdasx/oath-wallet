import CoreGraphics
import XCTest
@testable import LiquidGlassBubble

final class LiquidGlassBubblePhysicsTests: XCTestCase {
    func testLeftToRightDragUsesReportedPhysicalTranslation() {
        let translation = LiquidGlassBubblePhysics.physicalDragTranslation(
            CGSize(width: 48, height: -24),
            layoutDirection: .leftToRight
        )

        XCTAssertEqual(translation.width, 48)
        XCTAssertEqual(translation.height, -24)
    }

    func testRightToLeftDragUnmirrorsHorizontalTranslation() {
        let translation = LiquidGlassBubblePhysics.physicalDragTranslation(
            CGSize(width: -48, height: -24),
            layoutDirection: .rightToLeft
        )

        XCTAssertEqual(translation.width, 48)
        XCTAssertEqual(translation.height, -24)
    }

    func testOffsetWithinBoundsIsUnchanged() {
        let offset = LiquidGlassBubblePhysics.constrainedOffset(
            proposedOffset: CGSize(width: 40, height: 70),
            restingCenter: CGPoint(x: 150, y: 180),
            movementBounds: CGRect(x: 0, y: 0, width: 400, height: 800),
            diameter: 88,
            edgePadding: 8
        )

        XCTAssertEqual(offset.width, 40)
        XCTAssertEqual(offset.height, 70)
    }

    func testBubbleRemainsFullyInsideEveryEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let restingCenter = CGPoint(x: 200, y: 200)

        let topLeading = LiquidGlassBubblePhysics.constrainedOffset(
            proposedOffset: CGSize(width: -1_000, height: -1_000),
            restingCenter: restingCenter,
            movementBounds: bounds,
            diameter: 88,
            edgePadding: 8
        )
        let bottomTrailing = LiquidGlassBubblePhysics.constrainedOffset(
            proposedOffset: CGSize(width: 1_000, height: 1_000),
            restingCenter: restingCenter,
            movementBounds: bounds,
            diameter: 88,
            edgePadding: 8
        )

        XCTAssertEqual(topLeading.width, -148)
        XCTAssertEqual(topLeading.height, -148)
        XCTAssertEqual(bottomTrailing.width, 148)
        XCTAssertEqual(bottomTrailing.height, 548)
    }

    func testUndersizedBoundsUseTheirCenter() {
        let offset = LiquidGlassBubblePhysics.constrainedOffset(
            proposedOffset: CGSize(width: 100, height: 100),
            restingCenter: CGPoint(x: 80, y: 90),
            movementBounds: CGRect(x: 20, y: 30, width: 40, height: 50),
            diameter: 88,
            edgePadding: 8
        )

        XCTAssertEqual(offset.width, -40)
        XCTAssertEqual(offset.height, -35)
    }
}
