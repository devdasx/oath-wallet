import Foundation

protocol NetworkingServiceProtocol {
    func sendEvents<T: Encodable>(_ events: [T]) async throws -> Bool
}

class NetworkingService: NetworkingServiceProtocol {
    private let session: URLSession
    private let projectId: String
    private let sdkVersion: String
    private let apiURL = URL(string: "https://pulse.walletconnect.com/batch")!

    init(session: URLSession = .shared, projectId: String, sdkVersion: String) {
        self.session = session
        self.projectId = projectId
        self.sdkVersion = sdkVersion
    }

    func sendEvents<T: Encodable>(_ events: [T]) async throws -> Bool {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(projectId, forHTTPHeaderField: "x-project-id")
        request.setValue("events_sdk", forHTTPHeaderField: "x-sdk-type")
        request.setValue(sdkVersion, forHTTPHeaderField: "x-sdk-version")

        request.httpBody = try JSONEncoder().encode(events)

        try Task.checkCancellation()
        // URLSession's async API propagates task cancellation to the request.
        // A request already accepted by the server cannot be recalled.
        let (_, response) = try await session.data(for: request)
        try Task.checkCancellation()
        return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
    }
}

#if DEBUG
class MockNetworkingService: NetworkingServiceProtocol {
    var shouldFail = false
    var attemptCount = 0

    func sendEvents<T>(_ events: [T]) async throws -> Bool where T : Encodable {
        attemptCount += 1
        if shouldFail {
            throw NSError(domain: "MockError", code: -1, userInfo: nil)
        }
        return true
    }
}
#endif
