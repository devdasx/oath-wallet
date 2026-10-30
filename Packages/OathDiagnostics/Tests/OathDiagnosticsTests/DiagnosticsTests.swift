import XCTest
@testable import OathDiagnostics

private enum ControlFlowFixture: DiagnosticControlFlowError {
    case waitingForProtectedData, genuineFailure
    var isExpectedDiagnosticControlFlow: Bool { self == .waitingForProtectedData }
}

private actor FakeTransport: DiagnosticTransport {
    var failing = false
    var attempts = 0
    var received: [DiagnosticEvent] = []
    func fail(_ value: Bool) { failing = value }
    func upload(_ events: [DiagnosticEvent]) async throws {
        attempts += 1
        if failing { throw URLError(.notConnectedToInternet) }
        received += events
    }
    func events() -> [DiagnosticEvent] { received }
}
final class DiagnosticsTests: XCTestCase, @unchecked Sendable {
    func testFilecoinAddressesAreRedactedFromProviderErrors() {
        let value = "invalid f410fe7xvzw7ac535mjbyv77lnfpdh7bdgwlzqbe3qsy"
        XCTAssertEqual(DiagnosticPrivacy.text(value), "invalid [redacted]")
    }
    func testWalletConnectPayloadIsEntirelyRedacted() {
        let publicFixture = "wc:" + String(repeating: "a", count: 64) + "@2?relay-protocol=irn&symKey=" + String(repeating: "b", count: 64) + "&relay-data=private-routing"
        XCTAssertEqual(DiagnosticPrivacy.text("Pair failed " + publicFixture), "Pair failed [redacted]")
    }
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("outbox.json")
    }
    private func event(id: UUID = UUID(), message: String = "connection refused") -> DiagnosticEvent {
        .init(error: NSError(domain: "Test.RPC", code: -32000, userInfo: [NSLocalizedDescriptionKey: message]),
              component: "send", operation: "broadcast", context: ["chain": "dogecoin", "stage": "broadcast"],
              sessionID: UUID(), id: id, occurredAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)))
    }
    @MainActor func testSchedulingFlushReturnsWithAnUnfinishedDelivery() async throws {
        actor Held: DiagnosticTransport {
            var started = false
            var waiter: CheckedContinuation<Void, Never>?
            func upload(_ events: [DiagnosticEvent]) async throws {
                started = true
                await withCheckedContinuation { waiter = $0 }
            }
            func release() { waiter?.resume(); waiter = nil }
        }
        let transport = Held(), path = file(), queue = DiagnosticOutbox(file: path, transport: transport)
        let persisted = await queue.enqueue(event()); XCTAssertTrue(persisted)
        queue.requestFlush()
        for _ in 0..<200 {
            if await transport.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await transport.started; XCTAssertTrue(started)
        // Lifecycle scheduling is synchronous even with an unfinished delivery.
        for _ in 0..<20 { queue.requestFlush() }
        let second = event(message: "independent failure")
        let saved = await queue.enqueue(second); XCTAssertTrue(saved)
        let pending = await queue.status(); XCTAssertEqual(pending.pending, 2)
        await transport.release()
        for _ in 0..<200 {
            if await queue.status().pending == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let remaining = await queue.status(); XCTAssertEqual(remaining.pending, 1)
    }

    func testRedactsSecretsURLsMnemonicsAndUntrustedEchoes() {
        let samples = [
            "https://rpc.example.com/private-api-key-123?token=secret",
            "Authorization=Bearer very-private-token",
            "mnemonic=\"alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu\"",
            String(repeating: "abandon ", count: 11) + "about",
            "private_key=" + String(repeating: "a", count: 64),
            "password: 'tiny secret'",
            "user@private.example", "/Users/someone/Library/vault.json"
        ]
        for secret in samples { XCTAssertFalse(DiagnosticPrivacy.text(secret).contains(secret)) }
        XCTAssertEqual(DiagnosticPrivacy.text("mandatory-script-verify-flag-failed (code -26)"), "mandatory-script-verify-flag-failed (code -26)")
        XCTAssertFalse(DiagnosticPrivacy.text("RPC rejected \"sensitive input\"").contains("sensitive input"))
    }
    func testPreservesDomainCodeUnderlyingAndRejectsUnknownContext() {
        let inner = NSError(domain: "TLS", code: -1200)
        let outer = NSError(domain: "RPC", code: 429, userInfo: [NSUnderlyingErrorKey: inner, NSLocalizedDescriptionKey: "Rate limit exceeded"])
        let report = DiagnosticEvent(error: outer, component: "history", operation: "refresh", context: ["chain": "ton", "private_key": "should never exist"], sessionID: UUID())
        XCTAssertEqual(report.error.code, 429); XCTAssertEqual(report.error.underlying.first?.code, -1200)
        XCTAssertEqual(report.error.message, "Rate limit exceeded"); XCTAssertNil(report.context["private_key"])
    }
    func testCocoaFileErrorsRedactIdentifiersAndLocalizedQuotedNames() throws {
        let identifier = "12345678-1234-5678-9abc-123456789abc"
        let filename = identifier + ".sealed"
        for quoted in ["“\(filename)”", "‘\(filename)’", "«\(filename)»", "„\(filename)“"] {
            let original = NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: [
                NSLocalizedDescriptionKey: "The file \(quoted) could not be opened because permission was denied.",
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 1)
            ])
            let report = DiagnosticError(original)
            let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
            XCTAssertFalse(encoded.contains(identifier))
            XCTAssertFalse(encoded.contains(".sealed"))
            XCTAssertTrue(report.message.contains("permission was denied"))
            XCTAssertEqual(report.code, 257)
            XCTAssertEqual(report.underlying.first?.code, 1)
        }
        XCTAssertEqual(DiagnosticPrivacy.text("Missing local entry " + identifier), "Missing local entry [redacted]")
        XCTAssertEqual(DiagnosticPrivacy.text("The file “Personal wallet” is unavailable"), "The file [redacted] is unavailable")
    }
    func testShortAlchemyCredentialsAreRemovedFromErrorsAndContext() throws {
        let key = "alch_fake-Key_123"
        let error = NSError(domain: "RPC", code: 429, userInfo: [NSLocalizedDescriptionKey:
            "Rate limited for \(key) at https://bitcoin-mainnet.g.alchemy.com/v2/\(key)"])
        let event = DiagnosticEvent(error: error, component: "send", operation: "fee_source",
            context: ["host": "bitcoin-mainnet.g.alchemy.com", "reason": key], sessionID: UUID())
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(encoded.contains(key)); XCTAssertFalse(encoded.contains("/v2/"))
        XCTAssertTrue(encoded.contains("Rate limited")); XCTAssertTrue(encoded.contains("429"))
    }
    func testNSErrorWithoutMessageNeverFallsBackToArbitraryUserInfo() throws {
        let error = NSError(domain: "Test.Native", code: 22, userInfo: ["unstructured": ["input": "sensitive rejected value"]])
        let report = DiagnosticError(error)
        XCTAssertEqual(report.code, 22)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(json.contains("sensitive")); XCTAssertFalse(json.contains("unstructured"))
    }
    func testQueueRoundTripsAndRetainsFailedUpload() async throws {
        let path = file(), transport = FakeTransport(), original = event()
        let queue = DiagnosticOutbox(file: path, transport: transport)
        let durable = await queue.enqueue(original); XCTAssertTrue(durable)
        await transport.fail(true); await queue.flush()
        let pending = await queue.status(); XCTAssertEqual(pending.pending, 1)
        let reopened = DiagnosticOutbox(file: path, transport: transport)
        let restored = await reopened.status(); XCTAssertEqual(restored.pending, 1)
        await transport.fail(false); await reopened.flush()
        let sent = await transport.events(); XCTAssertEqual(sent, [original])
        let status = await reopened.status(); XCTAssertEqual(status.pending, 0)
        try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
    }
    func testIdempotentLocalEnqueueAndRetentionBound() async throws {
        let path = file(), transport = FakeTransport(), queue = DiagnosticOutbox(file: path, transport: transport, limit: 3)
        let first = event()
        _ = await queue.enqueue(first); _ = await queue.enqueue(first)
        let once = await queue.status(); XCTAssertEqual(once.pending, 1)
        for _ in 0..<5 { _ = await queue.enqueue(event()) }
        let bounded = await queue.status(); XCTAssertEqual(bounded.pending, 3); XCTAssertEqual(bounded.dropped, 3)
        let data = try Data(contentsOf: path)
        let reports = try DiagnosticEvent.decoder().decode([DiagnosticEvent].self, from: data)
        XCTAssertEqual(reports.count, 3)
        try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
    }
    func testWireSchemaUsesExpectedAcronymsAndNoUserInfo() throws {
        let report = event(message: "RPC denied https://rpc.example/key")
        let data = try DiagnosticEvent.encoder().encode(report)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["session_id"]); XCTAssertNotNil(json["occurred_at"])
        XCTAssertNotNil(json["source_file"]); XCTAssertEqual(json["privacy_filtered"] as? Bool, true)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("rpc.example"))
        XCTAssertEqual(try DiagnosticEvent.decoder().decode(DiagnosticEvent.self, from: data), report)
    }
    func testTransportContextNeverCopiesCredentialsAddressesOrQuery() {
        var request = URLRequest(url: URL(string: "https://rpc.ankr.com/ton_api_v2/private-key?address=secret-owner")!)
        request.setValue("secret", forHTTPHeaderField: "apikey")
        request.httpBody = Data(#"{"method":"eth_getBalance","params":{"walletAddress":"secret-owner"}}"#.utf8)
        let context = DiagnosticHTTP.context(request)
        XCTAssertEqual(context["chain"], "ton"); XCTAssertEqual(context["method"], "eth_getBalance")
        XCTAssertFalse(String(describing: context).contains("secret")); XCTAssertFalse(String(describing: context).contains("private-key"))
    }
    func testCorruptQueueRecoversWithoutLosingNewReport() async throws {
        let path = file(), transport = FakeTransport()
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: path)
        let queue = DiagnosticOutbox(file: path, transport: transport)
        let saved = await queue.enqueue(event()); XCTAssertTrue(saved)
        let status = await queue.status(); XCTAssertEqual(status.pending, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathExtension("corrupt").path))
        try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
    }
    func testRuntimeReportAllowsSymbolicationButRejectsPrivateFields() {
        let uuid = UUID().uuidString
        let raw = "{\"callStackTree\":{\"callStacks\":[{\"binaryUUID\":\"\(uuid)\",\"offsetIntoBinaryTextSegment\":123}]},\"applicationSpecificInformation\":\"private secret\",\"password\":\"private secret\"}"
        let safe = DiagnosticPrivacy.runtime(raw)
        XCTAssertTrue(safe.contains(uuid)); XCTAssertTrue(safe.contains("123")); XCTAssertFalse(safe.contains("private secret"))
    }
    func testLargeRuntimeReportStaysParseableAndKeepsAttributedStack() throws {
        let uuid = UUID().uuidString
        let frames = Array(repeating: ["binaryName": String(repeating: "module.", count: 70), "offsetIntoBinaryTextSegment": 123] as [String: Any], count: 128)
        var stacks = Array(repeating: ["threadAttributed": false, "callStackRootFrames": frames] as [String: Any], count: 10)
        stacks.append(["threadAttributed": true, "callStackRootFrames": [["binaryUUID": uuid, "offsetIntoBinaryTextSegment": 456]]])
        let raw = try JSONSerialization.data(withJSONObject: ["callStackTree": ["callStacks": stacks], "diagnosticMetaData": ["signal": 11]])
        let safe = DiagnosticPrivacy.runtime(String(decoding: raw, as: UTF8.self))
        XCTAssertLessThanOrEqual(safe.utf8.count, 14 * 1024)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any])
        XCTAssertEqual(json["_truncated"] as? Bool, true)
        XCTAssertTrue(safe.contains(uuid)); XCTAssertTrue(safe.contains("signal"))
    }
    func testLongPayloadIsExplicitlyTruncated() {
        let result = DiagnosticPrivacy.text(String(repeating: "failure. ", count: 5000))
        XCTAssertLessThan(result.count, 4200); XCTAssertTrue(result.contains("[truncated]"))
    }
    func testRecoveryPhrasesAreRedactedAcrossSupportedLanguagesWithoutHidingNormalErrors() {
        // Public dictionary words only, not wallet input.
        for word in ["abandon", "あいこくしん", "가격", "ábaco", "的", "abaisser", "abaco", "abdikace", "abacate"] {
            for separator in [" ", "\u{3000}", ", "] {
                let phrase = Array(repeating: word, count: 12).joined(separator: separator)
                XCTAssertEqual(DiagnosticPrivacy.text(phrase), "[redacted]")
            }
        }
        XCTAssertEqual(DiagnosticPrivacy.text(String(repeating: "的", count: 12)), "[redacted]")
        XCTAssertFalse(DiagnosticPrivacy.text("pass\u{200B}phrase=fixture-secret").contains("fixture-secret"))
        let explanation = "Transaction rejected because the replacement fee does not exceed the fee of the original transaction"
        XCTAssertEqual(DiagnosticPrivacy.text(explanation), explanation)
    }
    func testWorstCaseMultibyteEscapedEventFitsServerLimit() throws {
        for sample in ["\\\n🧪", "\\"] {
            let huge = String(repeating: sample, count: 10_000)
            var error = NSError(domain: "Fixture", code: -1, userInfo: [NSLocalizedDescriptionKey: huge, NSLocalizedFailureReasonErrorKey: huge])
            for _ in 0..<4 { error = NSError(domain: "Fixture", code: -1, userInfo: [NSLocalizedDescriptionKey: huge, NSLocalizedFailureReasonErrorKey: huge, NSUnderlyingErrorKey: error]) }
            let report = try JSONSerialization.data(withJSONObject: ["callStackTree": ["callStacks": Array(repeating: ["binaryName": String(huge.prefix(1024))], count: 128)]])
            let keys = ["chain", "stage", "method", "host", "http_status", "rpc_code", "attempt", "input_count", "duration_ms", "category", "source", "retryable", "count", "reason", "asset_kind", "screen", "origin_screen", "screen_source", "action", "step", "step_source", "app_state", "action_started_at", "elapsed_ms", "cause_status", "time_source"]
            let event = DiagnosticEvent(error: error, component: "fixture", operation: "size_limit", context: Dictionary(uniqueKeysWithValues: keys.map { ($0, huge) }),
                                        runtimeReport: String(decoding: report, as: UTF8.self), sessionID: UUID(),
                                        occurredAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)))
            let data = try DiagnosticEvent.encoder().encode(event)
            XCTAssertLessThan(data.count, 65_536)
            XCTAssertTrue(event.error.message.contains("[truncated]"))
            XCTAssertTrue(event.runtimeReport?.contains("callStackTree") == true)
            XCTAssertTrue(try DiagnosticEvent.decoder().decode(DiagnosticEvent.self, from: data) == event)
        }
    }
    func testDuplicateEnqueueDoesNotClaimDurabilityAfterDiskFailure() async throws {
        let path = file(), transport = FakeTransport(), original = event()
        let directory = path.deletingLastPathComponent()
        try Data("blocking file".utf8).write(to: directory)
        let queue = DiagnosticOutbox(file: path, transport: transport)
        let first = await queue.enqueue(original), duplicate = await queue.enqueue(original)
        XCTAssertFalse(first); XCTAssertFalse(duplicate)
        try FileManager.default.removeItem(at: directory)
        let recovered = await queue.enqueue(original); XCTAssertTrue(recovered)
        let restored = DiagnosticOutbox(file: path, transport: transport)
        let status = await restored.status(); XCTAssertEqual(status.pending, 1)
        try? FileManager.default.removeItem(at: directory)
    }
    func testQueueExpiresEventsEvenWithoutRelaunch() async throws {
        final class Clock: @unchecked Sendable {
            let lock = NSLock(); var date = Date()
            func now() -> Date { lock.withLock { date } }
            func advance() { lock.withLock { date += 500 } }
        }
        let clock = Clock(), path = file(), transport = FakeTransport()
        let queue = DiagnosticOutbox(file: path, transport: transport, now: { clock.now() })
        let old = DiagnosticEvent(error: DiagnosticFailure("old"), component: "fixture", operation: "expiry", sessionID: UUID(), occurredAt: clock.now().addingTimeInterval(-14 * 86_400 + 250))
        _ = await queue.enqueue(old)
        let before = await queue.status(); XCTAssertEqual(before.pending, 1)
        clock.advance(); await queue.flush()
        let sent = await transport.events()
        XCTAssertFalse(sent.contains(where: { $0.id == old.id }))
        XCTAssertEqual(sent.first?.operation, "retention")
    }
    func testEnqueueDuringUploadDoesNotLoseNewEvents() async throws {
        actor PausedTransport: DiagnosticTransport {
            var started = false
            var resume: CheckedContinuation<Void, Never>?
            var received: [UUID] = []
            func upload(_ events: [DiagnosticEvent]) async throws {
                if !started { started = true; await withCheckedContinuation { resume = $0 } }
                received += events.map(\.id)
            }
            func release() { resume?.resume(); resume = nil }
        }
        let transport = PausedTransport(), path = file()
        let queue = DiagnosticOutbox(file: path, transport: transport)
        let first = event(), second = event()
        _ = await queue.enqueue(first)
        let upload = Task { await queue.flush() }
        for _ in 0..<100 {
            if await transport.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = await queue.enqueue(second)
        await queue.flush() // An overlapping flush cannot start another upload.
        await transport.release(); await upload.value
        let sent = await transport.received
        XCTAssertEqual(sent, [first.id, second.id])
        let status = await queue.status(); XCTAssertEqual(status.pending, 0)
        try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
    }
    func testNewErrorsRespectBackoffUntilExplicitForegroundRetry() async throws {
        let path = file(), transport = FakeTransport()
        let queue = DiagnosticOutbox(file: path, transport: transport)
        await transport.fail(true)
        _ = await queue.enqueue(event()); await queue.flush()
        for _ in 0..<5 { _ = await queue.enqueue(event()); await queue.flush() }
        let offlineAttempts = await transport.attempts; XCTAssertEqual(offlineAttempts, 1)
        await transport.fail(false); await queue.flush(force: true)
        let status = await queue.status(); XCTAssertEqual(status.pending, 0)
        let sent = await transport.events(); XCTAssertEqual(sent.count, 6)
        try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
    }
}

