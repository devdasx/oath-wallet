import Foundation

/// ANKR's documented Bitcoin HTTPS RPC. Fee-only: never receives wallet data.
/// Litecoin was retired on 2026-09-15; BCH has no documented endpoint, and the
/// configured Dogecoin access returns 403. Those chains keep their public APIs.
struct AnkrUTXOFeeAPI: Sendable {
    let request: URLRequest

    init?(apiKey: String?) {
        guard let apiKey, !apiKey.isEmpty,
              apiKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        let url = URL(string: "https://rpc.ankr.com/btc")!.appendingPathComponent(apiKey)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"estimatesmartfee","params":[3,"CONSERVATIVE"]}"#.utf8)
        self.request = request
    }

    func source(for network: UTXONetwork) -> UTXOFeeProvider.Source? {
        guard network == .bitcoin else { return nil }
        return .init(name: "rpc.ankr.com", delay: .zero) {
            // Shared transport records HTTP/RPC failures with credential-free
            // context and observes Retry-After before attempting another API.
            let data = try await UTXOAPIProvider.fetch(request, limit: 65_536)
            return try Self.decode(data)
        }
    }

    static func decode(_ data: Data) throws -> Int64 {
        struct Reply: Decodable {
            struct Failure: Decodable { let code: Int; let message: String }
            struct Estimate: Decodable {
                let feerate: Decimal?
                let blocks: Int
                let errors: [String]?
            }
            let id: Int
            let result: Estimate?
            let error: Failure?
        }
        guard data.count <= 65_536 else { throw BitcoinSendError.feeUnavailable }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.id == 1 else { throw BitcoinSendError.feeUnavailable }
        if let error = reply.error {
            // The source boundary applies the shared error-text privacy filter.
            throw NSError(domain: "Oath.AnkrFee", code: error.code,
                          userInfo: [NSLocalizedDescriptionKey: String(error.message.prefix(1024))])
        }
        guard let result = reply.result else { throw BitcoinSendError.feeUnavailable }
        if let errors = result.errors, !errors.isEmpty {
            throw NSError(domain: "Oath.AnkrFee", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: String(errors.prefix(4).joined(separator: "; ").prefix(1024))])
        }
        guard (1...1008).contains(result.blocks), let rate = result.feerate, !rate.isNaN, rate > 0 else {
            throw BitcoinSendError.feeUnavailable
        }
        // estimatesmartfee returns BTC per 1,000 virtual bytes. Keep decimal
        // precision and round upward to atomic/kVB, never atomic/vB or whole BTC.
        var atomic = rate * 100_000_000
        let bounds = UTXONetwork.bitcoin.sendFeeRates
        guard !atomic.isNaN, atomic > 0, atomic <= Decimal(bounds.upperBound) else {
            throw BitcoinSendError.feeUnavailable
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &atomic, 0, .up)
        return max(bounds.lowerBound, NSDecimalNumber(decimal: rounded).int64Value)
    }
}
