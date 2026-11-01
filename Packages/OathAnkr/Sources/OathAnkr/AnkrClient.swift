import OathDiagnostics
import Foundation

public protocol AnkrTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}
public struct AnkrHTTPTransport: AnkrTransport {
    private let session: URLSession
    public init(maximumConnectionsPerHost: Int = 4) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = min(64, max(1, maximumConnectionsPerHost))
        session = URLSession(configuration: config)
    }
    init(session: URLSession) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let response = try await PublicMarketRequests.shared.send(request) { try await raw(request) }
        return (response.data, response.status)
    }
    private func raw(_ request: URLRequest) async throws -> PublicMarketRequests.Response {
        // Balances currently ignore pageSize on some chains (observed >12,000
        // assets). Bound the actual byte stream, not just Content-Length.
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw AnkrError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 64 * 1024 * 1024 { throw AnkrError.responseTooLarge }
            }
            try Task.checkCancellation()
            DiagnosticHTTP.response(data, status: response.statusCode, request: request)
            return .init(data: data, status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        } catch is CancellationError { throw CancellationError() }
        catch let error as AnkrError {
            try Task.checkCancellation()
            OathDiagnostics.record(error); throw error
        }
        catch {
            // URLSession can cancel a request independently of its Swift task.
            // Preserve that cancellation before clients classify/retry outages.
            // A failure already queued by URLSession may also arrive after
            // navigation cancelled its task. Teardown must not emit an outage.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            OathDiagnostics.record(error, component: "network", context: DiagnosticHTTP.context(request))
            throw AnkrError.transport
        }
    }
}