private final class ReplyProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var correctAcknowledgement = true
        var lastBody: [String: Any] = [:]
        var requestCount = 0
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; body.append(contentsOf: bytes.prefix(count)) }
        }
        let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let ids = (object["p_events"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.map { $0.lowercased() }
        let correct = Self.state.lock.withLock {
            Self.state.requestCount += 1
            Self.state.lastBody = object
            return Self.state.correctAcknowledgement
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: correct ? ids : [])) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
extension DiagnosticsTests {
    func testRPCResponseCapturesOriginalErrorBeforeProviderFlattensIt() async throws {
        let transport = FakeTransport(), path = file()
        OathDiagnostics.configure(file: path, transport: transport)
        var request = URLRequest(url: URL(string: "https://rpc.ankr.com/ton_api_v2/private-key")!)
        request.httpBody = Data(#"{"method":"getTransactions","params":{"address":"never upload"}}"#.utf8)
        let correlation = UUID()
        OathDiagnostics.$operationID.withValue(correlation) {
            DiagnosticHTTP.response(Data(#"{"id":1,"error":{"code":-32005,"message":"Rate limit exceeded","data":{"secret":"never upload"}}}"#.utf8), status: 200, request: request)
            DiagnosticHTTP.response(Data(#"{"result":{"status":"error","error":"actNotFound","error_code":19,"error_message":"Account not found.","request":{"address":"never upload"}}}"#.utf8), status: 200, request: request)
            DiagnosticHTTP.response(Data(#"{"message":"Account lookup failed","error_code":"account_not_found","input":"never upload"}"#.utf8), status: 404, request: request)
            DiagnosticHTTP.response(Data(#"{"ok":false,"error":"LITE_SERVER_UNKNOWN","code":500}"#.utf8), status: 500, request: request)
            var near = URLRequest(url: URL(string: "https://rpc.ankr.com/near/fixture-key")!)
            near.httpBody = Data(#"{"method":"query","params":{"request_type":"view_account","account_id":"fixture.near"}}"#.utf8)
            DiagnosticHTTP.response(Data(#"{"error":{"code":-32000,"message":"Server error","data":"account fixture.near does not exist while viewing"}}"#.utf8), status: 200, request: near)
            DiagnosticHTTP.response(Data(#"{"error":{"code":-32000,"message":"Server error","cause":{"name":"UNKNOWN_BLOCK","info":{"block":"never upload"}}}}"#.utf8), status: 200, request: near)
        }
        for _ in 0..<100 {
            if (await transport.events()).count == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await transport.events()
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events.allSatisfy { $0.operationID == correlation })
        XCTAssertFalse(events.contains { $0.error.code == -32005 || $0.error.code == 500 })
        let error = try XCTUnwrap(events.first(where: { $0.error.code == 19 }))
        XCTAssertEqual(error.context["chain"], "ton"); XCTAssertEqual(error.context["method"], "getTransactions")
        XCTAssertFalse(String(decoding: try DiagnosticEvent.encoder().encode(error), as: UTF8.self).contains("never upload"))
        XCTAssertEqual(events.first(where: { $0.error.code == 19 })?.error.message, "Account not found.")
        XCTAssertEqual(events.first(where: { $0.error.code == 404 })?.context["rpc_code"], "account_not_found")
        XCTAssertEqual(events.first(where: { $0.error.code == -32000 })?.error.message, "Server error: UNKNOWN_BLOCK")
        XCTAssertFalse(String(decoding: try DiagnosticEvent.encoder().encode(events), as: UTF8.self).contains("never upload"))
        let market = URLRequest(url: URL(string: "https://api.kraken.com/0/public/OHLC?pair=XDGUSD&interval=60")!)
        DiagnosticHTTP.response(Data(#"{"error":[],"result":{"private":"never upload"}}"#.utf8), status: 200, request: market)
        DiagnosticHTTP.response(Data(#"{"error":["EAPI:Rate limit exceeded","EGeneral:Invalid arguments password='fixture-secret'"],"result":{"private":"never upload"}}"#.utf8), status: 200, request: market)
        DiagnosticHTTP.response(Data(#"{"error":[]}"#.utf8), status: 500, request: market)
        for _ in 0..<100 {
            if (await transport.events()).count >= 4 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let marketEvents = await transport.events().filter { $0.context["host"] == "api.kraken.com" }
        XCTAssertEqual(marketEvents.count, 1, "Only the invalid-argument failure remains reportable")
        XCTAssertFalse(marketEvents.contains { $0.error.message == "EAPI:Rate limit exceeded" })
        XCTAssertTrue(marketEvents.contains { $0.error.message.contains("EGeneral:Invalid arguments") })
        XCTAssertFalse(marketEvents.contains { $0.error.domain == "Oath.HTTP" && $0.error.code == 500 })
        let encoded = String(decoding: try DiagnosticEvent.encoder().encode(marketEvents), as: UTF8.self)
        XCTAssertFalse(encoded.contains("never upload")); XCTAssertFalse(encoded.contains("fixture-secret"))

        // The provider scope ends before attempt catches its error. The outer
        // best-effort boundary must own the ID so both reports still correlate.
        let failed: Int? = await OathDiagnostics.attempt("native_price",
            file: "OathDatabase/SuiSynchronizer.swift", function: "refresh", line: 40) {
            try await OathDiagnostics.withChain("sui") {
                let error = URLError(.badServerResponse)
                OathDiagnostics.record(error, component: "network", operation: "correlation_fixture")
                throw error
            }
        }
        XCTAssertNil(failed)
        for _ in 0..<100 {
            if (await transport.events()).count >= 6 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let correlated = await transport.events().filter {
            $0.operation == "native_price" || $0.operation == "correlation_fixture"
        }
        XCTAssertEqual(correlated.count, 2)
        XCTAssertTrue(correlated.allSatisfy { $0.operationID != nil && $0.context["chain"] == "sui" && $0.privacyFiltered })
        XCTAssertEqual(Set(correlated.compactMap(\.operationID)).count, 1)
        let boundary = try XCTUnwrap(correlated.first { $0.operation == "native_price" })
        XCTAssertEqual(boundary.sourceFile, "OathDatabase/SuiSynchronizer.swift")
        XCTAssertEqual(boundary.sourceLine, 40)

        let cancelled: Int? = await OathDiagnostics.attempt("cancelled_scope") { throw CancellationError() }
        let absent: Int? = await OathDiagnostics.attemptOptional("absent_scope") { nil }
        XCTAssertNil(cancelled); XCTAssertNil(absent)
        for deferral in [DiagnosticDeferral.publicMarketCooldown, .publicMarketCapacity, .publicMarketQuoteUnavailable, .tokenMetadataCooldown, .tokenMetadataCapacity] {
            let deferred: Int? = await OathDiagnostics.attempt("deferred_scope") { throw deferral }
            XCTAssertNil(deferred)
            OathDiagnostics.record(deferral, component: "prices", operation: "direct_deferral")
        }
        OathDiagnostics.record(ControlFlowFixture.waitingForProtectedData, component: "storage", operation: "protected_data_wait")
        try await Task.sleep(for: .milliseconds(50))
        await OathDiagnostics.flush()
        let finalEvents = await transport.events()
        XCTAssertEqual(finalEvents.count, 6, "Cancellation, optional absence and local request deferral are not new failures")
        XCTAssertNil(OathDiagnostics.operationID); XCTAssertNil(OathDiagnostics.chain)

        // One GraphQL response can repeat the same failure at many field paths.
        // Retain its multiplicity without filling the outbox with identical rows.
        let duplicateScope = UUID()
        // Use a nonexcluded provider failure: the reviewed Rujira rate-bucket
        // response is intentionally suppressed by the user's upload policy.
        let rateMessage = "Malformed resolver result. contact fixture@example.com"
        let repeated = Array(repeating: ["message": rateMessage, "path": ["private fixture path"]] as [String: Any], count: 9)
        let distinct: [[String: Any]] = [
            ["message": "Unknown field", "code": -1],
            ["message": rateMessage, "code": 422]
        ]
        var graphQL = URLRequest(url: URL(string: "https://api.rujira.network/api/graphql")!)
        graphQL.httpMethod = "POST"
        graphQL.httpBody = Data(#"{"query":"private fixture query"}"#.utf8)
        let body = try JSONSerialization.data(withJSONObject: ["errors": repeated + distinct])
        let nextResponse = try JSONSerialization.data(withJSONObject: ["errors": [["message": rateMessage]]])
        OathDiagnostics.$operationID.withValue(duplicateScope) {
            DiagnosticHTTP.response(body, status: 200, request: graphQL)
            DiagnosticHTTP.response(nextResponse, status: 200, request: graphQL)
        }
        // Allow detached admission tasks to finish before checking the complete
        // set, including any erroneous duplicate admissions.
        for _ in 0..<400 {
            await OathDiagnostics.flush()
            if await transport.events().filter({ $0.operationID == duplicateScope }).count >= 4 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let deduplicated = await transport.events().filter { $0.operationID == duplicateScope }
        XCTAssertEqual(deduplicated.count, 4, "Only identical entries within one response should be coalesced")
        let rates = deduplicated.filter { $0.error.code == -1 && $0.error.message.contains("Malformed resolver result") }
        XCTAssertEqual(rates.count, 2, "A later request must still report the original provider failure")
        XCTAssertEqual(rates.compactMap { $0.context["count"] }, ["9"])
        XCTAssertEqual(deduplicated.filter { $0.error.code == 422 }.count, 1)
        XCTAssertEqual(deduplicated.filter { $0.error.message == "Unknown field" }.count, 1)
        XCTAssertTrue(deduplicated.allSatisfy { $0.context["chain"] == "thorchain" && $0.context["http_status"] == "200" && $0.privacyFiltered })
        let safeJSON = String(decoding: try DiagnosticEvent.encoder().encode(deduplicated), as: UTF8.self)
        XCTAssertFalse(safeJSON.contains("fixture@example.com"))
        XCTAssertFalse(safeJSON.contains("private fixture"))
        let failureScope = UUID()
        OathDiagnostics.$operationID.withValue(failureScope) {
            OathDiagnostics.record(ControlFlowFixture.genuineFailure, component: "storage", operation: "real_failure")
            OathDiagnostics.record(NSError(domain: NSCocoaErrorDomain, code: 257), component: "storage", operation: "real_storage_failure")
        }
        for _ in 0..<200 {
            if await transport.events().filter({ $0.operationID == failureScope }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let actualFailures = await transport.events().filter { $0.operationID == failureScope }
        XCTAssertEqual(actualFailures.count, 2, "Only explicitly typed wait/cancellation cases are excluded; genuine storage failures still report")
        // Availability bursts must be discarded before consuming the bounded
        // reporter admission slots, or they can drop a real app error and emit
        // misleading overflow reports even though none will enter the outbox.
        let burstStart = await transport.events().count
        for _ in 0..<3_000 {
            OathDiagnostics.record(URLError(.timedOut), component: "network", operation: "excluded_burst")
            OathDiagnostics.record(NSError(domain: "Oath.HTTP", code: 429), component: "network", operation: "excluded_burst")
        }
        let marker = UUID()
        OathDiagnostics.$operationID.withValue(marker) {
            OathDiagnostics.record(NSError(domain: "Fixture.Storage", code: 1), component: "storage", operation: "real_error_after_burst")
        }
        for _ in 0..<200 {
            await OathDiagnostics.flush()
            if await transport.events().contains(where: { $0.operationID == marker }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(200))
        let burstReports = Array(await transport.events().dropFirst(burstStart))
        XCTAssertEqual(burstReports.filter { $0.operationID == marker }.count, 1, "The genuine error must not be lost to excluded traffic")
        XCTAssertFalse(burstReports.contains { $0.error.message == "diagnostics_queue_overflow" || $0.error.message == "diagnostics_retention_limit" }, "Excluded traffic must never manufacture a loss report")
        try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
    }
}
