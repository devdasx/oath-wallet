import Foundation

@main struct CheckRefreshCompletion {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        func sample(_ policy: inout RefreshCompletion, _ time: Double,
                    tracking: Bool = false, dragging: Bool = false,
                    decelerating: Bool = false, model: Double = -62,
                    presented: Double = -62) -> Bool {
            policy.canFinish(at: time, tracking: tracking, dragging: dragging,
                             decelerating: decelerating, modelOffset: model,
                             presentedOffset: presented)
        }

        // A local refresh completes in milliseconds while the user holds a pull.
        var fast = RefreshCompletion(startedAt: 0)
        for tick in 1...180 {
            expect(!sample(&fast, Double(tick) / 60, tracking: true, dragging: true,
                           model: -250, presented: -250), "Never dismiss under a held finger")
        }
        for tick in 181...195 {
            let position = -250 + Double(tick - 180) * 8
            expect(!sample(&fast, Double(tick) / 60, decelerating: true,
                           model: position, presented: position), "Never interrupt the native rebound")
        }
        expect(!sample(&fast, 3.3), "Observe the new resting offset")
        expect(!sample(&fast, 3.32), "One stationary frame is insufficient")
        expect(sample(&fast, 3.34), "Complete promptly when the native scroll settles")

        // Very fast work without a drag must still produce perceptible feedback.
        var immediate = RefreshCompletion(startedAt: 5)
        for tick in 0...23 {
            expect(!sample(&immediate, 5 + Double(tick) / 60), "No one-frame spinner flash")
        }
        expect(sample(&immediate, 5.41), "The visibility floor must not hold longer than necessary")

        // Finishing a long request adds no artificial minimum after the work.
        var slow = RefreshCompletion(startedAt: 0)
        _ = sample(&slow, 10)
        _ = sample(&slow, 10.02)
        expect(sample(&slow, 10.04), "Long requests finish after only the settling check")

        // Layer animations can continue after UIScrollView reports not dragging.
        var animation = RefreshCompletion(startedAt: 0)
        for tick in 0...20 {
            expect(!sample(&animation, 1 + Double(tick) / 60, model: -122,
                           presented: -180 + Double(tick)), "Do not interrupt a presentation-layer animation")
        }
        _ = sample(&animation, 2, model: -122, presented: -122)
        _ = sample(&animation, 2.02, model: -122, presented: -122)
        expect(!sample(&animation, 2.04, tracking: true, model: -122, presented: -122),
               "A new touch resets settling even before its pan begins")
        expect(!sample(&animation, 2.06, model: -122, presented: -122), "Recheck after interruption")
        expect(sample(&animation, 2.08, model: -122, presented: -122), "Recover after the interruption")

        var confirmation = RefreshCompletion(startedAt: 20, minimumDuration: 0.65)
        _ = sample(&confirmation, 20)
        _ = sample(&confirmation, 20.02)
        expect(!sample(&confirmation, 20.4), "The checkmark keeps its own legible presentation interval")
        expect(!sample(&confirmation, 20.64), "Do not truncate the blur replacement")
        expect(sample(&confirmation, 20.66), "The result can collapse once its presentation is complete")
        print("Passed \(checks) refresh lifecycle checks")
    }
}
