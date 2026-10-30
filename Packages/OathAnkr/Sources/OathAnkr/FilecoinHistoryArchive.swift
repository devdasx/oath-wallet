import Foundation
import OathDiagnostics

/// Corroborates archival history when Lotus no longer retains a hash-index entry.
/// This is explorer evidence, kept distinct from RPC receipt verification.
struct FilecoinHistoryArchive: Sendable {
    private let reader: FilecoinArchiveReader
    init(transport: any AnkrTransport) { reader = FilecoinArchiveReader(transport: transport) }

    func messages(hashes: [String], transferRows: [SolanaJSON] = [], internalRows: [SolanaJSON] = []) async throws -> [String: SolanaJSON] {
        guard hashes.count <= 50 else { throw AnkrError.responseTooLarge }
        let actors = try await actorIDs(rows: internalRows)
        return try await withThrowingTaskGroup(of: (String, SolanaJSON).self) { group in
            var next = 0, bytes = 0, result: [String: SolanaJSON] = [:]
            func enqueue() {
                guard next < hashes.count else { return }
                let hash = hashes[next]; next += 1
                group.addTask {
                    var value = try await message(hash: hash)
                    let rows = transferRows.filter { $0["transaction_hash"].string?.lowercased() == hash }
                    let needsLogs = rows.contains { row in
                        !(value["tokenTransfers"].array ?? []).contains { Self.matches(row, transfer: $0, stream: .transfers) }
                    }
                    if needsLogs {
                        guard let cid = value["cid"].string, cid.hasPrefix("bafy"), (40...128).contains(cid.count),
                              cid.utf8.allSatisfy({ (97...122).contains($0) || (50...55).contains($0) }),
                              case .object(var fields) = value else { throw AnkrError.invalidResponse }
                        let logs = try await read(path: cid + "/events")
                        guard let events = logs.array, events.count <= 10_000 else { throw AnkrError.invalidResponse }
                        fields["archive_event_logs"] = logs
                        value = .object(fields)
                    }
                    let calls = internalRows.filter { $0["transaction_hash"].string?.lowercased() == hash }
                    if calls.contains(where: { row in
                        !(value["transfers"].array ?? []).contains { Self.matches(row, transfer: $0, stream: .internalTransactions) }
                    }) {
                        guard let cid = value["cid"].string, cid.hasPrefix("bafy"), (40...128).contains(cid.count),
                              cid.utf8.allSatisfy({ (97...122).contains($0) || (50...55).contains($0) }),
                              case .object(var fields) = value else { throw AnkrError.invalidResponse }
                        fields["archive_subcalls"] = .array(try Self.flatten(await read(path: cid + "/subcalls")))
                        fields["archive_actor_ids"] = .object(actors.mapValues { .string($0) })
                        value = .object(fields)
                    }
                    return (hash, value)
                }
            }
            for _ in 0..<4 { enqueue() }
            for try await (hash, message) in group {
                bytes += try JSONEncoder().encode(message).count
                guard bytes <= 32 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
                result[hash] = message; enqueue()
            }
            return result
        }
    }

    private func message(hash: String) async throws -> SolanaJSON {
        guard AnkrQuantity.hash(hash) else { throw AnkrError.invalidResponse }
        let result = try await read(path: hash)
        guard result["ethTransactionHash"].string?.lowercased() == hash else { throw AnkrError.invalidResponse }
        return result
    }

    private func read(path: String, collection: String = "message") async throws -> SolanaJSON {
        try await reader.read(path: path, collection: collection)
    }

    private func actorIDs(rows: [SolanaJSON]) async throws -> [String: String] {
        let addresses = try Set(rows.flatMap { [$0["from"]["hash"], $0["to"]["hash"]] }.map {
            try IndexedEVMIdentity.address($0.string ?? "")
        }).sorted()
        guard addresses.count <= 100 else { throw AnkrError.responseTooLarge }
        return try await withThrowingTaskGroup(of: (String, String).self) { group in
            var next = 0, result: [String: String] = [:]
            func enqueue() {
                guard next < addresses.count else { return }
                let address = addresses[next]; next += 1
                group.addTask {
                    let json = try await read(path: address, collection: "address")
                    guard json["ethAddress"].string?.lowercased() == address,
                          let id = json["id"].string, id.hasPrefix("f0"), UInt64(id.dropFirst(2)) != nil else { throw AnkrError.invalidResponse }
                    return (address, id)
                }
            }
            for _ in 0..<4 { enqueue() }
            for try await (address, id) in group { result[address] = id; enqueue() }
            return result
        }
    }

