import Foundation

public class EventsClientFactory {
    static func create(
        projectId: String,
        sdkVersion: String,
        storage: EventStorage = UserDefaultsTraceEventStorage()
    ) -> EventsClient {
        let networkingService = NetworkingService(
            projectId: projectId,
            sdkVersion: sdkVersion
        )
        let logger = ConsoleLogger(prefix: "🧚🏻‍♂️", loggingLevel: .off)
        let retryPolicy = RetryPolicy(maxAttempts: 3, initialDelay: 5, multiplier: 2)
        let eventsDispatcher = EventsDispatcher(networkingService: networkingService, retryPolicy: retryPolicy)
        let eventsCollector = EventsCollector(storage: storage, logger: logger)
        // Oath does not opt into SDK event telemetry. Apply this policy before
        // constructing a client, including when an older stored setting is true.
        let state = UserDefaultsTelemetryStateStorage()
        state.telemetryEnabled = false
        return EventsClient(
            eventsCollector: eventsCollector,
            eventsDispatcher: eventsDispatcher,
            logger: logger,
            stateStorage: state,
            messageEventsStorage: UserDefaultsMessageEventsStorage(),
            initEventsStorage: UserDefaultsInitEventsStorage()
        )
    }
}

