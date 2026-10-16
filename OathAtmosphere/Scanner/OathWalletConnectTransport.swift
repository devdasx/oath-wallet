@preconcurrency import WalletConnectSign
@preconcurrency import WalletConnectNetworking
import Foundation
import OathAnkr
import OathSecp256k1
import OathDiagnostics

struct OathWCCrypto: CryptoProvider {
    func keccak256(_ data: Data) -> Data { TronSendCrypto.keccak(data) }
    func recoverPubKey(signature: EthereumSignature, message: Data) throws -> Data {
        let v = signature.v >= 27 ? signature.v - 27 : signature.v
        return Data(try OathSecp256k1.recover(Data(signature.r + signature.s + [v]), digest: message).dropFirst())
    }
}
struct OathWCSocketFactory: WebSocketFactory {
    var writeTimeout: TimeInterval = 20
    var maximumPendingWrites: Int = 64
    func create(with url: URL) -> any WebSocketConnecting {
        OathWCSocket(url: url, writeTimeout: writeTimeout, maximumPendingWrites: maximumPendingWrites)
    }
}
/// Native URLSession transport; no third-party socket or main-thread blocking.
private final class OathWCSocket: NSObject, WebSocketErrorReporting, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var operationID = UUID()
    private let writeTimeout: TimeInterval
    private let maximumPendingWrites: Int
    private var writes: [UUID: PendingWrite] = [:]
    private var socket: URLSessionWebSocketTask?
    private var client: URLSession?
    private var connected = false
    private var input: URLRequest
    private var connectCallback: (() -> Void)?
    private var disconnectCallback: ((Error?) -> Void)?
    private var textCallback: ((String) -> Void)?
    private enum Stage: String { case disconnect, receive, send, session; case writeTimeout = "write_timeout" }
    var isConnected: Bool { lock.withLock { connected } }
    var request: URLRequest { get { lock.withLock { input } } set { lock.withLock { input = newValue } } }
    var onConnect: (() -> Void)? { get { lock.withLock { connectCallback } } set { lock.withLock { connectCallback = newValue } } }
    var onDisconnect: ((Error?) -> Void)? { get { lock.withLock { disconnectCallback } } set { lock.withLock { disconnectCallback = newValue } } }
    var onText: ((String) -> Void)? { get { lock.withLock { textCallback } } set { lock.withLock { textCallback = newValue } } }
    init(url: URL, writeTimeout: TimeInterval, maximumPendingWrites: Int) {
        input = URLRequest(url: url)
        self.writeTimeout = writeTimeout
        self.maximumPendingWrites = maximumPendingWrites
        super.init()
    }
    func connect() {
        lock.withLock {
            guard socket == nil else { return }
            operationID = UUID()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            let client = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.client = client
            let task = client.webSocketTask(with: input); task.maximumMessageSize = 1_048_576
            socket = task; task.resume(); receive(task)
        }
    }
    func disconnect() { finish(nil, task: lock.withLock { socket }) }
    private func finish(_ error: Error?, task: URLSessionWebSocketTask?, pendingWriteID: UUID? = nil, stage: Stage = .disconnect) {
        let closed: (callback: ((Error?) -> Void)?, writes: [PendingWrite], operationID: UUID)? = lock.withLock {
            guard let task, task === socket else { return nil }
            if let pendingWriteID, writes[pendingWriteID] == nil { return nil }
            connected = false; socket = nil
            task.cancel(with: .goingAway, reason: nil); client?.invalidateAndCancel(); client = nil
            let pending = Array(writes.values)
            writes.removeAll()
            pending.forEach { $0.deadline.cancel() }
            return (disconnectCallback, pending, operationID)
        }
        guard let closed else { return }
        if let error, !Self.isCancellation(error) {
            OathDiagnostics.$operationID.withValue(closed.operationID) {
                OathDiagnostics.record(error, component: "walletconnect", operation: "relay_transport", context: ["stage": stage.rawValue])
            }
        }
        closed.callback?(error)
        // Intentional teardown cancels outstanding writes; it never fabricates
        // success. Cancellation is expected control flow, not an app failure.
        closed.writes.forEach { $0.complete(error ?? CancellationError()) }
    }
    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task, lock.withLock({ socket === task }) else { return }
            switch result {
            case .success(.string(let value)): onText?(value); receive(task)
            case .success(.data(let data)):
                if let value = String(data: data, encoding: .utf8) { onText?(value) }; receive(task)
            case .success: receive(task)
            case .failure(let error): finish(error, task: task, stage: .receive)
            }
        }
    }
    // The socket lock owns each callback until removal. Only the remover may
    // invoke it, outside the lock, so close/send/timeout races complete once.
    private struct PendingWrite {
        let deadline: DispatchWorkItem
        let complete: (Error?) -> Void
    }
    func write(string: String, completion: (() -> Void)?) {
        write(string: string, resultCompletion: { error in
            if error == nil { completion?() }
        })
    }
    func write(string: String, resultCompletion: @escaping (Error?) -> Void) {
        let id = UUID()
        let start: (task: URLSessionWebSocketTask?, error: Error?) = lock.withLock {
            guard let task = socket else { return (nil, URLError(.networkConnectionLost)) }
            guard writes.count < maximumPendingWrites else { return (nil, URLError(.resourceUnavailable)) }
            let deadline = DispatchWorkItem { [weak self, weak task] in
                self?.finish(URLError(.timedOut), task: task, pendingWriteID: id, stage: .writeTimeout)
            }
            writes[id] = PendingWrite(deadline: deadline, complete: resultCompletion)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + writeTimeout, execute: deadline)
            return (task, nil)
        }
        guard let task = start.task else {
            // A missing socket follows an already-observed disconnect. A full
            // queue is a real failure and must be reported without its payload.
            if let error = start.error, (error as NSError).code == NSURLErrorResourceUnavailable {
                OathDiagnostics.$operationID.withValue(lock.withLock { operationID }) {
                    OathDiagnostics.record(error, component: "walletconnect", operation: "relay_write_capacity", context: ["stage": "send"])
                }
            }
            resultCompletion(start.error)
            return
        }
        task.send(.string(string)) { [weak self, weak task] error in
            if let error { self?.finish(error, task: task, stage: .send) }
            else { self?.completeWrite(id, task: task) }
        }
    }
    private func completeWrite(_ id: UUID, task: URLSessionWebSocketTask?) {
        let pending: PendingWrite? = lock.withLock {
            guard let task, socket === task else { return nil }
            return writes.removeValue(forKey: id)
        }
        pending?.deadline.cancel()
        pending?.complete(nil)
    }
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let value = error as NSError
        return value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let callback: (() -> Void)? = lock.withLock {
            guard socket === webSocketTask else { return nil }; connected = true; return connectCallback
        }; callback?()
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(nil, task: webSocketTask)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let task = task as? URLSessionWebSocketTask, let error { finish(error, task: task, stage: .session) }
    }
}