    static func flatten(_ value: SolanaJSON) throws -> [SolanaJSON] {
        guard let roots = value.array else { throw AnkrError.invalidResponse }
        var pending = roots.map { ($0, false) }, result: [SolanaJSON] = []
        while let (call, ancestorFailed) = pending.popLast() {
            guard result.count + pending.count < 10_000, let children = call["subcalls"].array,
                  case .object(var fields) = call else { throw AnkrError.responseTooLarge }
            let reverted = try ancestorFailed || IndexedEVMIdentity.amount(call["receipt"]["exitCode"]) != "0"
            fields["subcalls"] = nil
            fields["archive_reverted"] = .bool(reverted)
            result.append(.object(fields)); pending += children.map { ($0, reverted) }
        }
        return result
    }

    static func address(_ value: SolanaJSON, id: SolanaJSON = .null) throws -> String {
        if let text = value.string, text.hasPrefix("f4") || text.hasPrefix("0x") {
            return try FilecoinIdentity.ethereum(text)
        }
        if let text = value.string, !["f0", "f1", "f2", "f3"].contains(where: text.hasPrefix) { throw AnkrError.invalidResponse }
        let text = value.string?.hasPrefix("f0") == true ? value.string : id.string
        guard let text, text.hasPrefix("f0"), let number = UInt64(text.dropFirst(2)), text == "f0" + String(number) else { throw AnkrError.invalidResponse }
        return "0xff" + String(repeating: "0", count: 22) + String(format: "%016llx", number)
    }

    static func corroborate(rows: [SolanaJSON], messages: [String: SolanaJSON], stream: IndexedEVMHistoryStream) throws -> [SolanaJSON] {
        var consumed: [String: Set<Int>] = [:]
        return try rows.compactMap { row in
            if row["timestamp"].isNull, stream == .transactions, row["block_number"].isNull { return nil }
            guard case .object(var result) = row,
                  let hash = row[stream == .transactions ? "hash" : "transaction_hash"].string?.lowercased(),
                  let message = messages[hash], message["ethTransactionHash"].string?.lowercased() == hash,
                  try IndexedEVMIdentity.height(message["height"]) == IndexedEVMIdentity.height(row["block_number"]),
                  let timestamp = message["timestamp"].text.flatMap(Double.init),
                  timestamp == (try IndexedEVMIdentity.timestamp(row["timestamp"])) else { throw AnkrError.invalidResponse }
            let failed = try IndexedEVMIdentity.amount(message["receipt"]["exitCode"]) != "0"
            let from = try IndexedEVMIdentity.address(row["from"]["hash"].string ?? "")
            let to = try IndexedEVMIdentity.address(row["to"]["hash"].string ?? row["created_contract"]["hash"].string ?? "0x" + String(repeating: "0", count: 40))
            switch stream {
            case .transactions:
                let target: String
                if row["to"].isNull {
                    guard message["to"].string == "f010", message["method"].string == "CreateExternal" else { throw AnkrError.invalidResponse }
                    target = failed ? "0x" + String(repeating: "0", count: 40) : try createdAddress(message["receipt"]["return"])
                } else { target = try address(message["to"], id: message["toId"]) }
                guard try address(message["from"], id: message["fromId"]) == from,
                      target == to,
                      try IndexedEVMIdentity.amount(message["value"]) == IndexedEVMIdentity.amount(row["value"]),
                      row["status"].string == (failed ? "error" : "ok") else { throw AnkrError.invalidResponse }
                // Filecoin's actual charge includes the gas-limit based miner tip
                // and overestimation burn; rounded EVM gas prices lose precision.
                let fee = try ["baseFeeBurn", "overEstimationBurn", "minerTip"].reduce("0") {
                    try AptosIdentity.add($0, IndexedEVMIdentity.amount(message["fee"][$1]))
                }
                result["fee"] = .object(["type": .string("actual"), "value": .string(fee)])
            case .transfers, .internalTransactions:
                if stream == .internalTransactions,
                   (try? address(message["from"], id: message["fromId"])) == from,
                   (try? address(message["to"], id: message["toId"])) == to,
                   (try? IndexedEVMIdentity.amount(message["value"])) == (try? IndexedEVMIdentity.amount(row["value"])) {
                    guard row["success"] == .bool(!failed) else { throw AnkrError.invalidResponse }
                    // Lotus can expose the root transfer again as a trace.
                    // The transaction stream already owns this movement.
                    return nil
                }
                if stream == .internalTransactions, row["success"] == .bool(false), failed {
                    result["value"] = .string("0")
                    break
                }
                guard !failed else { throw AnkrError.invalidResponse }
                let transfers = try requiredArray(message[stream == .transfers ? "tokenTransfers" : "transfers"])
                let match = transfers.indices.first { index in
                    consumed[hash]?.contains(index) != true && Self.matches(row, transfer: transfers[index], stream: stream)
                }
                if let match { consumed[hash, default: []].insert(match) }
                else if stream == .internalTransactions {
                    guard let calls = message["archive_subcalls"].array else { throw AnkrError.invalidResponse }
                    let callKey = hash + ":calls"
                    let match = calls.indices.first { index in
                        guard consumed[callKey]?.contains(index) != true else { return false }
                        let call = calls[index]
                        let matchesFrom = (try? address(call["from"], id: call["fromId"])) == from
                            || (message["archive_actor_ids"][from].string != nil && call["fromId"].string == message["archive_actor_ids"][from].string)
                        let matchesTo = (try? address(call["to"], id: call["toId"])) == to
                            || (message["archive_actor_ids"][to].string != nil && call["toId"].string == message["archive_actor_ids"][to].string)
                        guard let status = try? IndexedEVMIdentity.amount(call["receipt"]["exitCode"]) else { return false }
                        return matchesFrom && matchesTo && row["success"] == .bool(status == "0" && call["archive_reverted"] != .bool(true))
                            && (try? IndexedEVMIdentity.amount(call["value"])) == (try? IndexedEVMIdentity.amount(row["value"]))
                    }
                    guard let match else { throw AnkrError.invalidResponse }
                    consumed[callKey, default: []].insert(match)
                } else {
                    guard let logs = message["archive_event_logs"].array else { throw AnkrError.invalidResponse }
                    let logKey = hash + ":logs"
                    let logMatch = logs.indices.first { index in
                        guard consumed[logKey]?.contains(index) != true, case .object(var log) = logs[index],
                              logs[index]["removed"] == .bool(false),
                              let contract = try? address(logs[index]["address"]) else { return false }
                        log["address"] = .string(contract)
                        if (try? IndexedEVMClient.verifyTransfer(row, log: .object(log), chain: .filecoin)) != nil { return true }
                        return matchesWrappedFIL(row, log: .object(log), transfers: message["transfers"].array ?? [])
                    }
                    guard let logMatch else { throw AnkrError.invalidResponse }
                    consumed[logKey, default: []].insert(logMatch)
                }
            }
            result["verification_source"] = .string("blockscout_filfox_archive")
            return .object(result)
        }
    }

