import XCTest
import OathDiagnostics
import Events
import JSONRPC
@testable import WalletConnectPairing
@testable import WalletConnectRelay

final class ConnectionErrorIdentityTests: XCTestCase {
    func testConnectionErrorIdentitiesUsedByAppPresentation() {
        let used = WalletPairService.Errors.noPendingRequestsForPairing(topic: "synthetic-private-topic") as NSError
        XCTAssertEqual(used.domain, "WalletConnectPairing.WalletPairService.Errors")
        XCTAssertEqual(used.code, 0)
        let disconnected = WalletPairService.Errors.networkNotConnected as NSError
        XCTAssertEqual(disconnected.domain, used.domain)
        XCTAssertEqual(disconnected.code, 1)
        let timeout = RelayError.requestTimeout as NSError
        XCTAssertEqual(timeout.domain, "WalletConnectRelay.RelayError")
        XCTAssertEqual(timeout.code, 0)
    }
}

private actor PairFailureCapture: DiagnosticTransport {
    var events = [DiagnosticEvent]()
    func upload(_ batch: [DiagnosticEvent]) async throws { events += batch }
}

extension ConnectionErrorIdentityTests {
    func testConsumedPairingKeepsFreshQRRequirementWithoutReportingAnAppFailure() async throws {
        guard ProcessInfo.processInfo.environment["OATH_CONSUMED_PAIRING_TEST"] == "1" else {
            throw XCTSkip("Isolated diagnostics reporter")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let sink = PairFailureCapture()
        OathDiagnostics.configure(file: file, transport: sink)
        let storage = PairingStorage(storage: SequenceStore(store: CodableStore<WCPairing>(
            defaults: RuntimeKeyValueStorage(), identifier: "fixture")))
        let history = RPCHistoryFactory.createForNetwork(keyValueStorage: RuntimeKeyValueStorage())
        let network = NetworkingInteractorMock()
        let service = WalletPairService(networkingInteractor: network, kms: KeyManagementServiceMock(),
            pairingStorage: storage, history: history, logger: ConsoleLoggerMock(), eventsClient: MockEventsClient())
        let topic = String(repeating: "1", count: 64)
        let uri = try WalletConnectURI(uriString: "wc:" + topic + "@2?relay-protocol=irn&symKey=" + String(repeating: "2", count: 64))
        var pairing = WCPairing(uri: uri)
        pairing.receivedRequest()
        storage.setPairing(pairing)
        let unrelated = RPCRequest(method: "wc_sessionPropose", id: 10)
        try history.set(unrelated, forTopic: "unrelated", emmitedBy: .remote, transportType: .relay)
        do {
            try await service.pair(uri)
            XCTFail("A consumed code must never create a new connection")
        } catch {
            guard case WalletPairService.Errors.noPendingRequestsForPairing(let returnedTopic) = error else { return XCTFail("Unexpected error type") }
            XCTAssertEqual(returnedTopic, topic)
            OathDiagnostics.record(error, component: "walletconnect", operation: "pair")
        }
        XCTAssertFalse(network.didSubscribe(to: topic))
        XCTAssertFalse(network.didCallHandleHistoryRequest)
        let pending = RPCRequest(method: "wc_sessionPropose", id: 11)
        try history.set(pending, forTopic: topic, emmitedBy: .remote, transportType: .relay)
        try await service.pair(uri)
        XCTAssertTrue(network.didCallHandleHistoryRequest)
        XCTAssertFalse(network.didSubscribe(to: topic))
        OathDiagnostics.record(WalletPairService.Errors.networkNotConnected, component: "walletconnect", operation: "pair")
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            await OathDiagnostics.flush()
            if await sink.events.contains(where: { $0.error.code == 1 }) { break }
        }
        let recorded = await sink.events
        XCTAssertEqual(recorded.map { $0.error.code }, [1])
    }
}
