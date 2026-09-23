import Foundation

actor AnkrRPCTransport {
    private let endpoint: URL
    private let session: URLSession
    private var requestID = 0

    init(endpoint: URL, session: URLSession? = nil) {
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func call<Parameters, Result>(
        method: String,
        parameters: Parameters
    ) async throws -> Result
    where Parameters: Encodable & Sendable, Result: Decodable & Sendable {
        requestID += 1
        let payload = AnkrRPCRequest(
            id: String(requestID),
            jsonrpc: "2.0",
            method: method,
            params: parameters
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnkrAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AnkrAPIError.httpFailure(
                statusCode: httpResponse.statusCode,
                message: providerMessage(from: data)
            )
        }

        let envelope = try JSONDecoder().decode(
            AnkrRPCResponse<Result>.self,
            from: data
        )
        if let error = envelope.error {
            throw AnkrAPIError.rpcFailure(
                code: error.code,
                message: sanitized(error.message) ?? "empty_provider_message"
            )
        }
        guard let result = envelope.result else {
            throw AnkrAPIError.invalidResponse
        }
        return result
    }

    private func providerMessage(from data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(
            AnkrHTTPErrorResponse.self,
            from: data
        ) else {
            return nil
        }
        if let message = envelope.error?.message {
            return sanitized(message)
        }
        if let code = envelope.error?.code {
            return sanitized(code)
        }
        if let message = envelope.message {
            return sanitized(message)
        }
        return nil
    }

    private func sanitized(_ rawValue: String) -> String? {
        var value = rawValue
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        value = value.replacingOccurrences(
            of: endpoint.absoluteString,
            with: "<endpoint>"
        )
        for component in endpoint.pathComponents where
            component.count >= 32
                && component.unicodeScalars.allSatisfy({
                    CharacterSet.alphanumerics.contains($0)
                }) {
            value = value.replacingOccurrences(
                of: component,
                with: "<credential>"
            )
        }
        return String(value.prefix(500))
    }
}
