import Foundation

extension DiagnosticHTTP {
    /// A nil body means that the actual delivered bytes exceeded the caller's
    /// limit. Never return a truncated body to a decoder or signature checker.
    public static func readBody(_ bytes: URLSession.AsyncBytes, maximumBytes: Int) async throws -> Data? {
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                guard maximumBytes >= 0 else { bytes.task.cancel(); return nil }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < maximumBytes else {
                        bytes.task.cancel()
                        try Task.checkCancellation()
                        return nil
                    }
                    data.append(byte)
                }
                try Task.checkCancellation()
                return data
            } catch {
                bytes.task.cancel()
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            bytes.task.cancel()
        }
    }

    public static func boundedData(for request: URLRequest, session: URLSession, maximumBytes: Int,
                                   file: String = #fileID, function: String = #function,
                                   line: UInt = #line) async throws -> (Data?, URLResponse) {
        do {
            let (bytes, head) = try await session.bytes(for: request)
            let body = try await readBody(bytes, maximumBytes: maximumBytes)
            if let http = head as? HTTPURLResponse {
                // An oversized body cannot be inspected. Preserve the HTTP
                // status without passing incomplete bytes to envelope decoding.
                response(body ?? Data(), status: http.statusCode, request: request,
                         file: file, function: function, line: line)
            }
            return (body, head)
        } catch {
            OathDiagnostics.record(error, component: "network", context: context(request),
                                   file: file, function: function, line: line)
            throw error
        }
    }
}
