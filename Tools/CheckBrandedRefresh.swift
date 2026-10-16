import Foundation
import SwiftUI

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

        // Compare the generated path against the SVG's two analytic stroke
        // masks, independently of the path operations used to build it.
        let rect = CGRect(x: 82, y: 222, width: 860, height: 580)
        let mark = OathRefreshMark().path(in: rect)
        expect(abs(mark.boundingRect.width - 860) < 0.1 && abs(mark.boundingRect.height - 580) < 0.1,
               "The original logo viewBox is preserved")
        for y in stride(from: 228.0, to: 798.0, by: 9.0) {
            for x in stride(from: 88.0, to: 938.0, by: 9.0) {
                let left = hypot(x - 372, y - 512), right = hypot(x - 652, y - 512)
                // Exclude only the antialiased boundaries of the original SVG.
                guard [left, right].allSatisfy({ r in [148.0, 170, 290, 312].allSatisfy { abs(r - $0) > 0.5 } }),
                      abs(y - 512) > 0.5 else { continue }
                let a = (170...290).contains(left) && !(y >= 512 && (148...312).contains(right))
                let b = (170...290).contains(right) && !(y <= 512 && (148...312).contains(left))
                expect(mark.contains(CGPoint(x: x, y: y)) == (a || b),
                       "SVG mismatch at \(x),\(y); radii \(left),\(right); expected \(a || b)")
            }
        }
        print("Passed \(checks) branded refresh lifecycle and SVG geometry checks")
    }
}
