import Foundation
import OathDiagnostics

/// Mainnet-only HTTPS RPC. Estimates are coins per 1,000 bytes (virtual bytes
/// for BTC/LTC), never sat/vB. Transaction bytes occur only in POST bodies,
/// never URLs or diagnostic context. Signing keys remain on device.
struct AlchemyUTXOAPI: Sendable {
    private let key: String
    private let session: URLSession
    private let budget: UTXOAPIBudget
    init?(apiKey: String?, session: URLSession = .shared, budget: UTXOAPIBudget = .shared) {
        guard let apiKey, (1...256).contains(apiKey.utf8.count),
              apiKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        key = apiKey
        self.session = session; self.budget = budget
    }

    static func host(_ network: UTXONetwork) -> String { "\(network.rawValue)-mainnet.g.alchemy.com" }
    static func isHost(_ host: String) -> Bool { UTXONetwork.allCases.contains { Self.host($0) == host } }

    private func request(_ network: UTXONetwork, method: String, params: [Any]) throws -> URLRequest {
        let url = URL(string: "https://\(Self.host(network))/v2")!.appendingPathComponent(key)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1,
            "method": method, "params": params])
        return request
    }
    func feeRequest(_ network: UTXONetwork) throws -> URLRequest {
        // BCH estimatefee has no confirmation-target parameter. DOGE does not
        // accept Bitcoin's optional CONSERVATIVE mode; use the common target.
        try request(network, method: network == .bitcoincash ? "estimatefee" : "estimatesmartfee",
                    params: network == .bitcoincash ? [] : [3])
    }
    func broadcastRequest(_ network: UTXONetwork, hex: String) throws -> URLRequest {
        try request(network, method: "sendrawtransaction", params: [hex])
    }
    func lookupRequest(_ network: UTXONetwork, txid: String) throws -> URLRequest {
        try request(network, method: "getrawtransaction", params: [txid, false])
    }
    func feeSource(_ network: UTXONetwork) -> UTXOFeeProvider.Source {
        .init(name: Self.host(network), delay: .zero) {
            let data = try await UTXOAPIProvider.fetch(feeRequest(network), limit: 65_536, session: session, budget: budget)
            return try Self.decodeFee(data, network: network)
        }
    }
    func broadcastSource(_ network: UTXONetwork) -> UTXOBroadcastProvider.Source {
        .init(name: Self.host(network), delay: .zero, submit: { hex in
            let data = try await UTXOAPIProvider.fetch(broadcastRequest(network, hex: hex), limit: 65_536, session: session, budget: budget)
            return try Self.decodeBroadcast(data)
        }, lookup: { txid in
            let data = try await UTXOAPIProvider.fetch(lookupRequest(network, txid: txid),
                limit: 2_100_000, missingRPCCode: -5, session: session, budget: budget)
            return try Self.decodeRaw(data)
        })
    }

    private struct Header: Decodable {
        struct Failure: Decodable { let code: Int; let message: String }
        let id: Int
        let jsonrpc: String?
        let error: Failure?
    }
    private struct Reply<Value: Decodable>: Decodable { let result: Value }
    private static func header(_ data: Data, limit: Int) throws -> Header {
        guard data.count <= limit else { throw UTXOAPIProvider.APIError.invalidResponse }
        let reply = try JSONDecoder().decode(Header.self, from: data)
        guard reply.id == 1, reply.jsonrpc == nil || reply.jsonrpc == "2.0" else {
            throw UTXOAPIProvider.APIError.invalidResponse
        }
        return reply
    }
    private static func check(_ header: Header) throws {
        if let failure = header.error {
            throw NSError(domain: "Oath.Alchemy", code: failure.code,
                userInfo: [NSLocalizedDescriptionKey: DiagnosticPrivacy.text(failure.message, limit: 1024)])
        }
    }
    static func decodeFee(_ data: Data, network: UTXONetwork) throws -> Int64 {
        try check(header(data, limit: 65_536))
        let coins: Decimal
        if network == .bitcoincash {
            coins = try JSONDecoder().decode(Reply<Decimal>.self, from: data).result
        } else {
            struct Estimate: Decodable { let feerate: Decimal?; let blocks: Int; let errors: [String]? }
            let result = try JSONDecoder().decode(Reply<Estimate>.self, from: data).result
            if let errors = result.errors, !errors.isEmpty {
                throw NSError(domain: "Oath.AlchemyFee", code: -1, userInfo: [NSLocalizedDescriptionKey:
                    DiagnosticPrivacy.text(errors.prefix(4).joined(separator: "; "), limit: 1024)])
            }
            guard (1...1008).contains(result.blocks), let rate = result.feerate else {
                throw BitcoinSendError.feeUnavailable
            }
            coins = rate
        }
        var atomic = coins * 100_000_000, rounded = Decimal()
        guard !atomic.isNaN, atomic > 0, atomic <= Decimal(network.sendFeeRates.upperBound) else {
            throw BitcoinSendError.feeUnavailable
        }
        NSDecimalRound(&rounded, &atomic, 0, .up)
        return max(network.sendFeeRates.lowerBound, NSDecimalNumber(decimal: rounded).int64Value)
    }
    static func decodeBroadcast(_ data: Data) throws -> String {
        try check(header(data, limit: 65_536))
        let txid = try JSONDecoder().decode(Reply<String>.self, from: data).result
        guard txid.utf8.count == 64, txid.utf8.allSatisfy(isHex) else { throw UTXOAPIProvider.APIError.invalidResponse }
        return txid.lowercased() // The caller must also match its locally computed txid.
    }
    static func decodeRaw(_ data: Data) throws -> Data? {
        let header = try header(data, limit: 2_100_000)
        // Expected absence while propagation is in progress; not acceptance.
        if header.error?.code == -5 { return nil }
        try check(header)
        let hex = try JSONDecoder().decode(Reply<String>.self, from: data).result
        guard !hex.isEmpty, hex.utf8.count <= 2_000_000, hex.utf8.allSatisfy(isHex),
              let bytes = Data(hex: hex) else { throw UTXOAPIProvider.APIError.invalidResponse }
        return bytes // The caller compares both bytes and txid before accepting.
    }
    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}
