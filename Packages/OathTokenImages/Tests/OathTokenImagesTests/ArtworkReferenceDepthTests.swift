import Foundation
import XCTest
@testable import OathTokenImages

final class ArtworkReferenceDepthTests: XCTestCase {
    // Both documents describe the same drawing. Only the declaration order in
    // defs changes. 30 links use exactly 64 nodes on the longest expanded path.
    private func document(links: Int, leavesFirst: Bool) -> Data {
        let shape = "<g id='g0'><rect width='1' height='1'/></g>"
        var groups = [shape]
        for n in 1...links {
            groups.append("<g id='g\(n)'><use xlink:href='#g\(n-1)'/></g>")
        }
        if !leavesFirst { groups.reverse() }
        let xml = "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' width='4' height='4'><defs>"
            + groups.joined() + "</defs><use xlink:href='#g\(links)'/></svg>"
        return Data(xml.utf8)
    }

    private func expectDepthRejection(leavesFirst: Bool) {
        XCTAssertThrowsError(try ArtworkImage.decode(document(links: 31, leavesFirst: leavesFirst)),
                             "Over-budget SVG must be rejected before rendering") { error in
            XCTAssertEqual((error as? ArtworkDecodeFailure)?.stage, .svgSafety)
        }
    }

    func testSharedLeafFirstCannotBypassDepthBudget() {
        expectDepthRejection(leavesFirst: true)
    }

    func testSharedRootFirstCannotBypassDepthBudget() {
        expectDepthRejection(leavesFirst: false)
    }

    func testShadowedCycleCannotReachRenderer() {
        // At the document root SwiftDraw finds the first matching child.
        // A validator indexing only the last ID sees a harmless rectangle.
        let xml = "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' width='4' height='4'>"
            + "<g id='mark'><use xlink:href='#mark'/></g><rect id='mark' width='1' height='1'/></svg>"
        XCTAssertThrowsError(try ArtworkImage.decode(Data(xml.utf8))) { error in
            XCTAssertEqual((error as? ArtworkDecodeFailure)?.stage, .svgSafety)
        }
    }

    func testSiblingReferencesMayShareOneID() {
        let xml = "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' width='4' height='4'>"
            + "<defs><rect id='mark' width='1' height='1'/></defs>"
            + "<use xlink:href='#mark'/><use xlink:href='#mark' x='2'/></svg>"
        XCTAssertNoThrow(try ArtworkImage.decode(Data(xml.utf8)))
    }

    func testExactlyAtDepthBudgetInBothOrders() {
        for leavesFirst in [false,true] {
            XCTAssertNoThrow(try ArtworkImage.decode(document(links: 30, leavesFirst: leavesFirst)))
        }
    }
}
