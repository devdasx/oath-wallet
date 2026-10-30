import Foundation
import OathDiagnostics

/// Committed transaction logs, not EVM re-execution against a provider's state.
/// Wire schema: iotex-proto/api/api.proto and types/transaction_log.proto.
struct IoTeXNativeLogs: Sendable {
    struct Movement: Sendable, Equatable { let amount: String; let sender: String; let recipient: String; let type: UInt64 }
    let block: Int64
    let blockHash: String
    let actions: [String: [Movement]]
    private static let permits = AnkrPermits(count: 2)

    private static func request(method: String, message: Data, transport: any AnkrTransport) async throws -> Data {
        let length = UInt32(message.count)
        let body = Data([0, UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)]) + message
        try await permits.acquire()
        do {
            var last: Error = AnkrError.transport
            for host in ["api.iotex.one", "api.mainnet.iotex.one"] {
                do {
                    var request = URLRequest(url: URL(string: "https://" + host + "/iotexapi.APIService/" + method)!)
                    request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 25
                    request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
                    request.setValue("trailers", forHTTPHeaderField: "TE")
                    request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
                    let (data, status) = try await transport.send(request)
                    guard status == 200 else { throw AnkrError.http(status) }
                    _ = try envelope(data)
                    await permits.release(); return data
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    OathDiagnostics.record(error, operation: "iotex_native_rpc", context: ["chain": "iotex", "host": host, "stage": "history"])
                    last = error
                }
            }
            throw last
        } catch {
            OathDiagnostics.record(error, operation: "iotex_native_recovery", context: ["chain": "iotex"])
            await permits.release(); throw error
        }
    }
    static func read(height: Int64, transport: any AnkrTransport) async throws -> (Self, Data) {
        guard height >= 0 else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
        let data = try await request(method: "GetTransactionLogByBlockHeight", message: TronSendCrypto.number(1, UInt64(height)), transport: transport)
        let result = try decode(data)
        guard result.block == height else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
        return (result, data)
    }
    static func accountActions(owner: String, before: UInt64?, transport: any AnkrTransport) async throws -> (rows: [SolanaJSON], next: UInt64?, raw: Data) {
        let address = try IoTeXIdentity.native(owner)
        var evidence: [Data] = [], total: UInt64
        if let before { total = before }
        else {
            let data = try await request(method: "GetAccount", message: TronSendCrypto.field(1, Data(address.utf8)), transport: transport)
            let response = try envelope(data), account = try fields(one(response, 1))
            guard try text(account, 1) == address else { throw AnkrError.wrongAccount }
            total = try integer(account, 5); evidence.append(data)
        }
        guard total <= 100_000_000 else { throw AnkrError.responseTooLarge }
        guard total > 0 else { return ([], nil, try JSONEncoder().encode(evidence)) }
        let count = min(total, UInt64(IoTeXIndex.pageSize)), start = total - count
        let lookup = TronSendCrypto.field(1, Data(address.utf8)) + TronSendCrypto.number(2, start) + TronSendCrypto.number(3, count)
        let data = try await request(method: "GetActions", message: TronSendCrypto.field(3, lookup), transport: transport)
        let response = try envelope(data), values = response[1] ?? []
        guard values.count == count else { throw AnkrError.incompleteInventory }
        let rows = try values.reversed().map { field -> SolanaJSON in
            guard case .bytes(let data) = field else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
            let action = try fields(data), hash = "0x" + (try text(action, 2)), height = try integer(action, 5)
            guard AnkrQuantity.hash(hash), height <= Int64.max else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
            return .object(["hash": .string(hash), "blockNumber": .number(String(height))])
        }
        evidence.append(data)
        return (rows, start > 0 ? start : nil, try JSONEncoder().encode(evidence))
    }
    private static func envelope(_ data: Data) throws -> [Int:[Field]] {
        guard data.count >= 5, data.count <= 8 * 1024 * 1024, data.first == 0,
              data.dropFirst().prefix(4).reduce(UInt32(0), { ($0 << 8) | UInt32($1) }) == data.count - 5 else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
        return try fields(Data(data.dropFirst(5)))
    }
    static func decode(_ data: Data) throws -> Self {
        let response = try envelope(data)
        let block = try fields(one(response, 2)), number = try integer(block, 2)
        let blockHash = "0x" + (try text(block, 1))
        guard number <= Int64.max, AnkrQuantity.hash(blockHash) else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
        let logs = try fields(one(response, 1))
        guard (logs[1]?.count ?? 0) <= 10_000 else { throw AnkrError.responseTooLarge }
        var actions: [String: [Movement]] = [:]
        for entry in logs[1] ?? [] {
            guard case .bytes(let bytes) = entry else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
            let log = try fields(bytes), hashBytes = try one(log, 1)
            guard hashBytes.count == 32 else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
            let hash = "0x" + hashBytes.map { String(format:"%02x",$0) }.joined()
            let raw = log[3] ?? []
            guard raw.count <= 10_000, try integer(log, 2) == raw.count, actions[hash] == nil else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
            actions[hash] = try raw.map { field in
                guard case .bytes(let bytes) = field else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
                let value = try fields(bytes), amount = try text(value, 2)
                let canonical = try AnkrQuantity.decimal(amount)
                guard canonical == amount, amount.utf8.allSatisfy({ (48...57).contains($0) }) else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
                return try .init(amount: amount, sender: text(value, 3), recipient: text(value, 4), type: integer(value, 5))
            }
        }
        return .init(block: Int64(number), blockHash: blockHash, actions: actions)
    }
    func movements(hash: String, receipt: SolanaJSON, transaction: SolanaJSON, block: SolanaJSON, owner: String) throws -> [SolanaJSON] {
        guard blockHash == receipt["blockHash"].string?.lowercased(), self.block == (try IndexedEVMIdentity.height(receipt["blockNumber"])),
              let records = actions[hash] else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
        let base = try IoTeXIndex.base(hash, receipt: receipt, block: block)
        let rootAmount = try IndexedEVMIdentity.amount(transaction["value"])
        var rootSkipped = false
        return try records.enumerated().compactMap { index, record in
            // Fees belong to the external transaction. Protocol staking/reward
            // accounting records are not EVM call transfers.
            guard record.type == 0 || record.type == 7 else { return nil }
            let from = try IoTeXIdentity.ethereum(record.sender), to = try IoTeXIdentity.ethereum(record.recipient)
            if !rootSkipped, from == transaction["from"].string?.lowercased(),
               to == transaction["to"].string?.lowercased(), record.amount == rootAmount {
                rootSkipped = true; return nil
            }
            guard record.amount != "0", from == owner || to == owner else { return nil }
            var value = base
            value["from"] = .object(["hash": .string(from)]); value["to"] = .object(["hash": .string(to)])
            value["value"] = .string(record.amount); value["index"] = .number(String(index))
            value["success"] = .bool(try IoTeXIndex.succeeded(receipt))
            return .object(value)
        }
    }
    private enum Field { case bytes(Data), number(UInt64) }
    private static func one(_ fields: [Int:[Field]], _ tag: Int) throws -> Data {
        guard let values = fields[tag], values.count == 1, case .bytes(let data) = values[0] else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }; return data
    }
    private static func text(_ fields: [Int:[Field]], _ tag: Int) throws -> String {
        guard let text = String(data: try one(fields, tag), encoding: .utf8), text.utf8.count <= 256 else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }; return text
    }
    private static func integer(_ fields: [Int:[Field]], _ tag: Int) throws -> UInt64 {
        guard let values = fields[tag] else { return 0 }
        guard values.count == 1, case .number(let value) = values[0] else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }; return value
    }
    private static func fields(_ data: Data) throws -> [Int:[Field]] {
        let bytes = Array(data); var offset = 0, fields: [Int:[Field]] = [:], count = 0
        func integer() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < bytes.count else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
                let byte = bytes[offset]; offset += 1
                guard shift != 63 || byte <= 1 else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation")
        }
        while offset < bytes.count {
            let key = try integer(), tag = key >> 3, wire = key & 7
            count += 1
            guard tag > 0, tag < 1 << 29, count <= 50_000 else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
            if wire == 0 { fields[Int(tag), default: []].append(.number(try integer())) }
            else if wire == 2 {
                let length = try integer()
                guard length <= bytes.count - offset else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
                fields[Int(tag), default: []].append(.bytes(Data(bytes[offset..<offset + Int(length)]))); offset += Int(length)
            } else if wire == 1 || wire == 5 {
                let length = wire == 1 ? 8 : 4
                guard length <= bytes.count - offset else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }; offset += length
            } else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
        }
        return fields
    }
}