/// A monotonic cancellation boundary shared by one refresh generation. Invalidate
/// it before cancelling individual workers: an unwinding worker can release a
/// permit before a later worker's Task cancellation flag has been set.
public final class AnkrRequestScope: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    func checkCancellation() throws {
        try Task.checkCancellation()
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

public struct AnkrClient: Sendable {
    private let endpoint: URL
    private let transport: any AnkrTransport
    private let permits = AnkrPermits(count: 4)
    public init(apiKey: String, transport: any AnkrTransport = AnkrHTTPTransport()) throws {
        guard !apiKey.isEmpty, apiKey.count <= 256,
              apiKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw AnkrError.configurationMissing
        }
        endpoint = URL(string: "https://rpc.ankr.com/multichain")!.appendingPathComponent(apiKey)
        self.transport = transport
    }
    public func balances(chain: AnkrChain, address: String, cursor: String? = nil,
                         onlyWhitelisted: Bool = true, requestScope: AnkrRequestScope? = nil) async throws -> AnkrPage<AnkrBalanceResult> {
        // Explicit on every page. Unfiltered discovery is a per-wallet opt-in;
        // callers retain whitelist evidence separately from token visibility.
        var params: [String: Any] = ["blockchain": [chain.rawValue], "walletAddress": address, "onlyWhitelisted": onlyWhitelisted, "nativeFirst": true, "pageSize": 1000]
        if let cursor { params["pageToken"] = cursor }
        let request = try makeRequest("ankr_getAccountBalance", address: address, params: params)
        let page: AnkrPage<AnkrBalanceResult> = try await call(request, scope: requestScope)
        for asset in page.value.assets {
            guard asset.blockchain == chain.rawValue else { throw AnkrError.wrongChain }
            guard asset.holderAddress.lowercased() == address.lowercased() else { throw AnkrError.wrongAccount }
            guard ["NATIVE", "ERC20"].contains(asset.tokenType), (0...255).contains(asset.tokenDecimals),
                  AnkrQuantity.address(asset.contractAddress) else { throw AnkrError.invalidResponse }
            _ = try AnkrQuantity.decimal(asset.balanceRawInteger)
        }
        return page
    }
    public func transactions(chain: AnkrChain, address: String, cursor: String? = nil,
                             fromTimestamp: Int? = nil, toTimestamp: Int? = nil, pageSize: Int = 100,
                             requestScope: AnkrRequestScope? = nil) async throws -> AnkrPage<AnkrTransactionResult> {
        let params = historyParams(chain, address, cursor, fromTimestamp, toTimestamp, pageSize, transfers: false)
        let request = try makeRequest("ankr_getTransactionsByAddress", address: address, params: params)
        let page: AnkrPage<AnkrTransactionResult> = try await call(request, scope: requestScope)
        for tx in page.value.transactions {
            guard tx.blockchain == chain.rawValue else { throw AnkrError.wrongChain }
            guard tx.from.lowercased() == address.lowercased() || tx.to?.lowercased() == address.lowercased() else { throw AnkrError.wrongAccount }
            guard AnkrQuantity.hash(tx.hash), AnkrQuantity.address(tx.from),
                  tx.to == nil || tx.to == "" || AnkrQuantity.address(tx.to!) else { throw AnkrError.invalidResponse }
            _ = try AnkrQuantity.decimal(tx.value)
        }
        return page
    }
    public func transfers(chain: AnkrChain, address: String, cursor: String? = nil,
                          fromTimestamp: Int? = nil, toTimestamp: Int? = nil, pageSize: Int = 100,
                          requestScope: AnkrRequestScope? = nil) async throws -> AnkrPage<AnkrTransferResult> {
        let params = historyParams(chain, address, cursor, fromTimestamp, toTimestamp, pageSize, transfers: true)
        let request = try makeRequest("ankr_getTokenTransfers", address: address, params: params)
        let page: AnkrPage<AnkrTransferResult> = try await call(request, scope: requestScope)
        for item in page.value.transfers {
            guard item.blockchain == chain.rawValue else { throw AnkrError.wrongChain }
            guard item.fromAddress.lowercased() == address.lowercased() || item.toAddress.lowercased() == address.lowercased() else { throw AnkrError.wrongAccount }
            guard AnkrQuantity.hash(item.transactionHash), AnkrQuantity.address(item.contractAddress),
                  AnkrQuantity.address(item.fromAddress), AnkrQuantity.address(item.toAddress),
                  (0...255).contains(item.tokenDecimals), item.logIndex >= 0, item.blockHeight >= 0,
                  item.timestamp.isFinite, item.timestamp >= 0 else { throw AnkrError.invalidResponse }
            _ = try AnkrQuantity.decimal(item.valueRawInteger)
        }
        return page
    }
    private func historyParams(_ chain: AnkrChain, _ address: String, _ cursor: String?, _ from: Int?, _ to: Int?,
                               _ pageSize: Int, transfers: Bool) -> [String: Any] {
        var p: [String: Any] = ["blockchain": [chain.rawValue], "address": transfers ? [address] : address,
                               "descOrder": true, "pageSize": min(1000, max(1, pageSize))]
        if !transfers { p["includeLogs"] = true; p["decodeLogs"] = true; p["decodeTxData"] = true }
        if let cursor { p["pageToken"] = cursor }
        if let from { p["fromTimestamp"] = from }
        if let to { p["toTimestamp"] = to }
        return p
    }
    private func makeRequest(_ method: String, address: String, params: [String: Any]) throws -> URLRequest {
        guard AnkrQuantity.address(address) else { throw AnkrError.invalidAddress }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        return request
    }
    private func call<T: Decodable & Sendable>(_ request: URLRequest, scope: AnkrRequestScope?) async throws -> AnkrPage<T> {
        try scope?.checkCancellation()
        try await permits.acquire()
        do {
            try scope?.checkCancellation()
            let page: AnkrPage<T> = try await exchange(request, scope: scope)
            await permits.release()
            return page
        } catch { OathDiagnostics.record(error); await permits.release(); throw error }
    }
    private func exchange<T: Decodable & Sendable>(_ request: URLRequest, scope: AnkrRequestScope?) async throws -> AnkrPage<T> {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            try scope?.checkCancellation()
            do {
                let (data, status) = try await transport.send(request)
                try scope?.checkCancellation()
                guard data.count <= 64 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
                guard status == 200 else { throw AnkrError.http(status) }
                let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
                guard envelope.jsonrpc == "2.0", envelope.id == 1 else { throw AnkrError.invalidResponse }
                if let error = envelope.error { throw AnkrError.rpc(error.code) }
                guard let result = envelope.result else { throw AnkrError.invalidResponse }
                return AnkrPage(value: result, raw: data, fetchedAt: .now)
            } catch { OathDiagnostics.record(error);
                let retry: Bool
                switch error {
                case AnkrError.http(let code): retry = code == 429 || (500...599).contains(code)
                // Advanced API failures can arrive as HTTP 200 JSON-RPC
                // errors. Retry only the documented transient gateway codes.
                case AnkrError.rpc(let code):
                    retry = [-32603, -32055, -32056, -32057, -32059, -32061, -32063, -32064,
                             -32067, -32068, -32069, -32070, -32071, -32076, -32077, -32090].contains(code)
                case AnkrError.transport: retry = true
                default: retry = false
                }
                if retry && attempt < 2 { try await Task.sleep(for: .milliseconds(500 * (1 << attempt))); continue }
                if error is DecodingError { throw AnkrError.invalidResponse }
                throw error
            }
        }
        throw AnkrError.transport
    }
    private struct Envelope<T: Decodable>: Decodable {
        struct RPCError: Decodable { let code: Int }
        let id: Int?
        let jsonrpc: String?
        let result: T?
        let error: RPCError?
    }
}

actor AnkrPermits {
    var count: Int
    var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    init(count: Int) { self.count = count }
    func acquire() async throws {
        try Task.checkCancellation()
        if count > 0 { count -= 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func release() {
        if waiters.isEmpty { count += 1 } else { waiters.removeFirst().1.resume() }
    }
    func cancel(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: i).1.resume(throwing: CancellationError())
    }
}
