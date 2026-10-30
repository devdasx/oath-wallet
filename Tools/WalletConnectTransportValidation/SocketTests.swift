import XCTest
import OathDiagnostics
import RelayDispatcher
@testable import SocketTransport

private final class Events: @unchecked Sendable {
    let lock = NSLock()
    var opens = 0, closes = 0, writes = 0
    var texts: [String] = []
    var errors: [Int] = []
    func opened() { lock.withLock { opens += 1 } }
    func closed(_ error: Error?) { lock.withLock { closes += 1; if let error { errors.append((error as NSError).code) } } }
    func text(_ text: String) { lock.withLock { texts.append(text) } }
    func wrote() { lock.withLock { writes += 1 } }
    func read<T>(_ block: (Events) -> T) -> T { lock.withLock { block(self) } }
    func observe(_ socket: any WebSocketConnecting) {
        let open = socket.onConnect, close = socket.onDisconnect, text = socket.onText
        socket.onConnect = { [self] in open?(); opened() }
        socket.onDisconnect = { [self] error in close?(error); closed(error) }
        socket.onText = { [self] value in text?(value); self.text(value) }
    }
}

@MainActor final class SocketTests: XCTestCase {
    private func until(attempts: Int = 400, _ predicate: () -> Bool) async throws {
        for _ in 0..<attempts { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw SocketTestFailure.callbackTimedOut
    }
    private func socket(_ path: String = "/echo") throws -> (any WebSocketConnecting, Events) {
        let port = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_SOCKET_TEST_PORT"])
        let socket = OathWCSocketFactory().create(with: URL(string: "ws://127.0.0.1:" + port + path)!)
        let events = Events()
        socket.onConnect = events.opened
        socket.onDisconnect = events.closed
        socket.onText = events.text
        return (socket, events)
    }
    func testNativeEchoIntentionalCloseAndReconnect() async throws {
        let (socket, events) = try socket()
        defer { socket.disconnect() }
        socket.connect(); socket.connect()
        try await until { events.read { $0.opens == 1 } }
        XCTAssertTrue(socket.isConnected)
        socket.write(string: "first-public-fixture", completion: events.wrote)
        try await until { events.read { $0.texts.contains("first-public-fixture") && $0.writes == 1 } }
        socket.disconnect(); socket.disconnect()
        XCTAssertFalse(socket.isConnected)
        try await until { events.read { $0.closes == 1 } }
        socket.connect()
        try await until { events.read { $0.opens == 2 } }
        socket.write(string: "second-public-fixture", completion: events.wrote)
        try await until { events.read { $0.texts.contains("second-public-fixture") && $0.writes == 2 } }
        XCTAssertTrue(events.read { $0.errors.isEmpty })
        XCTAssertEqual(events.read { $0.closes }, 1)
    }
    func testAbruptPeerLossReportsOnceAndReconnects() async throws {
        let (socket, events) = try socket()
        defer { socket.disconnect() }
        socket.connect()
        try await until { events.read { $0.opens == 1 } }
        socket.write(string: "terminate-public-fixture", completion: nil)
        try await until { events.read { $0.closes == 1 } }
        XCTAssertFalse(socket.isConnected)
        XCTAssertEqual(events.read { $0.errors.count }, 1)
        socket.connect()
        try await until { events.read { $0.opens == 2 } }
        socket.write(string: "recovered-public-fixture", completion: events.wrote)
        try await until { events.read { $0.texts.contains("recovered-public-fixture") && $0.writes == 1 } }
        XCTAssertTrue(socket.isConnected)
        XCTAssertEqual(events.read { $0.closes }, 1)
    }
    func testClosingBeforeUpgradeDoesNotEmitLateOpenOrDuplicateClose() async throws {
        let (socket, events) = try socket("/delayed")
        socket.connect()
        socket.disconnect()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(events.read { $0.opens }, 0)
        XCTAssertEqual(events.read { $0.closes }, 1)
        XCTAssertTrue(events.read { $0.errors.isEmpty })
        XCTAssertFalse(socket.isConnected)
    }

    func testRemoteCloseCodeDistinguishesNormalClosureFromRelayFailure() async throws {
        let capture = try TransportCapture.configured()
        let previous = Set(await capture.events.map(\.id))
        let expectedShutdowns: Set<Int> = [1000, 1001, 4010]
        let failures: Set<Int> = [1008, 1011, 4001, 4011]
        for code in [1000, 1001, 4010, 1008, 1011, 4001, 4011] {
            let (socket, events) = try socket()
            defer { socket.disconnect() }
            socket.connect()
            try await until { events.read { $0.opens == 1 } }
            socket.write(string: "close-public-fixture:\(code)", completion: nil)
            try await until { events.read { $0.closes == 1 } }
            // A pending receive and the close delegate may both complete. The
            // close code must win regardless of their callback order.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(socket.isConnected)
            XCTAssertEqual(events.read { $0.closes }, 1)
            XCTAssertEqual(events.read { $0.errors }, expectedShutdowns.contains(code) ? [] : [code], "close code \(code)")
            socket.connect()
            try await until { events.read { $0.opens == 2 } }
            socket.write(string: "after-close-public-fixture", completion: events.wrote)
            try await until { events.read { $0.texts.contains("after-close-public-fixture") && $0.writes == 1 } }
        }
        for _ in 0..<100 {
            if await capture.events.count >= previous.count + failures.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let reports = await capture.events.filter { !previous.contains($0.id) }
        XCTAssertEqual(reports.count, failures.count, "Only genuine remote failures are diagnostics")
        XCTAssertEqual(Set(reports.map(\.error.code)), failures)
        XCTAssertEqual(Set(reports.map(\.error.domain)), ["Oath.WalletConnectClose"])
        XCTAssertEqual(Set(reports.map(\.operation)), ["relay_transport"])
        XCTAssertEqual(Set(reports.compactMap(\.operationID)).count, failures.count)
        let text = String(decoding: try JSONEncoder().encode(reports), as: UTF8.self)
        XCTAssertFalse(text.contains("private-close-reason-fixture"))
        XCTAssertFalse(text.contains("close-public-fixture"))
        XCTAssertFalse(text.contains("127.0.0.1"))
    }

    func testLiveNativeRelaySubscribePublishAndReconnect() async throws {
        guard let configuration = ProcessInfo.processInfo.environment["OATH_SOCKET_LIVE"] else {
            throw XCTSkip("Opt-in public relay check")
        }
        struct Configuration: Decodable { let projectID: String; let tokens: [String] }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(configuration.utf8))
        var url = URLComponents(string: "wss://relay.walletconnect.com")!
        url.queryItems = [.init(name: "projectId", value: config.projectID)]
        let events = [Events(), Events()]
        let sockets = config.tokens.enumerated().map { index, token in
            let socket = OathWCSocketFactory().create(with: url.url!)
            socket.request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            return socket
        }
        let dispatchers = sockets.map { DispatcherFixture(socket: $0, factory: OathWCSocketFactory()) }
        for index in sockets.indices { events[index].observe(sockets[index]) }
        defer {
            for peer in events {
                print("OATH_NATIVE_RELAY peer callbacks: opens=\(peer.read { $0.opens }) closes=\(peer.read { $0.closes }) errors=\(peer.read { $0.errors }) frames=\(peer.read { $0.texts.count })")
                for text in peer.read({ $0.texts }) {
                    if let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                       let error = json["error"] as? [String: Any], let code = error["code"] as? Int {
                        print("OATH_NATIVE_RELAY RPC error code=\(code)")
                    }
                }
            }
        }
        defer { sockets.forEach { $0.disconnect() } }
        print("OATH_NATIVE_RELAY connecting")
        sockets.forEach { $0.connect() }
        try await until(attempts: 1_500) { events.allSatisfy { $0.read { $0.opens == 1 } } }
        let topic = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        func send(_ peer: Int, id: Int, method: String, params: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "jsonrpc": "2.0", "method": method, "params": params])
            try await dispatchers[peer].send(String(decoding: data, as: UTF8.self))
        }
        func frames(_ peer: Events) -> [[String: Any]] {
            peer.read { $0.texts }.compactMap { text in
                // Alternative frame decoding is expected protocol dispatch.
                (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            }
        }
        func result(_ peer: Events, id: Int) -> Any? { frames(peer).first { ($0["id"] as? Int) == id }?["result"] }
        for cycle in 0..<2 {
            if cycle == 1 {
                sockets[0].disconnect()
                XCTAssertFalse(sockets[0].isConnected)
                sockets[0].connect()
                try await until(attempts: 1_500) { events[0].read { $0.opens == 2 } }
            }
            // Relay IDs encode the creation timestamp, like WalletConnectRPCID.
            let baseID = Int(Date().timeIntervalSince1970 * 1000) * 1_000_000
            let subscriptionID = baseID + 10, publicationID = baseID + 20
            print("OATH_NATIVE_RELAY subscribe cycle=\(cycle)")
            try await send(0, id: subscriptionID, method: "irn_subscribe", params: ["topic": topic])
            try await until(attempts: 1_500) { result(events[0], id: subscriptionID) is String }
            let payload = Data(("Oath public native socket fixture " + String(cycle)).utf8).base64EncodedString()
            print("OATH_NATIVE_RELAY publish cycle=\(cycle)")
            try await send(1, id: publicationID, method: "irn_publish", params: ["topic": topic,
                "message": payload, "ttl": 30, "tag": 1100, "prompt": false])
            try await until(attempts: 1_500) { (result(events[1], id: publicationID) as? Bool) == true }
            print("OATH_NATIVE_RELAY delivery cycle=\(cycle)")
            try await until(attempts: 1_500) {
                frames(events[0]).contains {
                    (($0["params"] as? [String: Any])?["data"] as? [String: Any])?["message"] as? String == payload
                }
            }
            if let incoming = frames(events[0]).last(where: { $0["method"] as? String == "irn_subscription" }),
               let id = incoming["id"] {
                let ack = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": true])
                try await dispatchers[0].send(String(decoding: ack, as: UTF8.self))
            }
            let subscription = try XCTUnwrap(result(events[0], id: subscriptionID) as? String)
            print("OATH_NATIVE_RELAY unsubscribe cycle=\(cycle)")
            try await send(0, id: baseID + 30, method: "irn_unsubscribe", params: ["topic": topic, "id": subscription])
            try await until(attempts: 1_500) { (result(events[0], id: baseID + 30) as? Bool) == true }
        }
        XCTAssertTrue(events.allSatisfy { $0.read { $0.errors.isEmpty } })
        withExtendedLifetime(dispatchers) {}
        print("OATH_NATIVE_RELAY: patched SDK dispatcher, authentication, subscribe, acknowledged publish, delivered payload, reconnect, resubscribe, second delivery and unsubscribe passed. Host URLSession; no on-chain transaction.")
    }
}

private enum SocketTestFailure: Error { case callbackTimedOut }
