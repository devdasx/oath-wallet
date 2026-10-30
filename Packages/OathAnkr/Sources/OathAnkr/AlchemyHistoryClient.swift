import Foundation
import OathDiagnostics

/// Address-filtered discovery only. Consumers verify mined transactions and
/// logs against receipts before committing them. Never use rounded `value`.
struct AlchemyHistoryClient: Sendable {
    enum Network: String, Sendable {
        case arc = "arc-mainnet", robinhood = "robinhood-mainnet"
        var chainID: Int { self == .arc ? ArcIdentity.chainID : RobinhoodIdentity.chainID }
        var diagnosticChain: String { self == .arc ? "arc" : "robinhood" }
    }
    struct Reply: Sendable { let value: SolanaJSON; let raw: Data }
    struct Page: Sendable { let transfers: [SolanaJSON]; let next: String?; let raw: Data }
    let network: Network
    let endpoint: URL
    private let transport: any AnkrTransport
    private let permits = AnkrPermits(count: 1)

    init(network: Network, apiKey: String, transport: any AnkrTransport) throws {
        guard !apiKey.isEmpty, apiKey.count <= 256,
              apiKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw AnkrError.configurationMissing }
        self.network = network; self.transport = transport
        endpoint = URL(string: "https://\(network.rawValue).g.alchemy.com/v2/")!.appendingPathComponent(apiKey)
    }
    func request(_ method: String, _ params: [SolanaJSON]) async throws -> Reply {
        try await OathDiagnostics.withChain(network.diagnosticChain) {
            try await requestInContext(method, params)
        }
    }
    private func requestInContext(_ method: String, _ params: [SolanaJSON]) async throws -> Reply {
        let calls: SolanaJSON = .array([("eth_chainId", [SolanaJSON]()), (method, params)].enumerated().map { i, call in
            .object(["jsonrpc": .string("2.0"), "id": .number(String(i)), "method": .string(call.0), "params": .array(call.1)])
        })
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(calls)
        try await permits.acquire()
        do {
            for attempt in 0..<3 {
                try Task.checkCancellation()
                do {
                    let (data, status) = try await transport.send(request)
                    guard status == 200 else { throw AnkrError.http(status) }
                    guard data.count <= 8 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
                    let json = try JSONDecoder().decode(SolanaJSON.self, from: data)
                    guard let rows = json.array, rows.count == 2,
                          rows.allSatisfy({ $0["jsonrpc"].string == "2.0" }),
                          rows.filter({ $0["id"].integer == 0 }).count == 1,
                          rows.filter({ $0["id"].integer == 1 }).count == 1 else { throw AnkrError.invalidResponse }
                    let chain = rows.first { $0["id"].integer == 0 }!, response = rows.first { $0["id"].integer == 1 }!
                    guard try ArcIdentity.amount(Self.result(chain)) == String(network.chainID) else { throw AnkrError.wrongChain }
                    let value = try Self.result(response)
                    await permits.release(); return .init(value: value, raw: data)
                } catch {
                    OathDiagnostics.record(error, operation: "alchemy_history")
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    let retry: Bool
                    switch error {
                    case AnkrError.http(let status): retry = status == 429 || (500...599).contains(status)
                    case AnkrError.transport: retry = true
                    default: retry = false
                    }
                    if retry && attempt < 2 { try await Task.sleep(for: .milliseconds(500 * (1 << attempt))); continue }
                    throw error
                }
            }
            throw AnkrError.transport
        } catch { OathDiagnostics.record(error, operation: "alchemy_history"); await permits.release(); throw error }
    }
    private static func result(_ row: SolanaJSON) throws -> SolanaJSON {
        if let code = row["error"]["code"].text.flatMap(Int.init) { throw AnkrError.rpc(code) }
        guard case .object(let object) = row, let value = object["result"], !value.isNull else { throw AnkrError.invalidResponse }
        return value
    }
    func transfers(owner: String, incoming: Bool, categories: [String], from: Int64 = 0,
                   through: Int64? = nil, ascending: Bool = false, cursor: String? = nil) async throws -> Page {
        try await OathDiagnostics.withChain(network.diagnosticChain) {
            try await transfersInContext(owner: owner, incoming: incoming, categories: categories,
                                         from: from, through: through, ascending: ascending, cursor: cursor)
        }
    }
    private func transfersInContext(owner: String, incoming: Bool, categories: [String], from: Int64,
                                    through: Int64?, ascending: Bool, cursor: String?) async throws -> Page {
        let owner = try ArcIdentity.address(owner)
        guard from >= 0, through == nil || through! > from, !categories.isEmpty,
              categories.allSatisfy({ ["external", "erc20", "internal"].contains($0) }),
              network == .arc || !categories.contains("internal") else { throw AnkrError.invalidResponse }
        var options: [String: SolanaJSON] = ["fromBlock": .string("0x" + String(from, radix: 16)),
            "toBlock": .string(through.map { "0x" + String($0 - 1, radix: 16) } ?? "latest"),
            incoming ? "toAddress" : "fromAddress": .string(owner), "order": .string(ascending ? "asc" : "desc"),
            "maxCount": .string("0x64"), "withMetadata": .bool(true), "excludeZeroValue": .bool(false),
            "category": .array(categories.map(SolanaJSON.string))]
        if let cursor { guard !cursor.isEmpty, cursor.count <= 4096 else { throw AnkrError.invalidResponse }; options["pageKey"] = .string(cursor) }
        let reply: Reply
        do { reply = try await request("alchemy_getAssetTransfers", [.object(options)]) }
        catch AnkrError.rpc(-32602) where cursor != nil {
            // The original provider code was recorded at the request boundary.
            // Page keys expire; the existing one-time history restart preserves
            // the interval instead of marking an expired page as complete.
            OathDiagnostics.record(AnkrError.rpc(-32602), operation: "alchemy_cursor")
            throw AnkrError.http(422)
        }
        guard let transfers = reply.value["transfers"].array, transfers.count <= 100 else { throw AnkrError.invalidResponse }
        var previous = ascending ? Int64.min : Int64.max
        for value in transfers {
            guard let hash = value["hash"].string, AnkrQuantity.hash(hash),
                  let category = value["category"].string, categories.contains(category),
                  let sender = value["from"].string else { throw AnkrError.invalidResponse }
            let senderAddress = try ArcIdentity.address(sender)
            let recipientAddress = try value["to"].string.map(ArcIdentity.address)
            guard recipientAddress != nil || (category == "external" && value["to"].isNull),
                  (incoming ? recipientAddress : senderAddress) == owner else { throw AnkrError.wrongAccount }
            let block = try ArcIdentity.height(value["blockNum"])
            guard block >= from, through == nil || block < through!, ascending ? block >= previous : block <= previous else { throw AnkrError.invalidResponse }
            previous = block
        }
        guard reply.value["pageKey"].isNull || reply.value["pageKey"].string != nil else { throw AnkrError.invalidResponse }
        let next = reply.value["pageKey"].string.flatMap { $0.isEmpty ? nil : $0 }
        if let next { guard next.count <= 4096, next != cursor, !transfers.isEmpty else { throw AnkrError.paginationLoop } }
        return .init(transfers: transfers, next: next, raw: reply.raw)
    }
}
