import CryptoKit
import Foundation
import Network

struct BitcoinFamilyElectrumBatchValue: Sendable {
    let parameter: String
    let value: JSONValue
}

private func bitcoinFamilyElectrumBatchParameters(
    chain: BitcoinFamilyChain,
    method: String,
    parameter: String
) throws -> [AnyEncodable] {
    switch method {
    case "blockchain.scripthash.listunspent" where chain == .bitcoinCash:
        // Native BCH sends must never consume a CashTokens-bearing output.
        return [AnyEncodable(parameter), AnyEncodable("exclude_tokens")]
    case "blockchain.transaction.get":
        // Request raw hex explicitly. Several Electrum implementations return
        // a verbose object when the second parameter is omitted.
        return [AnyEncodable(parameter), AnyEncodable(false)]
    case "blockchain.block.header":
        guard let height = Int64(parameter) else {
            throw BitcoinFamilyElectrumError.invalidResponse
        }
        return [AnyEncodable(height)]
    default:
        return [AnyEncodable(parameter)]
    }
}

extension BitcoinFamilyElectrumClient {
    nonisolated static let maximumPipelinedRequestCount = 64

    func callStringParameterBatch(
        chain: BitcoinFamilyChain,
        method: String,
        parameters: [String],
        maximumResponseBytes: Int = 1_048_576
    ) async throws -> [BitcoinFamilyElectrumBatchValue] {
        guard !parameters.isEmpty else { return [] }
        do {
            return try await BitcoinFamilyElectrumBatchCoordinator.shared
                .call(
                    chain: chain,
                    method: method,
                    parameters: parameters,
                    maximumResponseBytes: maximumResponseBytes
                )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await callCompatibilityBatch(
                chain: chain,
                method: method,
                parameters: parameters,
                maximumResponseBytes: maximumResponseBytes
            )
        }
    }

    func prewarmBalanceConnections() async {
        await BitcoinFamilyElectrumBatchCoordinator.shared
            .prewarmBalanceConnections()
    }

    private func callCompatibilityBatch(
        chain: BitcoinFamilyChain,
        method: String,
        parameters: [String],
        maximumResponseBytes: Int
    ) async throws -> [BitcoinFamilyElectrumBatchValue] {
        var output: [BitcoinFamilyElectrumBatchValue] = []
        output.reserveCapacity(parameters.count)
        var start = 0
        while start < parameters.count {
            try Task.checkCancellation()
            let end = min(
                start + Self.maximumPipelinedRequestCount,
                parameters.count
            )
            let chunk = Array(parameters[start..<end])
            let values = try await withThrowingTaskGroup(
                of: (Int, BitcoinFamilyElectrumBatchValue).self
            ) { group in
                for (index, parameter) in chunk.enumerated() {
                    group.addTask {
                        let value = try await self.call(
                            chain: chain,
                            method: method,
                            params: try bitcoinFamilyElectrumBatchParameters(
                                chain: chain,
                                method: method,
                                parameter: parameter
                            ),
                            maximumResponseBytes: maximumResponseBytes
                        )
                        return (
                            index,
                            BitcoinFamilyElectrumBatchValue(
                                parameter: parameter,
                                value: value
                            )
                        )
                    }
                }
                var indexed: [(Int, BitcoinFamilyElectrumBatchValue)] = []
                indexed.reserveCapacity(chunk.count)
                while let value = try await group.next() {
                    indexed.append(value)
                }
                return indexed.sorted { $0.0 < $1.0 }.map(\.1)
            }
            output.append(contentsOf: values)
            start = end
        }
        return output
    }
}

