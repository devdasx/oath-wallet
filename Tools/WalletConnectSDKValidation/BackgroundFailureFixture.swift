import Foundation
import Combine
@testable import WalletConnectPairing

/// Uses the production resubscribe service and in-memory upstream storage.
/// The injected transport throws a fixture failure; no ACK is fabricated.
final class BackgroundFailureFixture {
    private let network=FailingSubscriptionNetwork()
    private let service:PairingResubscribeService
    init() {
        let store=CodableStore<WCPairing>(defaults:RuntimeKeyValueStorage(),identifier:"sdk-fixture")
        service=PairingResubscribeService(networkInteractor:network,pairingStorage:PairingStorage(storage:SequenceStore(store:store)))
    }
    func reconnect() { network.socketConnectionStatusPublisherSubject.send(.connected) }
}
private final class FailingSubscriptionNetwork: NetworkingInteractorMock {
    override func batchSubscribe(topics:[String]) async throws {
        throw NSError(domain:"Fixture.Transport",code:503,userInfo:[NSLocalizedDescriptionKey:"Unavailable https://fixture.invalid/private-path?token=fixture-secret"])
    }
}
