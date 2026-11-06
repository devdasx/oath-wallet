import Foundation
import SwiftUI
import AppKit

@main struct CheckBrandedRefresh {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        var cycle = RefreshCycle()
        cycle.pull(distance: 120, isDragging: false)
        expect(cycle.phase == .idle, "A rebound must not trigger work")
        cycle.pull(distance: 24, isDragging: true)
        expect(cycle.phase == .pulling && cycle.progress == 0.25, "The logo fills with the pull distance")
        cycle.pull(distance: 12, isDragging: true)
        expect(cycle.progress == 0.125, "Reversing a pull drains the logo")
        cycle.pull(distance: 0, isDragging: false)
        expect(cycle.phase == .idle, "A cancelled pull clears without a completion symbol")
        cycle.pull(distance: 96, isDragging: true)
        expect(cycle.phase == .pulling && cycle.progress == 1, "A full logo waits for native activation")
        cycle.pull(distance: 200, isDragging: true)
        expect(cycle.phase == .pulling, "Holding a long pull must not start wallet work")
        cycle.pull(distance: 0, isDragging: true)
        expect(cycle.phase == .idle, "Reversing even a full pull can cancel before native activation")
        expect(cycle.begin(), "The native event starts refresh")
        expect(cycle.phase == .refreshing && cycle.progress == 1, "Loading retains the full logo")
        for distance in stride(from: 0.0, through: 300.0, by: 3) {
            cycle.pull(distance: distance, isDragging: true)
            expect(cycle.phase == .refreshing, "Repeated pulls retain the current work")
            expect(!cycle.begin(), "Native and accessibility activations cannot duplicate work")
        }
        cycle.complete(succeeded: true)
        expect(cycle.phase == .succeeded, "Only success reveals the checkmark")
        expect(!cycle.begin(), "The completion transition cannot restart work")
        cycle.returnToRest()
        cycle.pull(distance: 40, isDragging: false)
        expect(cycle.phase == .succeeded, "The check remains during native collapse")
        cycle.pull(distance: 0, isDragging: false)
        expect(cycle.phase == .idle, "Return to rest rearms the next gesture")
        expect(cycle.begin(), "An explicit accessibility refresh can start without a drag")
        cycle.complete(succeeded: false)
        expect(cycle.phase == .failed, "Errors never show a success checkmark")
        cycle.complete(succeeded: true)
        expect(cycle.phase == .failed, "Late completions cannot replace the recorded result")
        cycle.reset()
        expect(cycle.phase == .idle && cycle.progress == 0, "Cancellation clears the indicator")
        cycle.pull(distance: .nan, isDragging: true)
        expect(cycle.phase == .idle, "Invalid geometry is ignored")
        cycle.pull(distance: .infinity, isDragging: true)
        expect(cycle.phase == .idle, "Infinite geometry is ignored")
        cycle.pull(distance: 200, isDragging: true)
        expect(cycle.phase == .pulling, "A fast pull still waits for the native event")

        // Compare the actual SwiftUI outline to the approved shipping PNG,
        // independent of the SVG-to-Swift generator. Ignore antialiased edges.
        let icon = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath:
            "OathApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png")))!
        let rect = CGRect(x: 138, y: 260, width: 748, height: 504.465087890625)
        let mark = OathRefreshMark().path(in: rect)
        expect(abs(mark.boundingRect.width - rect.width) < 0.01, "Approved logo width")
        expect(abs(mark.boundingRect.height - rect.height) < 0.01, "Approved logo height")
        func isWhite(_ x: Int, _ y: Int) -> Bool {
            let color = icon.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            return min(color.redComponent, color.greenComponent, color.blueComponent) > 0.98
        }
        for y in stride(from: 2, to: 1022, by: 6) {
            for x in stride(from: 2, to: 1022, by: 6) {
                let expected = isWhite(x, y)
                guard [-2, 0, 2].allSatisfy({ dx in
                    [-2, 0, 2].allSatisfy { dy in isWhite(x + dx, y + dy) == expected }
                }) else { continue }
                expect(mark.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) == expected,
                       "Approved icon silhouette mismatch at \(x),\(y)")
            }
        }
        expect(OathRefreshMark().path(in: .zero).isEmpty, "Empty layout is safe")
        print("Passed \(checks) branded refresh lifecycle and SVG geometry checks")
    }
}
