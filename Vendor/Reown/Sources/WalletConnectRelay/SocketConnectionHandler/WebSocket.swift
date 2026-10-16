// Modified by Oath, 2026-10-15: optional error-reporting native socket writes.
// Upstream: Reown 2.4.0, 1286a56685266804f3ceae93e394f45eb4473dfb.
import Foundation

public protocol WebSocketConnecting: AnyObject {
    var isConnected: Bool { get }
    var onConnect: (() -> Void)? { get set }
    var onDisconnect: ((Error?) -> Void)? { get set }
    var onText: ((String) -> Void)? { get set }
    var request: URLRequest { get set }
    func connect()
    func disconnect()
    func write(string: String, completion: (() -> Void)?)
}

public protocol WebSocketFactory {
    func create(with url: URL) -> WebSocketConnecting
}

/// A transport that terminates each write with its actual outcome, including
/// disconnect and timeout. Legacy transports retain the original contract.
public protocol WebSocketErrorReporting: WebSocketConnecting {
    func write(string: String, resultCompletion: @escaping (Error?) -> Void)
}

#if DEBUG
class WebSocketMock: WebSocketConnecting {
    var request: URLRequest = URLRequest(url: URL(string: "wss://relay.walletconnect.com")!)

    var onText: ((String) -> Void)?
    var onConnect: (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var sendCallCount: Int = 0
    var connectCallCount: Int = 0
    
    // Make isConnected writable with private backing store
    private var _isConnected: Bool = false
    var isConnected: Bool {
        get { return _isConnected }
        set { _isConnected = newValue }
    }
    
    var blockConnection = false

    func connect() {
        connectCallCount += 1
        guard !blockConnection else {
            return
        }
        _isConnected = true
        onConnect?()
    }

    func disconnect() {
        _isConnected = false
        onDisconnect?(nil)
    }

    func write(string: String, completion: (() -> Void)?) {
        sendCallCount += 1
        completion?()
    }
}
#endif

#if DEBUG
class WebSocketFactoryMock: WebSocketFactory {
    private let webSocket: WebSocketMock

    init(webSocket: WebSocketMock) {
        self.webSocket = webSocket
    }

    func create(with url: URL) -> WebSocketConnecting {
        return webSocket
    }
}
#endif
