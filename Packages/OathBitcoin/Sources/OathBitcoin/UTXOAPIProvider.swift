import Foundation
import OathDiagnostics

/// Mainnet HTTPS routes only. Transport formats/units belong here so new
/// providers cannot accidentally reuse another chain's endpoint or coin units.
struct UTXOAPIProvider: Sendable {
    enum Format: Sendable { case mempool, blockstream, blockcypher, blockchair, blockbook }
    let network: UTXONetwork
    let base: URL
    let format: Format

    static func providers(for network: UTXONetwork) -> [Self] {
        func api(_ base: String, _ format: Format) -> Self {
            Self(network: network, base: URL(string: base)!, format: format)
        }
        let chair = api("https://api.blockchair.com/\(network == .bitcoincash ? "bitcoin-cash" : network.rawValue)", .blockchair)
        switch network {
        case .bitcoin:
            return [api("https://mempool.space/api", .mempool),
                    api("https://blockstream.info/api", .blockstream),
                    api("https://api.blockcypher.com/v1/btc/main", .blockcypher), chair]
        case .bitcoincash:
            // Trezor's hosted Blockbook endpoints reject anonymous app reads
            // with HTTP 403. They are not a usable public fallback contract.
            // Configured providers and verified TLS peers remain independent
            // recovery routes; never spoof browser headers to bypass access.
            return [chair]
        case .litecoin:
            return [api("https://litecoinspace.org/api", .mempool),
                    api("https://api.blockcypher.com/v1/ltc/main", .blockcypher), chair]
        case .dogecoin:
            return [api("https://api.blockcypher.com/v1/doge/main", .blockcypher), chair]
        }
    }

