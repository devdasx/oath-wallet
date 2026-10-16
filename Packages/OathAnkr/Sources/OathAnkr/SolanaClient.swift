import OathDiagnostics
import Foundation

/// Standard Solana JSON-RPC on the paid Ankr endpoint. Advanced API is EVM-only.
/// Every batch maps replies by ID, checks every member, and preserves exact integers.
public actor SolanaClient {
    private let primary: URL
    private let archive: URL
    private let transport: any AnkrTransport
    private let permits = AnkrPermits(count: 3)
    private let archivePermits = AnkrPermits(count: 1)
    private var verified: Set<URL> = []
    private var archiveAfter = ContinuousClock.now
    private var archiveSpacingMilliseconds = 1200
    public init(apiKey: String, transport: any AnkrTransport = AnkrHTTPTransport(),
                archive: URL = URL(string: "https://api.mainnet-beta.solana.com")!) throws {
        guard !apiKey.isEmpty, apiKey.count <= 256, apiKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              archive.scheme == "https" else { throw SolanaError.configuration }
        primary = URL(string: "https://rpc.ankr.com/solana")!.appendingPathComponent(apiKey)
        self.archive = archive; self.transport = transport
    }
    private struct Call: Sendable { let method: String; let params: [SolanaJSON] }
    private func batch(_ calls: [Call], endpoint: URL) async throws -> [Result<SolanaJSON, SolanaError>] {
        guard !calls.isEmpty, calls.count <= 20 else { throw SolanaError.malformed }
        let gate = endpoint == archive ? archivePermits : permits
        try await gate.acquire()
        do {
            let result = try await exchange(calls, endpoint: endpoint)
            await gate.release(); return result
        } catch { OathDiagnostics.record(error); await gate.release(); throw error }
    }
    private func exchange(_ calls: [Call], endpoint: URL) async throws -> [Result<SolanaJSON, SolanaError>] {
        var pending = Array(calls.indices)
        var completed: [Int: Result<SolanaJSON, SolanaError>] = [:]
        for attempt in 0..<3 {
            try Task.checkCancellation()
            // Pace every attempt, including partial retries. If the archive
            // throttles a member, lower concurrency's effective request rate
            // for subsequent pages instead of repeatedly hitting the same limit.
            if endpoint == archive {
                let wait = archiveAfter - .now
                if wait > .zero { try await Task.sleep(for: wait) }
                archiveAfter = .now.advanced(by: .milliseconds(max(1200, pending.count * archiveSpacingMilliseconds)))
            }
            // HTTP 200 does not mean every member succeeded. Keep successful
            // replies and retry only rate-limited members, retaining their IDs.
            let requests = pending.map { i in SolanaJSON.object([
                "jsonrpc": .string("2.0"), "id": .number(String(i + 1)),
                "method": .string(calls[i].method), "params": .array(calls[i].params)]) }
            var request = URLRequest(url: endpoint)
            // A stalled primary must yield to the independent provider, not
            // occupy a refresh for three URLSession timeout windows.
            request.timeoutInterval = endpoint == primary ? 8 : 15
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(requests.count == 1 ? requests[0] : .array(requests))
            do {
                let (data, status) = try await transport.send(request)
                guard status == 200 else { throw SolanaError.http(status) }
                let root = try JSONDecoder().decode(SolanaJSON.self, from: data)
                let values = requests.count == 1 ? [root] : (root.array ?? [])
                guard values.count == requests.count else { throw SolanaError.malformed }
                var replies: [Int: Result<SolanaJSON, SolanaError>] = [:]
                for value in values {
                    guard value["jsonrpc"].string == "2.0", let id = value["id"].integer,
                          id <= UInt64(calls.count), id > 0, pending.contains(Int(id) - 1),
                          replies[Int(id)] == nil else { throw SolanaError.malformed }
                    if !value["error"].isNull {
                        guard case .number(let code) = value["error"]["code"], let code = Int(code) else { throw SolanaError.malformed }
                        replies[Int(id)] = .failure(.rpc(code))
                    } else {
                        guard case .object(let object) = value, object["result"] != nil else { throw SolanaError.malformed }
                        replies[Int(id)] = .success(value["result"])
                    }
                }
                var retry: [Int] = []
                for index in pending {
                    let result = replies[index + 1]!
                    if attempt < 2, case .failure(.rpc(let code)) = result,
                       [429, -32005, -32016, -32429].contains(code) {
                        if endpoint == archive, code == 429 || code == -32429 {
                            archiveSpacingMilliseconds = 1500
                            archiveAfter = .now.advanced(by: .seconds(15))
                        }
                        retry.append(index)
                    } else { completed[index] = result }
                }
                pending = retry
            } catch { OathDiagnostics.record(error);
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                let safe = error as? SolanaError ?? .transport
                if endpoint == archive, safe == .http(429) {
                    archiveSpacingMilliseconds = 1500
                    archiveAfter = .now.advanced(by: .seconds(15))
                }
                switch safe {
                case .http(429), .http(500...599), .transport:
                    if endpoint == primary || attempt == 2 {
                        for index in pending { completed[index] = .failure(safe) }
                        pending = []
                    }
                default: throw safe
                }
            }
            if pending.isEmpty { return calls.indices.map { completed[$0]! } }
            try await Task.sleep(for: .seconds(endpoint == archive ? 5 << attempt : 1 << attempt))
        }
        throw SolanaError.transport
    }
    private func verify(_ endpoint: URL) async throws {
        if verified.contains(endpoint) { return }
        let result = try await batch([.init(method: "getGenesisHash", params: [])], endpoint: endpoint)[0].get()
        guard result.string == SolanaIdentity.genesis else { throw SolanaError.wrongNetwork }
        verified.insert(endpoint)
    }
    private func primaryResults(_ calls: [Call]) async throws -> [SolanaJSON] {
        try await verify(primary)
        return try await batch(calls, endpoint: primary).map { try $0.get() }
    }
    public func inventory(owner: String) async throws -> SolanaInventory {
        guard SolanaIdentity.isAddress(owner) else { throw SolanaError.invalidAddress }
        let config: SolanaJSON = .object(["commitment": .string("confirmed"), "encoding": .string("jsonParsed")])
        let calls = [Call(method: "getBalance", params: [.string(owner), .object(["commitment": .string("confirmed")])])] +
            [SolanaIdentity.tokenProgram, SolanaIdentity.token2022Program].map {
                Call(method: "getTokenAccountsByOwner", params: [.string(owner), .object(["programId": .string($0)]), config]) }
        let values: [SolanaJSON]
        do { values = try await primaryResults(calls) }
        catch { OathDiagnostics.record(error);
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            try await verify(archive)
            // Public RPCs often reject indexed methods inside large batches.
            var fallback: [SolanaJSON] = []
            for call in calls { fallback.append(try await batch([call], endpoint: archive)[0].get()) }
            values = fallback
        }
        return try SolanaDecoding.inventory(owner: owner, values: values)
    }
    public func signatures(address: String, before: String? = nil, until: String? = nil, limit: Int = 100) async throws -> SolanaSignaturePage {
        guard SolanaIdentity.isAddress(address), (1...1000).contains(limit),
              before.map(SolanaIdentity.isSignature) ?? true, until.map(SolanaIdentity.isSignature) ?? true else { throw SolanaError.invalidAddress }
        var config: [String: SolanaJSON] = ["commitment": .string("finalized"), "limit": .number(String(limit))]
        if let before { config["before"] = .string(before) }
        if let until { config["until"] = .string(until) }
        let call = Call(method: "getSignaturesForAddress", params: [.string(address), .object(config)])
        // Always use the archive for cursor enumeration. Ankr can return []
        // beyond its retention window without saying that history was pruned.
        do {
            try await verify(archive)
            let value = try await batch([call], endpoint: archive)[0].get()
            return .init(signatures: try SolanaDecoding.signatures(value), archival: true)
        } catch { OathDiagnostics.record(error);
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            let value = try await primaryResults([call])[0]
            return .init(signatures: try SolanaDecoding.signatures(value), archival: false)
        }
    }
    public func transactions(signatures: [String], owner: String) async throws -> [SolanaTransaction] {
        guard signatures.count <= 20, !signatures.isEmpty, Set(signatures).count == signatures.count,
              signatures.allSatisfy(SolanaIdentity.isSignature), SolanaIdentity.isAddress(owner) else { throw SolanaError.invalidAddress }
        let calls = signatures.map { Call(method: "getTransaction", params: [.string($0), .object([
            "commitment": .string("finalized"), "encoding": .string("jsonParsed"), "maxSupportedTransactionVersion": SolanaTransactionRead.maximumVersion])]) }
        var replies: [Result<SolanaJSON, SolanaError>]
        do { try await verify(primary); replies = try await batch(calls, endpoint: primary) }
        catch { OathDiagnostics.record(error); if error is CancellationError { throw error }; try Task.checkCancellation(); replies = calls.map { _ in .failure(.transport) } }
        let missing = replies.indices.filter {
            if case .success(let value) = replies[$0], !value.isNull { return false }; return true
        }
        if !missing.isEmpty { try await verify(archive) }
        // The public archive counts each member against its method quota.
        // A five-member batch was a burst even when HTTP requests were paced.
        // Preserve paid-primary batching, but spread fallback members over time.
        for index in missing {
            replies[index] = try await batch([calls[index]], endpoint: archive)[0]
        }
        var result: [SolanaTransaction] = []
        for i in replies.indices {
            let value = try replies[i].get()
            guard !value.isNull else { throw SolanaError.missingTransaction }
            result.append(try SolanaDecoding.transaction(value, signature: signatures[i], owner: owner))
        }
        return result
    }
}
