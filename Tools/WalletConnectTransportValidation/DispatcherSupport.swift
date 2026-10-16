// Non-transport dependencies for the host harness. The dispatcher, socket
// contracts and status provider are copied verbatim from the pinned SDK.
import Foundation
import Combine

public enum SocketConnectionStatus { case connected, disconnected }
final class RelayUrlFactory {}
protocol ConsoleLogging { func debug(_ message: String) }
struct QuietLogger: ConsoleLogging { func debug(_ message: String) {} }

final class ConnectedNetwork: NetworkMonitoring {
    var isConnected: Bool { true }
    var networkConnectionStatusPublisher: AnyPublisher<NetworkConnectionStatus, Never> {
        Just(.connected).eraseToAnyPublisher()
    }
}
struct FixtureConnectionHandler: SocketConnectionHandler {
    let socket: WebSocketConnecting
    func handleConnect() throws { socket.connect() }
    func handleInternalConnect(unconditionally: Bool) async throws { socket.connect() }
    func handleDisconnect(closeCode: URLSessionWebSocketTask.CloseCode) throws { socket.disconnect() }
}
public final class DispatcherFixture: @unchecked Sendable {
    let dispatcher: Dispatcher
    public init(socket: WebSocketConnecting, factory: WebSocketFactory) {
        let logger = QuietLogger()
        dispatcher = Dispatcher(socketFactory: factory, relayUrlFactory: RelayUrlFactory(),
            networkMonitor: ConnectedNetwork(), socket: socket, logger: logger,
            socketConnectionHandler: FixtureConnectionHandler(socket: socket),
            socketStatusProvider: SocketStatusProvider(socket: socket, logger: logger))
    }
    public func send(_ string: String, completion: @escaping (Error?) -> Void) {
        dispatcher.protectedSend(string, completion: completion)
    }
    public func send(_ string: String) async throws { try await dispatcher.protectedSend(string) }
}