    private static func matches(_ row: SolanaJSON, transfer: SolanaJSON, stream: IndexedEVMHistoryStream) -> Bool {
        guard let amount = try? IndexedEVMIdentity.amount(stream == .transfers ? row["total"]["value"] : row["value"]),
              (try? address(transfer["from"], id: transfer["fromId"])) == row["from"]["hash"].string?.lowercased(),
              (try? address(transfer["to"], id: transfer["toId"])) == row["to"]["hash"].string?.lowercased(),
              (try? IndexedEVMIdentity.amount(transfer["value"])) == amount else { return false }
        if stream == .internalTransactions { return transfer["type"].string == "transfer" && row["success"] == .bool(true) }
        return transfer["type"].string == "ERC20 Transfer"
            && (try? address(transfer["token"])) == row["token"]["address_hash"].string?.lowercased()
            && transfer["decimals"].text == row["token"]["decimals"].text
    }

    /// Older wrappers emit Deposit/Withdrawal without an ERC-20 Transfer.
    /// Require the matching native FIL movement, not a token name or ticker.
    static func matchesWrappedFIL(_ row: SolanaJSON, log: SolanaJSON, transfers: [SolanaJSON]) -> Bool {
        guard let contract = log["address"].string, contract == row["token"]["address_hash"].string?.lowercased(),
              let topics = log["topics"].array, topics.count == 2,
              let accountTopic = topics[1].string, accountTopic.count == 66,
              accountTopic.hasPrefix("0x" + String(repeating: "0", count: 24)),
              let amount = try? IndexedEVMIdentity.amount(log["data"]),
              (try? IndexedEVMIdentity.amount(row["total"]["value"])) == amount else { return false }
        let account = "0x" + accountTopic.suffix(40).lowercased(), zero = "0x" + String(repeating: "0", count: 40)
        let deposit = topics[0].string == "0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c"
        let withdrawal = topics[0].string == "0x7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b65"
        guard deposit || withdrawal,
              row["from"]["hash"].string?.lowercased() == (deposit ? zero : account),
              row["to"]["hash"].string?.lowercased() == (deposit ? account : zero) else { return false }
        return transfers.contains { transfer in
            transfer["type"].string == "transfer"
                && (try? address(transfer["from"], id: transfer["fromId"])) == (deposit ? account : contract)
                && (try? address(transfer["to"], id: transfer["toId"])) == (deposit ? contract : account)
                && (try? IndexedEVMIdentity.amount(transfer["value"])) == amount
        }
    }