private actor BitcoinFamilyElectrumBatchCoordinator {
    private struct IndexedChunk: Sendable {
        let start: Int
        let parameters: [String]
    }

    private struct IndexedValues: Sendable {
        let start: Int
        let values: [BitcoinFamilyElectrumBatchValue]
    }

    private struct Policy: Sendable {
        let chunkSize: Int
        let activeWorkerCount: Int
        let framing: BitcoinFamilyElectrumBatchFraming
    }

    static let shared = BitcoinFamilyElectrumBatchCoordinator()

    private var workers: [
        BitcoinFamilyChain: [BitcoinFamilyElectrumBatchWorker]
    ] = [:]
    private var nextBitcoinWorkerIndex = 0

    func prewarmBalanceConnections() async {
        var targets: [BitcoinFamilyElectrumBatchWorker] = []
        for chain in BitcoinFamilyChain.allCases {
            let available = workers(for: chain)
            let targetCount = chain == .bitcoin
                ? min(3, available.count) : min(1, available.count)
            targets.append(contentsOf: available.prefix(targetCount))
        }
        await withTaskGroup(of: Void.self) { group in
            for worker in targets {
                group.addTask { await worker.prewarmBalanceConnection() }
            }
            await group.waitForAll()
        }
        nextBitcoinWorkerIndex = 0
    }

    func call(
        chain: BitcoinFamilyChain,
        method: String,
        parameters: [String],
        maximumResponseBytes: Int
    ) async throws -> [BitcoinFamilyElectrumBatchValue] {
        let availableWorkers = workers(for: chain)
        guard !availableWorkers.isEmpty else {
            throw BitcoinFamilyElectrumError.unavailable
        }
        let policy = Self.policy(for: method)
        let activeCount = min(
            policy.activeWorkerCount,
            availableWorkers.count
        )
        let startingWorkerIndex: Int
        if chain == .bitcoin {
            startingWorkerIndex = nextBitcoinWorkerIndex % activeCount
            nextBitcoinWorkerIndex = (startingWorkerIndex + 1) % activeCount
        } else {
            startingWorkerIndex = 0
        }
        let chunks = stride(
            from: 0,
            to: parameters.count,
            by: policy.chunkSize
        ).map { start in
            IndexedChunk(
                start: start,
                parameters: Array(
                    parameters[
                        start..<min(start + policy.chunkSize, parameters.count)
                    ]
                )
            )
        }
        let values = try await withThrowingTaskGroup(
            of: [IndexedValues].self
        ) { group in
            for lane in 0..<activeCount {
                group.addTask {
                    var laneValues: [IndexedValues] = []
                    var chunkIndex = lane
                    while chunkIndex < chunks.count {
                        try Task.checkCancellation()
                        let chunk = chunks[chunkIndex]
                        let primaryIndex = (
                            startingWorkerIndex + chunkIndex
                        ) % activeCount
                        var finalError: Error?
                        var completed: IndexedValues?
                        for offset in 0..<availableWorkers.count {
                            let worker = availableWorkers[
                                (primaryIndex + offset)
                                    % availableWorkers.count
                            ]
                            do {
                                let result = try await worker.callAdaptive(
                                    method: method,
                                    parameters: chunk.parameters,
                                    framing: policy.framing,
                                    maximumResponseBytes: maximumResponseBytes
                                )
                                completed = IndexedValues(
                                    start: chunk.start,
                                    values: zip(
                                        chunk.parameters,
                                        result
                                    ).map {
                                        BitcoinFamilyElectrumBatchValue(
                                            parameter: $0.0,
                                            value: $0.1
                                        )
                                    }
                                )
                                break
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                finalError = error
                            }
                        }
                        guard let completed else {
                            throw finalError
                                ?? BitcoinFamilyElectrumError.unavailable
                        }
                        laneValues.append(
                            IndexedValues(
                                start: chunk.start,
                                values: completed.values
                            )
                        )
                        chunkIndex += activeCount
                    }
                    return laneValues
                }
            }
            var indexed: [IndexedValues] = []
            indexed.reserveCapacity(chunks.count)
            while let value = try await group.next() {
                indexed.append(contentsOf: value)
            }
            return indexed
        }
        return values.sorted { $0.start < $1.start }.flatMap(\.values)
    }

    private func workers(
        for chain: BitcoinFamilyChain
    ) -> [BitcoinFamilyElectrumBatchWorker] {
        if let existing = workers[chain] { return existing }
        let created = chain.batchScanEndpoints.map {
            BitcoinFamilyElectrumBatchWorker(
                chain: chain,
                endpoint: $0
            )
        }
        workers[chain] = created
        return created
    }

    private nonisolated static func policy(for method: String) -> Policy {
        switch method {
        case "blockchain.scripthash.get_balance":
            Policy(
                chunkSize: 512,
                activeWorkerCount: 3,
                framing: .packedNewlines
            )
        case "blockchain.scripthash.get_history":
            Policy(
                chunkSize: 10,
                activeWorkerCount: 3,
                framing: .jsonArray
            )
        case "blockchain.scripthash.listunspent":
            Policy(
                chunkSize: 20,
                activeWorkerCount: 3,
                framing: .jsonArray
            )
        case "blockchain.transaction.get":
            Policy(
                chunkSize: 20,
                activeWorkerCount: 3,
                framing: .jsonArray
            )
        case "blockchain.block.header":
            Policy(
                chunkSize: 100,
                activeWorkerCount: 3,
                framing: .packedNewlines
            )
        default:
            Policy(
                chunkSize: 50,
                activeWorkerCount: 3,
                framing: .jsonArray
            )
        }
    }
}

