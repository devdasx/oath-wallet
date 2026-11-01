
import Foundation

class SessionResponder {
    enum Errors: Error {
        case sessionRequestExpired
        case sessionRequestNotFound
    }
    private let logger: ConsoleLogging
    private let sessionStore: WCSessionStorage
    private let networkingInteractor: NetworkInteracting
    private let verifyContextStore: CodableStore<VerifyContext>
    private let sessionRequestsProvider: SessionRequestsProvider
    private let historyService: HistoryService
    private let tvfCollector: TVFCollector

    init(
        logger: ConsoleLogging,
        sessionStore: WCSessionStorage,
        networkingInteractor: NetworkInteracting,
        verifyContextStore: CodableStore<VerifyContext>,
        sessionRequestsProvider: SessionRequestsProvider,
        historyService: HistoryService,
        tvfCollector: TVFCollector
    ) {
        self.logger = logger
        self.sessionStore = sessionStore
        self.networkingInteractor = networkingInteractor
        self.verifyContextStore = verifyContextStore
        self.sessionRequestsProvider = sessionRequestsProvider
        self.historyService = historyService
        self.tvfCollector = tvfCollector
    }

    func respondSessionRequest(topic: String, requestId: RPCID, response: RPCResult) async throws {
        guard sessionStore.hasSession(forTopic: topic) else {
            throw WalletConnectError.noSessionMatchingTopic(topic)
        }

        guard let (request, _) = historyService.getSessionRequest(id: requestId),
              request.topic == topic else {
            throw Errors.sessionRequestNotFound
        }

        let protocolMethod = SessionRequestProtocolMethod()

        guard !request.isExpired() else {
            try await networkingInteractor.respondError(
                topic: topic,
                requestId: requestId,
                protocolMethod: protocolMethod,
                reason: SignReasonCode.sessionRequestExpired
            )
            verifyContextStore.delete(forKey: requestId.string)
            throw Errors.sessionRequestExpired
        }



        let tvfData = tvfCollector.collect(rpcMethod: request.method, rpcParams: request.params, chainID: request.chainId, rpcResult: response, tag: protocolMethod.responseConfig.tag)

        try await networkingInteractor.respond(
            topic: topic,
            response: RPCResponse(id: requestId, outcome: response),
            protocolMethod: protocolMethod,
            tvfData: tvfData
        )
        verifyContextStore.delete(forKey: requestId.string)
        sessionRequestsProvider.emitRequestAfterResponse()
    }

}
