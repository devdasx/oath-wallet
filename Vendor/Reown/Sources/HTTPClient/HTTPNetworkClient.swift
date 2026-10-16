import Foundation
import OathDiagnostics

public actor HTTPNetworkClient: HTTPClient {
    private var host: String
    private let session: URLSession

    public init(host: String, session: URLSession = .shared) {
        self.host = host
        self.session = session
    }

    // Decode on the caller's executor. Only the immutable host snapshot and
    // URLSession cross this actor boundary, never a generic non-Sendable value.
    public nonisolated func request<T: Decodable>(_ type: T.Type, at service: HTTPService) async throws -> T {
        try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
            let data = try await response(for: service)
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch {
                OathDiagnostics.record(error, component: "walletconnect_sdk", operation: "http_decode")
                throw error
            }
        }
    }

    public nonisolated func request(service: HTTPService) async throws {
        try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
            _ = try await response(for: service)
        }
    }

    public func updateHost(host: String) async { self.host = host }

    private nonisolated func response(for service: HTTPService) async throws -> Data {
        guard let request = service.resolve(for: await host) else {
            OathDiagnostics.record(DiagnosticFailure("Invalid SDK HTTP service URL"), component: "walletconnect_sdk", operation: "http_request")
            throw HTTPError.malformedURL(service)
        }
        let result: (Data, URLResponse)
        do { result = try await DiagnosticHTTP.data(for: request, session: session) }
        catch {
            // DiagnosticHTTP records the original error before domain conversion.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if (error as NSError).code == -1004 { throw HTTPError.couldNotConnect }
            throw HTTPError.dataTaskError(error)
        }
        guard let response = result.1 as? HTTPURLResponse else {
            OathDiagnostics.record(HTTPError.noResponse, component: "walletconnect_sdk", operation: "http_response")
            throw HTTPError.noResponse
        }
        guard (200..<300).contains(response.statusCode) else { throw HTTPError.badStatusCode(response.statusCode) }
        return result.0
    }
}
