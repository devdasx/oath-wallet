import XCTest
@testable import Events

/// Actual EventsClient/dispatcher, memory-only stores and a held fake transport.
/// No singleton, wallet storage, Keychain, URLSession or live service is used.
final class EventsPrivacyLifecycleTests: XCTestCase {
    func testDisabledClientDoesNotCollectOrRetainEvents() {
        let fixture = EventsFixture(enabled: false)
        let client = fixture.client()
        client.saveInitEvent()
        client.saveMessageEvent(.sessionRequestLinkModeSent(RPCID(42)))
        client.startTrace(topic: "synthetic-topic")
        client.saveTraceEvent(FixtureTrace())
        XCTAssertTrue(fixture.initial.fetchInitEvents().isEmpty, "Disabled initialization must not retain events")
        XCTAssertTrue(fixture.messages.fetchMessageEvents().isEmpty, "Disabled message collection must not retain events")
        XCTAssertTrue(fixture.errors.fetchErrorEvents().isEmpty)
        XCTAssertTrue(fixture.collector.trace.isEmpty)
        XCTAssertNil(fixture.collector.topic)
        client.setTelemetryEnabled(false)
    }

    func testDisablingPurgesEveryQueueAndInMemoryTrace() {
        let fixture = EventsFixture(enabled: true, delay: 60)
        let client = fixture.client()
        client.startTrace(topic: "synthetic-topic")
        client.saveTraceEvent(FixtureTrace())
        client.setTelemetryEnabled(false)
        XCTAssertTrue(fixture.initial.fetchInitEvents().isEmpty, "Disabling must erase queued initialization events")
        XCTAssertTrue(fixture.messages.fetchMessageEvents().isEmpty, "Disabling must erase queued message events")
        XCTAssertTrue(fixture.errors.fetchErrorEvents().isEmpty)
        XCTAssertTrue(fixture.collector.trace.isEmpty, "Disabling must erase in-memory trace")
        XCTAssertNil(fixture.collector.topic, "Disabling must erase in-memory topic")
    }

    func testDisablingPreventsRetryAfterCancellationResistantFailure() async throws {
        let first = expectation(description: "first synthetic transport request")
        let second = expectation(description: "no retry after opt-out")
        second.isInverted = true
        let transport = HeldEventsTransport(first: first, second: second)
        let fixture = EventsFixture(enabled: true, transport: transport)
        let client = fixture.client()
        await fulfillment(of: [first], timeout: 2)
        client.setTelemetryEnabled(false)
        transport.releaseFailure()
        // Retries are configured with zero delay. This bounded window observes
        // the resumed worker, not a live-network timeout.
        await fulfillment(of: [second], timeout: 0.3)
        XCTAssertEqual(transport.attempts, 1, "Opt-out must prevent retrying a previously accepted request")
    }

    func testFreshTelemetryStateRequiresOptIn() throws {
        let suite = "oath.audit.events." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = UserDefaultsTelemetryStateStorage(defaults: defaults)
        XCTAssertFalse(state.telemetryEnabled, "A new SDK installation must not opt into telemetry")
    }

    func testExplicitlyEnabledClientCanDeliverSyntheticEvents() async {
        let delivered = expectation(description: "synthetic events delivered")
        let transport = SuccessfulEventsTransport(delivered: delivered)
        let fixture = EventsFixture(enabled: true, transport: transport)
        let client = fixture.client()
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertGreaterThanOrEqual(transport.count, 3, "The real client must combine stored event kinds")
        client.setTelemetryEnabled(false)
    }
}

