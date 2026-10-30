import XCTest
import Combine
@testable import WalletConnectRelay

@MainActor final class SocketWaitTests: XCTestCase {
    func testManualImmediateConnectIsNotLost() async throws {
        let socket=WebSocketMock(), logger=ConsoleLoggerMock()
        let status=SocketStatusProvider(socket:socket,logger:logger)
        let sut=ManualSocketConnectionHandler(socket:socket,logger:logger,topicsTracker:TopicsTrackerMock(),clientIdAuthenticator:FixtureAuthenticator(),socketStatusProvider:status)
        sut.connectionTimeout=0.15
        try await sut.handleInternalConnect(unconditionally:true)
        XCTAssertTrue(socket.isConnected)
    }
    func testManualCancellationDoesNotWaitForTimeout() async throws {
        let socket=WebSocketMock(), logger=ConsoleLoggerMock()
        socket.blockConnection=true
        let status=SocketStatusProvider(socket:socket,logger:logger)
        let sut=ManualSocketConnectionHandler(socket:socket,logger:logger,topicsTracker:TopicsTrackerMock(),clientIdAuthenticator:FixtureAuthenticator(),socketStatusProvider:status)
        sut.connectionTimeout=0.25
        let task=Task { try await sut.handleInternalConnect(unconditionally:true) }
        try await Task.sleep(nanoseconds:30_000_000)
        task.cancel();let start=Date()
        do { try await task.value;XCTFail("Cancelled connection returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start),0.15)
    }
}
private struct FixtureAuthenticator: ClientIdAuthenticating {
    func createAuthToken(url:String) throws -> String { "fixture" }
    func refreshTokenIfNeeded(token:String,url:String) throws -> String { token }
}

extension SocketWaitTests {
    func testConcurrentCallersWaitForTheSameManualConnection() async throws {
        let socket=WebSocketMock(), logger=ConsoleLoggerMock()
        socket.blockConnection=true
        let status=SocketStatusProvider(socket:socket,logger:logger)
        let sut=ManualSocketConnectionHandler(socket:socket,logger:logger,topicsTracker:TopicsTrackerMock(),clientIdAuthenticator:FixtureAuthenticator(),socketStatusProvider:status)
        sut.connectionTimeout=0.5
        let first=Task { try await sut.handleInternalConnect(unconditionally:true); XCTAssertTrue(socket.isConnected) }
        try await Task.sleep(nanoseconds:15_000_000)
        let second=Task { try await sut.handleInternalConnect(unconditionally:true); XCTAssertTrue(socket.isConnected) }
        try await Task.sleep(nanoseconds:15_000_000)
        socket.isConnected=true;socket.onConnect?()
        try await first.value;try await second.value
        XCTAssertEqual(socket.connectCallCount,1)
    }
    func testAutomaticImmediateConnectionAndCancellation() async throws {
        let socket=WebSocketMock(), logger=ConsoleLoggerMock()
        let status=SocketStatusProvider(socket:socket,logger:logger)
        let sut=AutomaticSocketConnectionHandler(socket:socket,networkMonitor:FixtureNetwork(),appStateObserver:FixtureAppState(),backgroundTaskRegistrar:FixtureBackground(),subscriptionsTracker:SubscriptionsTrackerMock(),logger:logger,socketStatusProvider:status,clientIdAuthenticator:FixtureAuthenticator())
        sut.requestTimeout=0.25
        try await sut.handleInternalConnect(unconditionally:true)
        XCTAssertTrue(socket.isConnected)
        socket.blockConnection=true;socket.disconnect()
        try await Task.sleep(nanoseconds:10_000_000)
        let task=Task { try await sut.handleInternalConnect(unconditionally:true) }
        try await Task.sleep(nanoseconds:20_000_000)
        task.cancel();let start=Date()
        do { try await task.value;XCTFail("Cancelled automatic connection returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start),0.15)
    }
    func testWaiterCompletesOnceForDuplicateAndConcurrentCallbacks() async throws {
        let status=LockedStatusFixture()
        try await SocketConnectionWaiter().wait(for:status.publisher,timeout:0.2) {
            DispatchQueue.concurrentPerform(iterations:30) { _ in status.send() }
        }
    }
    func testWaiterTimeoutAndInitialDisconnectedState() async throws {
        let status=CurrentValueSubject<SocketConnectionStatus,Never>(.disconnected)
        let start=Date()
        do {
            try await SocketConnectionWaiter().wait(for:status.eraseToAnyPublisher(),timeout:0.05,maxDisconnections:1) {}
            XCTFail("Unconnected socket returned success")
        } catch { XCTAssertTrue(error is NetworkError) }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start),0.04)
    }
    func testAlreadyCancelledWaitDoesNotStartSocket() async throws {
        let status=PassthroughSubject<SocketConnectionStatus,Never>()
        let task=Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await SocketConnectionWaiter().wait(for:status.eraseToAnyPublisher(),timeout:0.2) { XCTFail("Started cancelled connection") }
                XCTFail("Cancelled wait returned success")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
    }
}
private final class FixtureAppState: AppStateObserving {
    var currentState:ApplicationState { .background }
    var onWillEnterForeground:(()->Void)?
    var onWillEnterBackground:(()->Void)?
}
private final class FixtureNetwork: NetworkMonitoring {
    var isConnected:Bool { true }
    var networkConnectionStatusPublisher:AnyPublisher<NetworkConnectionStatus,Never> { Empty().eraseToAnyPublisher() }
}
private final class FixtureBackground: BackgroundTaskRegistering {
    func register(name:String,completion:@escaping ()->Void) {}
    func invalidate() {}
}

private final class LockedStatusFixture: @unchecked Sendable {
    private let lock=NSLock()
    private let subject=PassthroughSubject<SocketConnectionStatus,Never>()
    var publisher:AnyPublisher<SocketConnectionStatus,Never> { subject.eraseToAnyPublisher() }
    func send() { lock.withLock { subject.send(.connected) } }
}