private enum BitcoinFamilyElectrumBatchFraming: Sendable {
    case jsonArray
    case packedNewlines
}

private struct BitcoinFamilyElectrumBatchEndpoint: Hashable, Sendable {
    let host: String
    let port: UInt16
}

private extension BitcoinFamilyChain {
    var batchScanEndpoints: [BitcoinFamilyElectrumBatchEndpoint] {
        switch self {
        case .bitcoin:
            Array(
                repeating: BitcoinFamilyElectrumBatchEndpoint(
                    host: "bitcoin.stackwallet.com", port: 50002
                ),
                count: 3
            ) + [
                BitcoinFamilyElectrumBatchEndpoint(
                    host: "fulcrum.grey.pw",
                    port: 51002
                ),
                BitcoinFamilyElectrumBatchEndpoint(
                    host: "e.keff.org",
                    port: 50002
                ),
                BitcoinFamilyElectrumBatchEndpoint(
                    host: "e2.keff.org",
                    port: 50002
                ),
                BitcoinFamilyElectrumBatchEndpoint(
                    host: "f.keff.org",
                    port: 50002
                ),
                BitcoinFamilyElectrumBatchEndpoint(
                    host: "electrum.petrkr.net",
                    port: 50002
                )
            ]
        case .bitcoinCash:
            Array(
                repeating: BitcoinFamilyElectrumBatchEndpoint(
                    host: "bch.loping.net", port: 50002
                ),
                count: 3
            ) + [
                BitcoinFamilyElectrumBatchEndpoint(
                    host: "bch.imaginary.cash", port: 50002
                ),
                BitcoinFamilyElectrumBatchEndpoint(
                    host: "bch.cyberbits.eu", port: 50002
                )
            ]
        case .litecoin:
            Array(
                repeating: BitcoinFamilyElectrumBatchEndpoint(
                    host: "electrum1.cipig.net", port: 20063
                ),
                count: 3
            ) + [
                BitcoinFamilyElectrumBatchEndpoint(
                    host: "electrum2.cipig.net", port: 20063
                ),
                BitcoinFamilyElectrumBatchEndpoint(
                    host: "litecoin.stackwallet.com", port: 20063
                )
            ]
        case .dogecoin:
            Array(
                repeating: BitcoinFamilyElectrumBatchEndpoint(
                    host: "electrum1.cipig.net", port: 20060
                ),
                count: 3
            ) + [
                BitcoinFamilyElectrumBatchEndpoint(
                    host: "electrum2.cipig.net", port: 20060
                ),
                BitcoinFamilyElectrumBatchEndpoint(
                    host: "dogecoin.stackwallet.com", port: 50022
                )
            ]
        }
    }
}

private actor BitcoinFamilyElectrumBatchPermit {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}

