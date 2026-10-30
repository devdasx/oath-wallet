import Foundation
import OathArtworkSource
import OathDiagnostics

/// Artwork only: no balances, decimals, verification status, or signing data
/// are taken from this endpoint. Public identities are matched exactly.
actor TokenBatchArtwork {
    private static let platforms = ["solana": "solana", "tron": "tron", "sui": "sui-network", "aptos": "aptos", "ton": "ton", "xrpl": "xrpl", "near": "near",
        "chiliz": "chiliz-chain", "filecoin": "filecoin", "sei": "sei-evm", "zerog": "0g", "iotex": "iotx"]
    private struct Entry { let source: String?; let expires: Date }
    private struct Flight { let id: UUID; let task: Task<Void, Never> }
    private var saved: [String: Entry] = [:]
    private var flights: [String: Flight] = [:]
    private let transport: any AnkrTransport
    private let permit = AnkrPermits(count: 1)
    private let spacing: Duration
    private var nextRequest = ContinuousClock.now
    private var retryAt = Date.distantPast
    init(transport: any AnkrTransport, spacing: Duration = .milliseconds(6100)) {
        self.transport = transport; self.spacing = spacing
    }

    func prefetch(_ entries: [TokenDiscoveryEntry]) {
        let now = Date()
        saved = saved.filter { $0.value.expires > now }
        guard now >= retryAt else { return } // Provider backpressure is not a new failure.
        var groups: [String: [String]] = [:], selected = Set<String>()
        for entry in entries.prefix(500) where Self.platforms[entry.network] != nil {
            let key = entry.id
            guard saved[key] == nil, flights[key] == nil, selected.insert(key).inserted,
                  selected.count + flights.count <= 512 else { continue }
            groups[entry.network, default: []].append(entry.reference)
        }
        for network in groups.keys.sorted() {
            let refs = groups[network]!
            for offset in stride(from: 0, to: refs.count, by: 30) {
                let batch = Array(refs[offset..<min(offset + 30, refs.count)])
                let id = UUID()
                let task = Task(priority: .utility) {
                    await OathDiagnostics.$operationID.withValue(id) {
                        await OathDiagnostics.$chain.withValue(network) { await self.load(network, refs: batch, id: id) }
                    }
                }
                for ref in batch { flights[network + ":" + ref] = Flight(id: id, task: task) }
            }
        }
    }

    func source(for entry: TokenDiscoveryEntry, cachedOnly: Bool) async -> String? {
        if let cached = saved[entry.id], cached.expires > Date() { return cached.source }
        guard !cachedOnly, Self.platforms[entry.network] != nil else { return nil }
        prefetch([entry])
        if let flight = flights[entry.id] { await flight.task.value }
        return saved[entry.id].flatMap { $0.expires > Date() ? $0.source : nil }
    }

    private func load(_ network: String, refs: [String], id: UUID) async {
        defer {
            for ref in refs where flights[network + ":" + ref]?.id == id { flights[network + ":" + ref] = nil }
        }
        do {
            try await permit.acquire()
            defer { Task { await permit.release() } }
            guard Date() >= retryAt else { return }
            if nextRequest > .now { try await Task.sleep(until: nextRequest, clock: .continuous) }
            try Task.checkCancellation()
            nextRequest = ContinuousClock.now.advanced(by: spacing)
            let platform = Self.platforms[network]!
            let base = URL(string: "https://api.geckoterminal.com/api/v2/networks/\(platform)/tokens/multi")!
            var request = URLRequest(url: base.appendingPathComponent(refs.joined(separator: ",")))
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, status) = try await transport.send(request)
            DiagnosticHTTP.response(data, status: status, request: request)
            guard status == 200 else { throw TokenDiscoveryError.http(status) }
            let images = try Self.decode(data, network: network, requested: Set(refs))
            // Missing optional artwork is cached briefly; it is not a failure.
            for ref in refs {
                let key = network + ":" + ref
                if saved[key] == nil, saved.count >= 512,
                   let oldest = saved.min(by: { $0.value.expires < $1.value.expires })?.key { saved[oldest] = nil }
                saved[key] = Entry(source: images[ref], expires: Date().addingTimeInterval(images[ref] == nil ? 300 : 86400))
            }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            OathDiagnostics.record(error, component: "artwork", operation: "batch_metadata", context: ["chain": network, "host": "api.geckoterminal.com"])
            retryAt = Date().addingTimeInterval(60)
        }
    }

    static func decode(_ data: Data, network: String, requested: Set<String>) throws -> [String: String] {
        struct Envelope: Decodable {
            struct Row: Decodable {
                struct Attributes: Decodable { let address: String; let image_url: String? }
                let id: String; let type: String; let attributes: Attributes
            }
            let data: [Row]
        }
        guard data.count <= 2_000_000, requested.count <= 30, let platform = platforms[network] else { throw TokenDiscoveryError.malformed }
        let rows = try JSONDecoder().decode(Envelope.self, from: data).data
        guard rows.count <= requested.count else { throw TokenDiscoveryError.malformed }
        var result: [String: String] = [:], seen = Set<String>()
        for row in rows {
            let ref = try TokenDiscoveryNetworks.canonical(row.attributes.address, network: network)
            guard row.type == "token", row.id == platform + "_" + row.attributes.address,
                  requested.contains(ref), seen.insert(ref).inserted else { throw TokenDiscoveryError.malformed }
            guard let image = row.attributes.image_url, image.utf8.count <= 2048,
                  let source = ArtworkSource.normalized(image), source.hasPrefix("https://") else { continue }
            result[ref] = source
        }
        return result
    }
}
