import Foundation

/// Ordered, bounded structured concurrency. A large recovery must not create
/// thousands of tasks waiting for a socket, and one failure cancels siblings.
enum BitcoinConcurrent {
    static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], limit: Int,
        operation: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var next = 0
            var results = [Output?](repeating: nil, count: inputs.count)
            func submit() {
                let index = next
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    return (index, try await operation(inputs[index]))
                }
            }
            for _ in 0..<min(max(1, limit), inputs.count) { submit() }
            for try await (index, value) in group {
                try Task.checkCancellation()
                results[index] = value
                if next < inputs.count { submit() }
            }
            return results.map { $0! }
        }
    }
}
