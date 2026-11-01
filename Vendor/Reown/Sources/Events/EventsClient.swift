import Foundation

public protocol EventsClientProtocol {
    func startTrace(topic: String)
    func saveTraceEvent(_ event: TraceEventItem)
    func setTopic(_ topic: String)
    func setTelemetryEnabled(_ enabled: Bool)
    func saveMessageEvent(_ event: MessageEventType)
}

public class EventsClient: EventsClientProtocol {
    private let eventsCollector: EventsCollector
    private let eventsDispatcher: EventsDispatcher
    private let logger: ConsoleLogging
    private var stateStorage: TelemetryStateStorage
    private let messageEventsStorage: MessageEventsStorage
    private let initEventsStorage: InitEventsStorage
    private let clientID: () -> String
    private let lock = NSLock()
    private var generation = UUID()
    private var revision = UUID()
    private var delivery: Task<Void, Never>?

    init(
        eventsCollector: EventsCollector,
        eventsDispatcher: EventsDispatcher,
        logger: ConsoleLogging,
        stateStorage: TelemetryStateStorage,
        messageEventsStorage: MessageEventsStorage,
        initEventsStorage: InitEventsStorage,
        clientID: @escaping () -> String = { (try? Networking.interactor.getClientId()) ?? "Unknown" }
    ) {
        self.eventsCollector = eventsCollector
        self.eventsDispatcher = eventsDispatcher
        self.logger = logger
        self.stateStorage = stateStorage
        self.messageEventsStorage = messageEventsStorage
        self.initEventsStorage = initEventsStorage
        self.clientID = clientID
        lock.withLock {
            if stateStorage.telemetryEnabled {
                saveInitEventLocked()
                scheduleDeliveryLocked()
            } else {
                clearEventsLocked()
            }
        }
    }

    public func setLogging(level: LoggingLevel) {
        lock.withLock { logger.setLogging(level: level) }
    }

    public func startTrace(topic: String) {
        lock.withLock {
            guard stateStorage.telemetryEnabled else { return }
            eventsCollector.startTrace(topic: topic)
        }
    }

    public func setTopic(_ topic: String) {
        lock.withLock {
            guard stateStorage.telemetryEnabled else { return }
            eventsCollector.setTopic(topic)
        }
    }

    public func saveTraceEvent(_ event: TraceEventItem) {
        lock.withLock {
            guard stateStorage.telemetryEnabled else { return }
            revision = UUID()
            eventsCollector.saveEvent(event)
        }
    }

    public func saveMessageEvent(_ event: MessageEventType) {
        lock.withLock {
            guard stateStorage.telemetryEnabled else { return }
            revision = UUID()
            messageEventsStorage.saveMessageEvent(event)
        }
    }

    public func saveInitEvent() {
        lock.withLock {
            guard stateStorage.telemetryEnabled else { return }
            saveInitEventLocked()
        }
    }

    private func saveInitEventLocked() {
        revision = UUID()
        let props = InitEvent.Props(properties: InitEvent.Properties(
            clientId: clientID(), userAgent: EnvironmentInfo.userAgent))
        initEventsStorage.saveInitEvent(InitEvent(
            eventId: UUID().uuidString,
            bundleId: Bundle.main.bundleIdentifier ?? "Unknown",
            timestamp: Int64(Date().timeIntervalSince1970 * 1000), props: props))
    }

    public func setTelemetryEnabled(_ enabled: Bool) {
        lock.withLock {
            // A repeated enable joins the existing worker rather than spawning
            // competing deliveries and acknowledgements.
            if enabled && stateStorage.telemetryEnabled && delivery != nil { return }
            generation = UUID()
            delivery?.cancel()
            delivery = nil
            stateStorage.telemetryEnabled = enabled
            if enabled {
                scheduleDeliveryLocked()
            } else {
                clearEventsLocked()
            }
        }
    }

    private func clearEventsLocked() {
        clearQueuesLocked()
        eventsCollector.trace = []
        eventsCollector.topic = nil
    }

    private func clearQueuesLocked() {
        revision = UUID()
        eventsCollector.storage.clearErrorEvents()
        messageEventsStorage.clearMessageEvents()
        initEventsStorage.clearInitEvents()
    }

    private func scheduleDeliveryLocked() {
        let token = generation
        delivery = Task { [weak self] in await self?.sendStoredEvents(generation: token) }
    }

    private func authorized(_ token: UUID) -> Bool {
        lock.withLock { generation == token && stateStorage.telemetryEnabled }
    }

    private func sendStoredEvents(generation token: UUID) async {
        let batch: (events: [AnyCodable], revision: UUID)? = lock.withLock {
            guard generation == token, stateStorage.telemetryEnabled else { return nil }
            let events = eventsCollector.storage.fetchErrorEvents().map { AnyCodable($0) }
                + messageEventsStorage.fetchMessageEvents().map { AnyCodable($0) }
                + initEventsStorage.fetchInitEvents().map { AnyCodable($0) }
            return (events, revision)
        }
        defer { lock.withLock { if generation == token { delivery = nil } } }
        guard let batch, !batch.events.isEmpty else { return }
        do {
            let success = try await eventsDispatcher.executeWithRetry(events: batch.events,
                isAuthorized: { [weak self] in self?.authorized(token) == true })
            lock.withLock {
                guard success, generation == token, stateStorage.telemetryEnabled,
                      revision == batch.revision else { return }
                // Never erase events saved during an unfinished request, nor
                // events belonging to a later opt-in generation. A changed
                // batch may be redelivered; it must not be silently discarded.
                clearQueuesLocked()
            }
        } catch is CancellationError {
            // Opt-out is expected; no retry or diagnostic upload.
        } catch {
            lock.withLock { logger.debug("Event delivery failed") }
        }
    }

    deinit { delivery?.cancel() }
}

#if DEBUG
public class MockEventsClient: EventsClientProtocol {
    var startTraceCalled = false
    var saveEventCalled = false
    var telemetryEnabled = true

    public init() {}

    public func startTrace(topic: String) {
        startTraceCalled = true
    }

    public func setTopic(_ topic: String) {}

    public func saveTraceEvent(_ event: TraceEventItem) {
        saveEventCalled = true
    }

    public func setTelemetryEnabled(_ enabled: Bool) {
        telemetryEnabled = enabled
    }

    public func saveMessageEvent(_ event: MessageEventType) {

    }

}
#endif
