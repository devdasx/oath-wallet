import Foundation
import Network

final class PersistentElectrumConnection: @unchecked Sendable {
    private struct PendingRequest {
        let payload: Data
        let maximumResponseBytes: Int
        let continuation: CheckedContinuation<JSONValue, Error>
        var wasSent: Bool
    }

    private struct NotificationSubscriber {
        let method: String
        let firstParameter: String
        let continuation: AsyncStream<JSONValue>.Continuation
    }

    private enum State {
        case idle
        case connecting
        case ready
        case closed
    }

    private let queue = DispatchQueue(
        label: "com.aperture.wallet.electrum.connection",
        qos: .userInitiated
    )
    private let connection: NWConnection
    private var state = State.idle
    private var pending: [Int: PendingRequest] = [:]
    private var notificationSubscribers: [UUID: NotificationSubscriber] = [:]
    private var buffer = Data()
    private var isReceiving = false

    init(
        host: String,
        port: UInt16
    ) {
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
        id: Int,
        payload: Data,
        maximumResponseBytes: Int
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.state != .closed else {
                        continuation.resume(
                            throwing: BitcoinFamilyElectrumError.unavailable
                        )
                        return
                    }
                    guard self.pending[id] == nil else {
                        continuation.resume(
                            throwing: BitcoinFamilyElectrumError.invalidResponse
                        )
                        return
                    }
                    self.pending[id] = PendingRequest(
                        payload: payload,
                        maximumResponseBytes: maximumResponseBytes,
                        continuation: continuation,
                        wasSent: false
                    )
                    self.startIfNeeded()
                    self.sendPendingIfReady()
                    self.queue.asyncAfter(deadline: .now() + 8) {
                        self.timeout(id: id)
                    }
                }
            }
        } onCancel: {
            self.queue.async {
                self.complete(id: id, result: .failure(CancellationError()))
            }
        }
    }

    func notificationStream(
        method: String,
        matchingFirstParameter firstParameter: String
    ) async -> AsyncStream<JSONValue> {
        let subscriberID = UUID()
        let pair = AsyncStream<JSONValue>.makeStream()
        pair.continuation.onTermination = { [weak self] _ in
            guard let connection = self else { return }
            connection.queue.async { [connection] in
                connection.notificationSubscribers[subscriberID] = nil
            }
        }
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.state != .closed else {
                    pair.continuation.finish()
                    continuation.resume()
                    return
                }
                self.notificationSubscribers[subscriberID] =
                    NotificationSubscriber(
                        method: method,
                        firstParameter: firstParameter,
                        continuation: pair.continuation
                    )
                self.startIfNeeded()
                continuation.resume()
            }
        }
        return pair.stream
    }

    func invalidate() {
        queue.async {
            self.failAll(BitcoinFamilyElectrumError.unavailable)
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
                    self.sendPendingIfReady()
                    self.receiveIfNeeded()
                case let .failed(error):
                    self.failAll(error)
                case .cancelled:
                    if self.state != .closed {
                        self.failAll(CancellationError())
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func sendPendingIfReady() {
        guard state == .ready else { return }
        for id in pending.keys.sorted() {
            guard var request = pending[id], !request.wasSent else {
                continue
            }
            request.wasSent = true
            pending[id] = request
            connection.send(
                content: request.payload,
                completion: .contentProcessed { [weak self] error in
                    guard let self, let error else { return }
                    self.queue.async { self.failAll(error) }
                }
            )
        }
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
                    guard self.buffer.count <= 16_777_216 - data.count else {
                        self.failAll(
                            BitcoinFamilyElectrumError.responseTooLarge
                        )
                        return
                    }
                    self.buffer.append(data)
                    self.consumeCompleteLines()
                }
                if let error {
                    self.failAll(error)
                } else if complete {
                    self.failAll(BitcoinFamilyElectrumError.unavailable)
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
        do {
            let preserved =
                BitcoinFamilyLosslessJSON.preservingNumberLexemes(in: line)
            let response = try JSONDecoder().decode(
                ElectrumResponse.self,
                from: preserved
            )
            guard let responseID = response.id?.value else {
                deliverNotification(response)
                return
            }
            guard let id = Int(exactly: responseID),
                  let request = pending[id] else { return }
            guard line.count <= request.maximumResponseBytes else {
                complete(
                    id: id,
                    result: .failure(
                        BitcoinFamilyElectrumError.responseTooLarge
                    )
                )
                return
            }
            if let error = response.error {
                guard let code = Int(exactly: error.code.value) else {
                    throw BitcoinFamilyElectrumError.invalidResponse
                }
                complete(
                    id: id,
                    result: .failure(
                        BitcoinFamilyElectrumError.rpc(code, error.message)
                    )
                )
                return
            }
            guard let result = response.result else {
                throw BitcoinFamilyElectrumError.invalidResponse
            }
            complete(id: id, result: .success(result))
        } catch {
            failAll(error)
        }
    }

    private func deliverNotification(_ response: ElectrumResponse) {
        guard let method = response.method,
              let params = response.params,
              let firstParameter = params.first?.string,
              let status = params.last else {
            return
        }
        for subscriber in notificationSubscribers.values
        where subscriber.method == method
            && subscriber.firstParameter == firstParameter {
            subscriber.continuation.yield(status)
        }
    }

    private func timeout(id: Int) {
        guard pending[id] != nil else { return }
        complete(
            id: id,
            result: .failure(BitcoinFamilyElectrumError.unavailable)
        )
    }

    private func complete(
        id: Int,
        result: Result<JSONValue, Error>
    ) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(with: result)
    }

    private func failAll(_ error: Error) {
        guard state != .closed else { return }
        state = .closed
        isReceiving = false
        let requests = Array(pending.values)
        let subscribers = Array(notificationSubscribers.values)
        pending.removeAll()
        notificationSubscribers.removeAll()
        connection.cancel()
        for request in requests {
            request.continuation.resume(throwing: error)
        }
        for subscriber in subscribers {
            subscriber.continuation.finish()
        }
    }
}