    static func broadcastProviders(for network: UTXONetwork) -> [Self] {
        let all = providers(for: network)
        // LitecoinSpace's read API is useful for fees, but its public POST
        // endpoint rejected our access. Prefer working public broadcast APIs.
        if network == .litecoin { return [all[1], all[2], all[0]] }
        return all
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: base.absoluteString + path)!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.setValue("application/json, text/plain", forHTTPHeaderField: "Accept")
        return request
    }
    var feeRequest: URLRequest {
        switch format {
        case .mempool: request("/v1/fees/recommended")
        case .blockstream: request("/fee-estimates")
        case .blockcypher: request("")
        case .blockchair: request("/stats")
        case .blockbook: request("/estimatefee/3")
        }
    }
    func broadcastRequest(hex: String) throws -> URLRequest {
        var result: URLRequest
        switch format {
        case .mempool, .blockstream:
            result = request("/tx"); result.httpBody = Data(hex.utf8)
            result.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        case .blockbook:
            result = request("/sendtx/"); result.httpBody = Data(hex.utf8)
            result.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        case .blockcypher:
            result = request("/txs/push"); result.httpBody = try JSONEncoder().encode(["tx": hex])
            result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        case .blockchair:
            // Hex needs no percent encoding. Never put transaction bytes in URLs.
            result = request("/push/transaction"); result.httpBody = Data("data=\(hex)".utf8)
            result.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        result.httpMethod = "POST"
        return result
    }
    func lookupRequest(txid: String) -> URLRequest {
        switch format {
        case .mempool, .blockstream: request("/tx/\(txid)/hex")
        case .blockcypher: request("/txs/\(txid)?includeHex=true")
        case .blockchair: request("/raw/transaction/\(txid)")
        case .blockbook: request("/tx-specific/\(txid)")
        }
    }

    func decodeFee(_ data: Data, now: Date = .now) throws -> Int64 {
        guard data.count <= 65_536 else { throw APIError.invalidResponse }
        try checkEnvelope(data)
        switch format {
        case .mempool, .blockstream:
            // BTC and LTC use the same bounded atomic/vbyte quote schema.
            return try BitcoinFeeFallback.decode(data, source: format == .mempool ? .mempool : .blockstream)
        case .blockcypher:
            return try UTXOFeeProvider.decodeBlockcypher(data, network: network, now: now)
        case .blockbook:
            struct Quote: Decodable { let result: String }
            let quote = try JSONDecoder().decode(Quote.self, from: data)
            guard quote.result.range(of: #"^[0-9]+(?:\.[0-9]{1,8})?$"#, options: .regularExpression) != nil,
                  let value = Decimal(string: quote.result, locale: Locale(identifier: "en_US_POSIX")) else { throw APIError.invalidResponse }
            return try atomicRate(value * 100_000_000)
        case .blockchair:
            struct Quote: Decodable {
                struct Stats: Decodable { let suggested_transaction_fee_per_byte_sat: Decimal }
                struct Context: Decodable {
                    struct Cache: Decodable { let since: String }
                    let code: Int; let cache: Cache
                }
                let data: Stats; let context: Context
            }
            let quote = try JSONDecoder().decode(Quote.self, from: data)
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            guard quote.context.code == 200, let date = formatter.date(from: quote.context.cache.since),
                  (-60...900).contains(now.timeIntervalSince(date)) else { throw APIError.invalidResponse }
            return try atomicRate(quote.data.suggested_transaction_fee_per_byte_sat * 1000)
        }
    }
    private func atomicRate(_ value: Decimal) throws -> Int64 {
        // Reject excessive quotes rather than clamping them into a misleading fee.
        guard !value.isNaN, value > 0, value <= Decimal(network.sendFeeRates.upperBound) else { throw BitcoinSendError.feeUnavailable }
        var value = value, rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .up)
        return max(network.sendFeeRates.lowerBound, NSDecimalNumber(decimal: rounded).int64Value)
    }

    func decodeBroadcast(_ data: Data) throws -> String {
        guard data.count <= 65_536 else { throw APIError.invalidResponse }
        let hash: String?
        switch format {
        case .mempool, .blockstream:
            hash = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        case .blockbook:
            try checkEnvelope(data)
            struct Reply: Decodable { let result: String }
            hash = try JSONDecoder().decode(Reply.self, from: data).result
        case .blockcypher:
            try checkEnvelope(data)
            struct Reply: Decodable {
                struct TX: Decodable { let hash: String }
                let hash: String?; let tx: TX?
            }
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            hash = reply.hash ?? reply.tx?.hash
        case .blockchair:
            try checkEnvelope(data)
            struct Reply: Decodable {
                struct TX: Decodable { let transaction_hash: String }
                struct Context: Decodable { let code: Int }
                let data: TX; let context: Context
            }
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            guard reply.context.code == 200 else { throw APIError.invalidResponse }
            hash = reply.data.transaction_hash
        }
        guard let hash, hash.count == 64, hash.utf8.allSatisfy(Self.isHex) else { throw APIError.invalidResponse }
        return hash.lowercased()
    }

    func decodeRaw(_ data: Data, txid: String) throws -> Data? {
        guard data.count <= 4_194_304 else { throw APIError.invalidResponse }
        if data.isEmpty { return nil } // A not-yet-propagated transaction is normal.
        let hex: String?
        switch format {
        case .mempool, .blockstream:
            hex = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        case .blockbook, .blockcypher:
            try checkEnvelope(data)
            struct Reply: Decodable { let hex: String }
            hex = try JSONDecoder().decode(Reply.self, from: data).hex
        case .blockchair:
            try checkEnvelope(data)
            // Blockchair represents a missing transaction as [] rather than {}.
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (object?["context"] as? [String: Any])?["code"] as? Int == 200 else { throw APIError.invalidResponse }
            if let missing = object?["data"] as? [Any], missing.isEmpty { return nil }
            guard let rows = object?["data"] as? [String: [String: Any]] else { throw APIError.invalidResponse }
            guard let row = rows[txid] else { return nil }
            hex = row["raw_transaction"] as? String
        }
        guard let hex, !hex.isEmpty, hex.utf8.allSatisfy(Self.isHex), let raw = Data(hex: hex) else { throw APIError.invalidResponse }
        return raw
    }
    private static func isHex(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value)
    }
    private func checkEnvelope(_ data: Data) throws {
        // Alternative envelope decoding is expected; each strict success schema
        // is decoded separately. Never report entire bodies or echoed raw bytes.
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let context = object["context"] as? [String: Any]
        if let error = object["error"], !(error is NSNull) { throw APIError.rejected }
        if let errors = object["errors"] as? [Any], !errors.isEmpty { throw APIError.rejected }
        if let code = context?["code"] as? Int, code != 200 {
            if let message = context?["error"] as? String {
                // The source boundary records this original provider error using
                // the shared privacy filter before attempting another provider.
                throw NSError(domain: "Oath.UTXOAPI", code: code,
                    userInfo: [NSLocalizedDescriptionKey: String(message.prefix(1024))])
            }
            throw APIError.http(code)
        }
    }
    enum APIError: Error { case http(Int), invalidResponse, rejected, mismatchedTransaction }

    static func fetch(_ request: URLRequest, limit: Int, allowMissing: Bool = false,
                      missingRPCCode: Int? = nil,
                      session: URLSession = .shared, budget: UTXOAPIBudget = .shared) async throws -> Data {
        let host = request.url?.host ?? "unknown"
        try await budget.acquire(host)
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch {
            await budget.release(host)
            OathDiagnostics.record(error, component: "network", context: DiagnosticHTTP.context(request))
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            await budget.release(host); throw APIError.invalidResponse
        }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
        if allowMissing, http.statusCode == 404 {
            bytes.task.cancel()
            await budget.finish(host, statuses: [404], retryAfter: retryAfter)
            try Task.checkCancellation()
            return Data()
        }
        let body: Data?
        do { body = try await DiagnosticHTTP.readBody(bytes, maximumBytes: limit) }
        catch {
            await budget.finish(host, statuses: [http.statusCode], retryAfter: retryAfter)
            OathDiagnostics.record(error, component: "network", context: DiagnosticHTTP.context(request))
            throw error
        }
        guard let data = body else {
            await budget.finish(host, statuses: [http.statusCode], retryAfter: retryAfter)
            DiagnosticHTTP.response(Data(), status: http.statusCode, request: request)
            throw APIError.invalidResponse
        }
        var statuses = [http.statusCode]
        // Some providers encode throttling inside HTTP 200. Inspect only this
        // bounded status envelope; it is not a fee or transaction result.
        let envelope = data.count <= 65_536 ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] : nil
        if let code = (envelope?["context"] as? [String: Any])?["code"] as? Int { statuses.append(code) }
        if let code = (envelope?["error"] as? [String: Any])?["code"] as? Int, code == 429 {
            statuses.append(code) // Alchemy can throttle with a JSON-RPC envelope.
        }
        await budget.finish(host, statuses: statuses, retryAfter: retryAfter)
        // An absent transaction during reconciliation is expected. Restrict the
        // exclusion to this exact Alchemy read and correlated -5 response; all
        // broadcast rejections and provider outages still reach diagnostics.
        if missingRPCCode == -5, http.statusCode == 200, AlchemyUTXOAPI.isHost(host),
           DiagnosticHTTP.context(request)["method"] == "getrawtransaction",
           envelope?["id"] as? Int == 1,
           (envelope?["error"] as? [String: Any])?["code"] as? Int == -5 {
            return data
        }
        DiagnosticHTTP.response(data, status: http.statusCode, request: request)
        guard (200...299).contains(http.statusCode) else {
            // Preserve Blockchair's nested error envelope through shared filters.
            if request.url?.host == "api.blockchair.com" {
                let provider = UTXOAPIProvider(network: UTXONetwork(rawValue: OathDiagnostics.chain ?? "") ?? .bitcoin,
                                               base: request.url!, format: .blockchair)
                try provider.checkEnvelope(data)
            }
            // Esplora errors are plain text with possible transaction echoes.
            // Keep only recognized policy classifications, never the raw body.
            let text = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
            let policy = ["txn-already-in-mempool", "already in block chain", "txn-mempool-conflict",
                          "missing-inputs", "bad-txns-inputs-missingorspent", "too-long-mempool-chain",
                          "min relay fee not met", "mempool min fee not met", "mandatory-script-verify-flag-failed",
                          "non-mandatory-script-verify-flag", "tx decode failed"].first(where: text.contains)
            if let policy { throw NSError(domain: "Oath.UTXOAPI", code: http.statusCode,
                                           userInfo: [NSLocalizedDescriptionKey: policy]) }
            throw APIError.http(http.statusCode)
        }
        return data
    }
}