    private static func requiredArray(_ value: SolanaJSON) throws -> [SolanaJSON] {
        guard let result = value.array, result.count <= 10_000 else { throw AnkrError.invalidResponse }
        return result
    }

    // The EAM CreateExternal return is the CBOR tuple
    // [actor_id, optional_robust_address, ethereum_address].
    static func createdAddress(_ value: SolanaJSON) throws -> String {
        guard let hex = value.string, hex.count <= 256 else { throw AnkrError.invalidResponse }
        let bytes = Array(try TronIdentity.hex(hex))
        var offset = 0
        func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw AnkrError.invalidResponse }
            defer { offset += 1 }; return bytes[offset]
        }
        func length(major: UInt8) throws -> UInt64 {
            let first = try byte(), info = first & 31
            guard first >> 5 == major else { throw AnkrError.invalidResponse }
            if info < 24 { return UInt64(info) }
            guard (24...27).contains(info) else { throw AnkrError.invalidResponse }
            let count = 1 << Int(info - 24)
            var result: UInt64 = 0
            for _ in 0..<count { result = (result << 8) | UInt64(try byte()) }
            let minimum: UInt64 = count == 1 ? 24 : UInt64(1) << ((count / 2) * 8)
            guard result >= minimum else { throw AnkrError.invalidResponse }
            return result
        }
        guard try length(major: 4) == 3, try length(major: 0) > 0 else { throw AnkrError.invalidResponse }
        if offset < bytes.count, bytes[offset] == 0xf6 { offset += 1 }
        else {
            guard try length(major: 2) == 21, try byte() == 2, offset + 20 <= bytes.count else { throw AnkrError.invalidResponse }
            offset += 20
        }
        guard try length(major: 2) == 20, offset + 20 == bytes.count else { throw AnkrError.invalidResponse }
        let address = "0x" + bytes[offset...].map { String(format: "%02x", $0) }.joined()
        _ = try FilecoinIdentity.delegated(address)
        return address
    }
}

private actor FilecoinArchiveReader {
    private let transport: any AnkrTransport
    private var nextStart = Date.distantPast
    private var cache: [String: (Date, SolanaJSON, Int)] = [:]
    private var flights: [String: Task<SolanaJSON, Error>] = [:]
    init(transport: any AnkrTransport) { self.transport = transport }

    func read(path: String, collection: String) async throws -> SolanaJSON {
        try Task.checkCancellation()
        let key = collection + "/" + path
        if let cached = cache[key], Date().timeIntervalSince(cached.0) < 600 { return cached.1 }
        if let flight = flights[key] {
            let value = try await flight.value
            try Task.checkCancellation()
            return value
        }
        let task = Task { try await fetch(path: path, collection: collection) }
        flights[key] = task
        defer { flights[key] = nil }
        let value = try await task.value
        let bytes = try JSONEncoder().encode(value).count
        cache[key] = (Date(), value, bytes)
        while cache.count > 256 || cache.values.reduce(0, { $0 + $1.2 }) > 16 * 1024 * 1024 {
            guard let oldest = cache.min(by: { $0.value.0 < $1.value.0 })?.key else { break }
            cache[oldest] = nil
        }
        try Task.checkCancellation()
        return value
    }

    private func fetch(path: String, collection: String) async throws -> SolanaJSON {
        var request = URLRequest(url: URL(string: "https://filfox.info/api/v1/")!.appendingPathComponent(collection).appendingPathComponent(path))
        request.timeoutInterval = 20
        request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
        for attempt in 0..<4 {
            let start = max(Date(), nextStart)
            nextStart = start.addingTimeInterval(0.55)
            try await Task.sleep(for: .seconds(max(0, start.timeIntervalSinceNow)))
            do {
                let (data, status) = try await transport.send(request)
                guard status == 200 else { throw AnkrError.http(status) }
                guard data.count <= 2 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
                let result = try JSONDecoder().decode(SolanaJSON.self, from: data)
                return result
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                OathDiagnostics.record(error, component: "history", operation: "filecoin_archive_read", context: ["chain": "filecoin", "source": "Filfox"])
                let retry: Bool
                switch error {
                case AnkrError.http(let status): retry = status == 429 || (500...599).contains(status)
                case AnkrError.transport: retry = true
                default: retry = false
                }
                guard retry && attempt < 3 else { throw error }
                try await Task.sleep(for: .seconds(2 << attempt))
            }
        }
        throw AnkrError.transport
    }

}