private actor BitcoinFamilyElectrumBatchWorker {
    private let chain: BitcoinFamilyChain
    private let endpoint: BitcoinFamilyElectrumBatchEndpoint
    private let permit = BitcoinFamilyElectrumBatchPermit()
    private var connection: BitcoinFamilyElectrumBatchConnection?
    private var isVerified = false
    private var nextRequestID = 1

    init(
        chain: BitcoinFamilyChain,
        endpoint: BitcoinFamilyElectrumBatchEndpoint
    ) {
        self.chain = chain
        self.endpoint = endpoint
    }

    func prewarmBalanceConnection() async {
        _ = try? await callAdaptive(
            method: "blockchain.scripthash.get_balance",
            parameters: [String(repeating: "0", count: 64)],
            framing: .packedNewlines,
            maximumResponseBytes: 1_048_576
        )
    }

    func callAdaptive(
        method: String,
        parameters: [String],
        framing: BitcoinFamilyElectrumBatchFraming,
        maximumResponseBytes: Int
    ) async throws -> [JSONValue] {
        await permit.acquire()
        do {
            try Task.checkCancellation()
            let result = try await callAdaptiveWithPermit(
                method: method,
                parameters: parameters,
                framing: framing,
                maximumResponseBytes: maximumResponseBytes
            )
            await permit.release()
            return result
        } catch {
            await permit.release()
            throw error
        }
    }

    private func callAdaptiveWithPermit(
        method: String,
        parameters: [String],
        framing: BitcoinFamilyElectrumBatchFraming,
        maximumResponseBytes: Int
    ) async throws -> [JSONValue] {
        do {
            return try await call(
                method: method,
                parameters: parameters,
                framing: framing,
                maximumResponseBytes: maximumResponseBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BitcoinFamilyElectrumError {
            switch error {
            case let .rpc(code, message)
                where Self.isBatchLimit(code: code, message: message):
                return try await split(
                    error: error,
                    method: method,
                    parameters: parameters,
                    framing: framing,
                    maximumResponseBytes: maximumResponseBytes
                )
            case .responseTooLarge:
                resetConnection()
                return try await split(
                    error: error,
                    method: method,
                    parameters: parameters,
                    framing: framing,
                    maximumResponseBytes: maximumResponseBytes
                )
            default:
                throw error
            }
        }
    }

    private func split(
        error: Error,
        method: String,
        parameters: [String],
        framing: BitcoinFamilyElectrumBatchFraming,
        maximumResponseBytes: Int
    ) async throws -> [JSONValue] {
        guard parameters.count > 1 else { throw error }
        let midpoint = parameters.count / 2
        let left = try await callAdaptiveWithPermit(
            method: method,
            parameters: Array(parameters[..<midpoint]),
            framing: framing,
            maximumResponseBytes: maximumResponseBytes
        )
        let right = try await callAdaptiveWithPermit(
            method: method,
            parameters: Array(parameters[midpoint...]),
            framing: framing,
            maximumResponseBytes: maximumResponseBytes
        )
        return left + right
    }

    private func call(
        method: String,
        parameters: [String],
        framing: BitcoinFamilyElectrumBatchFraming,
        maximumResponseBytes: Int
    ) async throws -> [JSONValue] {
        let connection = connection ?? makeConnection()
        do {
            try await verifyIfNeeded(connection)
            let requests = try parameters.map { parameter in
                makeRequest(
                    method: method,
                    params: try bitcoinFamilyElectrumBatchParameters(
                        chain: chain,
                        method: method,
                        parameter: parameter
                    )
                )
            }
            let payload = try Self.encode(
                requests: requests,
                framing: framing
            )
            return try await connection.request(
                ids: requests.map(\.id),
                payload: payload,
                maximumResponseBytes: Self.totalResponseLimit(
                    perResponse: maximumResponseBytes,
                    count: requests.count
                ),
                timeoutSeconds: Self.timeoutSeconds(for: method)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            resetConnection()
            throw error
        }
    }

    private func verifyIfNeeded(
        _ connection: BitcoinFamilyElectrumBatchConnection
    ) async throws {
        guard !isVerified else { return }
        let negotiation = makeRequest(
            method: "server.version",
            params: [
                AnyEncodable("Aperture"),
                AnyEncodable("1.4")
            ]
        )
        let headerRequest = makeRequest(
            method: "blockchain.block.header",
            params: [AnyEncodable(0)]
        )
        let verification = try await connection.request(
            ids: [negotiation.id, headerRequest.id],
            payload: try Self.encode(
                requests: [negotiation, headerRequest],
                framing: .packedNewlines
            ),
            maximumResponseBytes: 262_144,
            timeoutSeconds: 8
        )
        guard verification.count == 2,
              verification[0].array?.count == 2,
              let hex = verification[1].string,
              let header = Data(bitcoinHex: hex),
              header.count >= 80 else {
            throw BitcoinFamilyElectrumError.invalidResponse
        }
        let first = Data(SHA256.hash(data: header.prefix(80)))
        let hash = Data(SHA256.hash(data: first)).reversed()
            .map { String(format: "%02x", $0) }.joined()
        guard hash == chain.genesisHash else {
            throw BitcoinFamilyElectrumError.invalidResponse
        }
        isVerified = true
    }

    private func makeRequest(
        method: String,
        params: [AnyEncodable]
    ) -> ElectrumRequest {
        defer { nextRequestID += 1 }
        return ElectrumRequest(
            id: nextRequestID,
            method: method,
            params: params
        )
    }

    private func makeConnection() -> BitcoinFamilyElectrumBatchConnection {
        let created = BitcoinFamilyElectrumBatchConnection(
            host: endpoint.host,
            port: endpoint.port
        )
        connection = created
        return created
    }

    private func resetConnection() {
        connection?.invalidate()
        connection = nil
        isVerified = false
    }

    private nonisolated static func encode(
        requests: [ElectrumRequest],
        framing: BitcoinFamilyElectrumBatchFraming
    ) throws -> Data {
        let encoder = JSONEncoder()
        switch framing {
        case .jsonArray:
            var payload = try encoder.encode(requests)
            payload.append(0x0a)
            return payload
        case .packedNewlines:
            var payload = Data()
            for request in requests {
                payload.append(try encoder.encode(request))
                payload.append(0x0a)
            }
            return payload
        }
    }

    private nonisolated static func totalResponseLimit(
        perResponse: Int,
        count: Int
    ) -> Int {
        let multiplied = perResponse.multipliedReportingOverflow(by: count)
        let requested = multiplied.overflow ? Int.max : multiplied.partialValue
        return min(max(requested, 16_384), 32 * 1_048_576)
    }

    private nonisolated static func timeoutSeconds(
        for method: String
    ) -> Double {
        switch method {
        case "blockchain.scripthash.get_balance": 12
        case "blockchain.scripthash.get_history",
             "blockchain.scripthash.listunspent": 20
        default: 15
        }
    }

    private nonisolated static func isBatchLimit(
        code: Int,
        message: String
    ) -> Bool {
        code == 4
            || message.localizedCaseInsensitiveContains("batch limit")
            || message.localizedCaseInsensitiveContains(
                "batch request timed out"
            )
            || message.localizedCaseInsensitiveContains("too many requests")
    }
}

private final class BitcoinFamilyElectrumBatchConnection: @unchecked Sendable {
    private struct PendingRequest {
        let token: UUID
        let ids: [Int]
        let payload: Data
        let maximumResponseBytes: Int
        let continuation: CheckedContinuation<[JSONValue], Error>
        var values: [Int: JSONValue]
        var receivedResponseBytes: Int
        var wasSent: Bool
    }

    private enum State {
        case idle
        case connecting
        case ready
        case closed
    }

    private let queue = DispatchQueue(
        label: "com.aperture.wallet.electrum.batch",
        qos: .userInitiated
    )
    private let connection: NWConnection
    private var state = State.idle
    private var pending: PendingRequest?
    private var buffer = Data()
    private var isReceiving = false

    init(host: String, port: UInt16) {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 15
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3
        let parameters = NWParameters(
            tls: NWProtocolTLS.Options(),
            tcp: tcpOptions
        )
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
    }

    func request(
        ids: [Int],
        payload: Data,
        maximumResponseBytes: Int,
        timeoutSeconds: Double
    ) async throws -> [JSONValue] {
        try Task.checkCancellation()
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.state != .closed else {
                        continuation.resume(
                            throwing: BitcoinFamilyElectrumError.unavailable
                        )
                        return
                    }
                    guard self.pending == nil,
                          !ids.isEmpty,
                          Set(ids).count == ids.count,
                          maximumResponseBytes > 0 else {
                        continuation.resume(
                            throwing: BitcoinFamilyElectrumError.invalidResponse
                        )
                        return
                    }
                    self.pending = PendingRequest(
                        token: token,
                        ids: ids,
                        payload: payload,
                        maximumResponseBytes: maximumResponseBytes,
                        continuation: continuation,
                        values: [:],
                        receivedResponseBytes: 0,
                        wasSent: false
                    )
                    self.startIfNeeded()
                    self.sendIfReady()
                    self.queue.asyncAfter(
                        deadline: .now() + timeoutSeconds
                    ) {
                        self.timeout(token: token)
                    }
                }
            }
        } onCancel: {
            self.queue.async {
                self.complete(
                    token: token,
                    result: .failure(CancellationError())
                )
            }
        }
    }

    func invalidate() {
        queue.async {
            self.failAndClose(BitcoinFamilyElectrumError.unavailable)
        }
    }

    private func startIfNeeded() {
        guard state == .idle else { return }
        state = .connecting
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            self.queue.async {
                switch newState {
                case .ready:
                    guard self.state != .closed else { return }
                    self.state = .ready
                    self.sendIfReady()
                    self.receiveIfNeeded()
                case let .failed(error):
                    self.failAndClose(error)
                case .cancelled:
                    if self.state != .closed {
                        self.failAndClose(
                            BitcoinFamilyElectrumError.unavailable
                        )
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func sendIfReady() {
        guard state == .ready,
              var request = pending,
              !request.wasSent else { return }
        request.wasSent = true
        pending = request
        connection.send(
            content: request.payload,
            completion: .contentProcessed { [weak self] error in
                guard let self, let error else { return }
                self.queue.async { self.failAndClose(error) }
            }
        )
    }

    private func receiveIfNeeded() {
        guard state == .ready, !isReceiving else { return }
        isReceiving = true
        receiveNextChunk()
    }

    private func receiveNextChunk() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 1_048_576
        ) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.queue.async {
                if let data {
                    guard self.buffer.count <= 32 * 1_048_576 - data.count else {
                        self.failAndClose(
                            BitcoinFamilyElectrumError.responseTooLarge
                        )
                        return
                    }
                    self.buffer.append(data)
                    self.consumeCompleteLines()
                }
                if let error {
                    self.failAndClose(error)
                } else if complete {
                    self.failAndClose(
                        BitcoinFamilyElectrumError.unavailable
                    )
                } else if self.state == .ready {
                    self.receiveNextChunk()
                }
            }
        }
    }

    private func consumeCompleteLines() {
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard !line.isEmpty else { return }
        do {
            let preserved =
                BitcoinFamilyLosslessJSON.preservingNumberLexemes(in: line)
            if let responses = try? JSONDecoder().decode(
                [ElectrumResponse].self,
                from: preserved
            ) {
                try record(responses: responses, responseBytes: line.count)
            } else {
                let response = try JSONDecoder().decode(
                    ElectrumResponse.self,
                    from: preserved
                )
                try record(responses: [response], responseBytes: line.count)
            }
        } catch {
            failAndClose(error)
        }
    }

    private func record(
        responses: [ElectrumResponse],
        responseBytes: Int
    ) throws {
        guard var request = pending else { return }
        request.receivedResponseBytes += responseBytes
        guard request.receivedResponseBytes
                <= request.maximumResponseBytes else {
            throw BitcoinFamilyElectrumError.responseTooLarge
        }
        for response in responses {
            guard let rawID = response.id?.value,
                  let id = Int(exactly: rawID) else {
                if let error = response.error,
                   let code = Int(exactly: error.code.value) {
                    throw BitcoinFamilyElectrumError.rpc(
                        code,
                        error.message
                    )
                }
                continue
            }
            guard request.ids.contains(id) else { continue }
            if let error = response.error {
                guard let code = Int(exactly: error.code.value) else {
                    throw BitcoinFamilyElectrumError.invalidResponse
                }
                throw BitcoinFamilyElectrumError.rpc(code, error.message)
            }
            guard let result = response.result else {
                throw BitcoinFamilyElectrumError.invalidResponse
            }
            request.values[id] = result
        }
        pending = request
        guard request.values.count == request.ids.count else { return }
        let ordered = try request.ids.map { id in
            guard let value = request.values[id] else {
                throw BitcoinFamilyElectrumError.invalidResponse
            }
            return value
        }
        complete(token: request.token, result: .success(ordered))
    }

    private func timeout(token: UUID) {
        guard pending?.token == token else { return }
        failAndClose(BitcoinFamilyElectrumError.unavailable)
    }

    private func complete(
        token: UUID,
        result: Result<[JSONValue], Error>
    ) {
        guard let request = pending,
              request.token == token else { return }
        pending = nil
        request.continuation.resume(with: result)
    }

    private func failAndClose(_ error: Error) {
        guard state != .closed else { return }
        state = .closed
        isReceiving = false
        let request = pending
        pending = nil
        connection.cancel()
        request?.continuation.resume(throwing: error)
    }
}
