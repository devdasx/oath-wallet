import Foundation
import OathDiagnostics

/// Recovery for immutable Bitcoin transaction bytes when Electrum peers have
/// pruned/missing data. Every response is parsed and hash checked before use.
actor BitcoinTransactionFallback {
    static let shared = BitcoinTransactionFallback()
    typealias Fetch = @Sendable (URLRequest) async throws -> Data
    private let fetch: Fetch
    private var active = 0
    init(fetch: @escaping Fetch = { request in
        let (data, response) = try await DiagnosticHTTP.boundedData(for: request, session: .shared, maximumBytes: 4_000_000)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let data else { throw BitcoinError.invalidResponse }
        return data
    }) { self.fetch = fetch }

    func transactions(txids: [String]) async throws -> [String: Data] {
        guard txids.count <= 40, Set(txids).count == txids.count,
              txids.allSatisfy({ $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) else {
            throw BitcoinError.invalidResponse
        }
        return try await withThrowingTaskGroup(of: (String, Data).self) { group in
            var next = 0, output: [String: Data] = [:]
            func enqueue() {
                guard next < txids.count else { return }
                let hash = txids[next]; next += 1
                group.addTask { (hash, try await self.transaction(hash)) }
            }
            for _ in 0..<min(4, txids.count) { enqueue() }
            for try await (hash, data) in group { output[hash] = data; enqueue() }
            return output
        }
    }
    private func transaction(_ hash: String) async throws -> Data {
        // Shared across batches/accounts so an archive outage cannot create a
        // fan-out of hundreds of parallel HTTP requests.
        while active >= 4 { try await Task.sleep(for: .milliseconds(20)) }
        try Task.checkCancellation(); active += 1
        defer { active -= 1 }
        for host in ["blockstream.info", "mempool.space"] {
            do {
                let request = URLRequest(url: URL(string: "https://\(host)/api/tx/\(hash)/raw")!,
                                         cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
                let data = try await fetch(request)
                try Task.checkCancellation()
                guard data.count <= 4_000_000, try BitcoinTransactions.txid(data) == hash else { throw BitcoinError.invalidResponse }
                return data
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                OathDiagnostics.record(error, component: "electrum", operation: "transaction_http_fallback",
                    context: ["chain": "bitcoin", "host": host])
            }
        }
        throw BitcoinError.unavailable
    }
}