private struct FixtureTrace: TraceEventItem { var description: String { "synthetic trace" } }
private final class MemoryEventsState: TelemetryStateStorage {
    var telemetryEnabled: Bool
    init(_ enabled: Bool) { telemetryEnabled = enabled }
}
private final class MemoryEvents: EventStorage, MessageEventsStorage, InitEventsStorage {
    private let lock = NSLock()
    private var errors = [TraceEvent(eventId: "synthetic-error", bundleId: "audit", timestamp: 0,
        props: .init(event: "ERROR", type: "synthetic", properties: nil))]
    private var messages = [MessageEvent(eventId: "synthetic-message", bundleId: "audit", timestamp: 0,
        props: .init(type: "1125", properties: .init(correlationId: 42, clientId: "synthetic", direction: .sent)))]
    private var initial = [InitEvent(eventId: "synthetic-init", bundleId: "audit", timestamp: 0,
        props: .init(properties: .init(clientId: "synthetic", userAgent: "audit")))]
    func saveErrorEvent(_ value: TraceEvent) { lock.withLock { errors.append(value) } }
    func fetchErrorEvents() -> [TraceEvent] { lock.withLock { errors } }
    func clearErrorEvents() { lock.withLock { errors.removeAll() } }
    func saveMessageEvent(_ value: MessageEventType) { lock.withLock {
        messages.append(MessageEvent(eventId: "synthetic-new-message", bundleId: "audit", timestamp: 0,
            props: .init(type: "1125", properties: .init(correlationId: 43, clientId: "synthetic", direction: .sent))))
    } }
    func fetchMessageEvents() -> [MessageEvent] { lock.withLock { messages } }
    func clearMessageEvents() { lock.withLock { messages.removeAll() } }
    func saveInitEvent(_ value: InitEvent) { lock.withLock { initial.append(value) } }
    func fetchInitEvents() -> [InitEvent] { lock.withLock { initial } }
    func clearInitEvents() { lock.withLock { initial.removeAll() } }
}
private final class SuccessfulEventsTransport: NetworkingServiceProtocol {
    private let lock = NSLock()
    private var sentCount = 0
    let delivered: XCTestExpectation?
    var count: Int { lock.withLock { sentCount } }
    init(delivered: XCTestExpectation? = nil) { self.delivered = delivered }
    func sendEvents<T: Encodable>(_ events: [T]) async throws -> Bool {
        lock.withLock { sentCount = events.count }; delivered?.fulfill(); return true
    }
}
private final class HeldEventsTransport: NetworkingServiceProtocol {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Error>?
    private var count = 0
    let first: XCTestExpectation, second: XCTestExpectation
    var attempts: Int { lock.withLock { count } }
    init(first: XCTestExpectation, second: XCTestExpectation) { self.first = first; self.second = second }
    func sendEvents<T: Encodable>(_ events: [T]) async throws -> Bool {
        let attempt = lock.withLock { count += 1; return count }
        if attempt > 1 { second.fulfill(); return true }
        return try await withCheckedThrowingContinuation { pending in
            lock.withLock { continuation = pending }; first.fulfill()
        }
    }
    func releaseFailure() {
        let pending = lock.withLock { let value = continuation; continuation = nil; return value }
        pending?.resume(throwing: NSError(domain: "SyntheticFailure", code: 1))
    }
}
private final class EventsFixture {
    let errors = MemoryEvents(), messages = MemoryEvents(), initial = MemoryEvents()
    let state: MemoryEventsState
    let dispatcher: EventsDispatcher
    lazy var collector = EventsCollector(storage: errors, logger: ConsoleLoggerMock())
    init(enabled: Bool, delay: TimeInterval = 0, transport: NetworkingServiceProtocol = SuccessfulEventsTransport()) {
        state = MemoryEventsState(enabled)
        dispatcher = EventsDispatcher(networkingService: transport,
            retryPolicy: RetryPolicy(maxAttempts: 3, initialDelay: delay, multiplier: 1))
    }
    func client() -> EventsClient {
        EventsClient(eventsCollector: collector, eventsDispatcher: dispatcher, logger: ConsoleLoggerMock(),
            stateStorage: state, messageEventsStorage: messages, initEventsStorage: initial, clientID: { "synthetic-client" })
    }
}
