import Foundation

enum StablecoinCheckError: Error, Equatable, Sendable {
    case invalidAddress
    case unsupportedContract
    case invalidBoolean
    case wrongChain
    case invalidEnvelope
    case http(Int)
    case rpc(Int, String)
    case contract(String, String)
}

/// Only a complete ABI bool is evidence. Empty output, revert, null, and any
/// noncanonical integer remain errors, never a successful negative finding.
enum StablecoinBlacklistABI {
    static func boolean(_ value: String) throws -> Bool {
        let hex = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
        guard hex.count == 64, hex.dropLast().allSatisfy({ $0 == "0" }),
              let last = hex.last, last == "0" || last == "1" else {
            throw StablecoinCheckError.invalidBoolean
        }
        return last == "1"
    }

    static func parameter(address: String) throws -> String {
        guard address.hasPrefix("0x"), address.utf8.count == 42,
              address.dropFirst(2).utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }) else { throw StablecoinCheckError.invalidAddress }
        return String(repeating: "0", count: 24) + address.dropFirst(2).lowercased()
    }
}

struct StablecoinBlacklistClient: Sendable {
    let session: URLSession

    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: config)
    }

    func check(target: StablecoinBlacklistTarget, address: String) async throws -> Bool {
        guard let method = target.method else { throw StablecoinCheckError.unsupportedContract }
        if target.networkID == "tron" {
            return try await SendTronAPIClient(session: session)
                .stablecoinBlacklist(contract: target.contract, address: address, method: method)
        }
        let parameter = try StablecoinBlacklistABI.parameter(address: address)
        var lastError: any Error = StablecoinCheckError.invalidEnvelope
        for candidate in [target.endpoint] + target.fallbackEndpoints {
            try Task.checkCancellation()
            do {
                return try await checkEVM(target: target, method: method, parameter: parameter, endpoint: candidate)
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        throw lastError
    }

    private func checkEVM(target: StablecoinBlacklistTarget, method: StablecoinBlacklistTarget.Method,
                          parameter: String, endpoint endpointString: String) async throws -> Bool {
        // Validate the very same endpoint used for eth_call, so a fallback on
        // another chain cannot yield a valid-looking false result.
        guard let endpoint = URL(string: endpointString) else { throw StablecoinCheckError.invalidEnvelope }
        let chain = try await request(endpoint, id: 1, method: "eth_chainId", params: [])
        guard chain.hasPrefix("0x"), UInt64(chain.dropFirst(2), radix: 16) == target.chainID else {
            throw StablecoinCheckError.wrongChain
        }
        let result = try await request(endpoint, id: 2, method: "eth_call", params: [
            AnyEncodable(["to": target.contract, "data": "0x" + method.selector + parameter]),
            AnyEncodable("latest")
        ])
        guard result.hasPrefix("0x") else { throw StablecoinCheckError.invalidBoolean }
        return try StablecoinBlacklistABI.boolean(result)
    }

    private func request(_ endpoint: URL, id: Int, method: String, params: [AnyEncodable]) async throws -> String {
        struct Request: Encodable {
            let jsonrpc = "2.0"
            let id: Int
            let method: String
            let params: [AnyEncodable]
        }
        struct Response: Decodable {
            struct RPCError: Decodable { let code: Int; let message: String }
            let jsonrpc: String
            let id: Int
            let result: String?
            let error: RPCError?
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(id: id, method: method, params: params))
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw StablecoinCheckError.invalidEnvelope }
        guard (200..<300).contains(http.statusCode) else { throw StablecoinCheckError.http(http.statusCode) }
        let envelope = try JSONDecoder().decode(Response.self, from: data)
        guard envelope.jsonrpc == "2.0", envelope.id == id else { throw StablecoinCheckError.invalidEnvelope }
        if let error = envelope.error {
            throw StablecoinCheckError.rpc(error.code, SendTransactionSubmissionError.sanitizedMessage(error.message))
        }
        guard let result = envelope.result else { throw StablecoinCheckError.invalidEnvelope }
        return result
    }
}
