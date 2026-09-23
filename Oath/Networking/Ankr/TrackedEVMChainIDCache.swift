import Foundation

actor TrackedEVMChainIDCache {
    static let shared = TrackedEVMChainIDCache()

    private var values: [String: String] = [:]
    private var inFlight: [String: Task<String, Error>] = [:]

    func value(
        for networkID: String,
        loader: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        if let value = values[networkID] {
            return value
        }
        if let task = inFlight[networkID] {
            return try await task.value
        }

        let task = Task { try await loader() }
        inFlight[networkID] = task
        do {
            let value = try await task.value
            values[networkID] = value
            inFlight[networkID] = nil
            return value
        } catch {
            inFlight[networkID] = nil
            throw error
        }
    }
}
