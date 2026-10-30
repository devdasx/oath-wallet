import XCTest
import Network
@testable import OathDiagnostics

private actor AvailabilityCapture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

private struct TypedAvailabilityFixture: DiagnosticAvailabilityError, CustomStringConvertible {
    let isDiagnosticAvailabilityFailure: Bool
    var description: String { XCTFail("Admission must not format an error payload"); return "private fixture" }
}

final class AvailabilityPolicyTests: XCTestCase, @unchecked Sendable {
    func testSerializedRPC429IsExcludedWithoutHidingOtherCodesOrRuntimeReports() async throws {
        for context in [[:], ["chain":"arc"], ["chain":"robinhood"]] {
            XCTAssertTrue(DiagnosticUploadPolicy.excludes(event("OathAnkr.AnkrError",1,"rpc(429)",context:context)))
        }
        for message in ["rpc(13)","rpc(403)","rpc(-32000)","rpc(-32603)","rpc(429) extra"] {
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("OathAnkr.AnkrError",1,message)))
        }
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("Fixture.Storage",1,"rpc(429)")))
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("OathAnkr.AnkrError",1,"rpc(429)",severity:"fatal")))
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("OathAnkr.AnkrError",1,"rpc(429)",component:"runtime")))
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("OathAnkr.AnkrError",1,"rpc(429)",context:["chain":"iotex","stage":"broadcast"],component:"evm_send")))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("outbox.json")
        defer { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
        let bug = event("OathAnkr.AnkrError",1,"rpc(13)")
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try DiagnosticEvent.encoder().encode([event("OathAnkr.AnkrError",1,"rpc(429)"),bug]).write(to:file)
        let capture = AvailabilityCapture(), box = DiagnosticOutbox(file:file,transport:capture)
        await box.flush()
        let sent = await capture.events
        XCTAssertEqual(sent.map(\.id),[bug.id])
    }
    func testChilizFinalSendOutagesAreRetainedWithoutChangingBackgroundExclusions() async throws {
        let context = ["chain": "chiliz", "stage": "broadcast"]
        let failure = URLError(.timedOut)
        XCTAssertFalse(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(failure, component: "evm_send", severity: "error", context: context, runtimeReport: nil))
        let report = DiagnosticEvent(error: failure, component: "evm_send", operation: "broadcast", context: context, sessionID: UUID())
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(report))
        XCTAssertTrue(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(failure, component: "evm_send", severity: "error", context: ["chain": "chiliz"], runtimeReport: nil))
        XCTAssertTrue(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(failure, component: "evm_send", severity: "error", context: ["chain": "ethereum", "stage": "broadcast"], runtimeReport: nil))
        let reports = AvailabilityCapture()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("outbox.json")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let queue = DiagnosticOutbox(file: path, transport: reports)
        let accepted = await queue.enqueue(report)
        XCTAssertTrue(accepted)
        await queue.flush()
        let events = await reports.events
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events.allSatisfy { $0.privacyFiltered && $0.context["chain"] == "chiliz" })
    }

    func testRelayTimeoutIsExcludedButOtherSDKAndRuntimeFailuresRemain() async throws {
        let timeout = event("WalletConnectRelay.RelayError",0,"requestTimeout")
        XCTAssertTrue(DiagnosticUploadPolicy.excludes(timeout))
        for report in [event("Other.RelayError",0,"requestTimeout"),
                       event("WalletConnectRelay.RelayError",0,"requestTimeout: unknown payload"),
                       event("WalletConnectRelay.RelayError",0,"invalidResponse"),
                       event("WalletConnectRelay.RelayError",0,"requestTimeout",severity:"fatal"),
                       event("WalletConnectRelay.RelayError",0,"requestTimeout",component:"runtime")] {
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(report))
        }
        let reports = AvailabilityCapture()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at:path) }
        let queue = DiagnosticOutbox(file:path,transport:reports)
        let accepted = await queue.enqueue(timeout)
        XCTAssertTrue(accepted,"Exclusion must acknowledge consumption without retrying")
        await queue.flush()
        let uploaded = await reports.events
        XCTAssertTrue(uploaded.isEmpty)
        let pending = await queue.status().pending
        XCTAssertEqual(pending,0)
    }
    func testExactStaleCoinbaseQuoteIsAvailabilityButUnrelated404sRemain() {
        let message = "rpc error: code = NotFound desc = rate found but was stale"
        let context = ["host": "api.coinbase.com", "http_status": "404"]
        let error = NSError(domain: "Oath.Provider", code: 5, userInfo: [NSLocalizedDescriptionKey: message])
        XCTAssertTrue(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(error, component: "network", severity: "error", context: context, runtimeReport: nil))
        XCTAssertTrue(DiagnosticUploadPolicy.excludes(event("Oath.Provider", 5, message, context: context)))
        for changed in [[:], ["host": "other.example", "http_status": "404"], ["host": "api.coinbase.com", "http_status": "400"]] {
            XCTAssertFalse(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(error, component: "network", severity: "error", context: changed, runtimeReport: nil))
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("Oath.Provider", 5, message, context: changed)))
        }
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("Oath.Provider", 6, message, context: context)))
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("Oath.Provider", 5, "not found", context: context)))
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("OathAnkr.AnkrError", 0, "http(404)", context: context)))
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("Oath.Provider", 5, message, context: context, component: "runtime", severity: "fatal")))
    }
    func testNetworkFrameworkPOSIXFailuresFollowSocketPolicyWithoutHidingOtherCases() {
        for code: POSIXErrorCode in [.ENETDOWN, .ENETUNREACH, .ECONNABORTED, .ECONNRESET, .ENOTCONN, .ETIMEDOUT, .ECONNREFUSED, .EHOSTDOWN, .EHOSTUNREACH] {
            let error = NWError.posix(code)
            XCTAssertTrue(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(error, component: "electrum", severity: "error", context: [:], runtimeReport: nil))
            let report = DiagnosticEvent(error: error, component: "electrum", operation: "connection", sessionID: UUID())
            XCTAssertTrue(DiagnosticUploadPolicy.excludes(report), "\(report.error)")
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(DiagnosticEvent(error: error, component: "runtime", operation: "crash", severity: "fatal", sessionID: UUID())))
        }
        for error in [NWError.posix(.EACCES), NWError.posix(.EINVAL), NWError.dns(57), NWError.tls(57)] {
            XCTAssertFalse(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(error, component: "electrum", severity: "error", context: [:], runtimeReport: nil))
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(DiagnosticEvent(error: error, component: "electrum", operation: "connection", sessionID: UUID())))
        }
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("Network.NWError", 57, "POSIXErrorCode(rawValue: 22): Invalid argument")))
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("Network.NWError", 57, "unrecognized wrapper")))
    }
    private func event(_ domain: String, _ code: Int = 0, _ message: String = "fixture",
                       context: [String: String] = [:], component: String = "provider",
                       severity: String = "error", runtime: String? = nil) -> DiagnosticEvent {
        .init(error: NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message]),
              component: component, operation: "availability_fixture", severity: severity,
              context: context, runtimeReport: runtime, sessionID: UUID())
    }

    func testAdmissionUsesTypedCodesWithoutFormattingAndPreservesRuntimeFailures() {
        let unavailable = TypedAvailabilityFixture(isDiagnosticAvailabilityFailure: true)
        XCTAssertTrue(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(unavailable, component: "provider", severity: "error", context: [:], runtimeReport: nil))
        for (component, severity, runtime) in [("runtime", "error", nil as String?), ("provider", "fatal", nil), ("provider", "error", "{}")] {
            XCTAssertFalse(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(unavailable, component: component, severity: severity, context: [:], runtimeReport: runtime))
        }
        XCTAssertFalse(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(TypedAvailabilityFixture(isDiagnosticAvailabilityFailure: false), component: "provider", severity: "error", context: [:], runtimeReport: nil))
        let storage = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])
        XCTAssertFalse(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(storage, component: "storage", severity: "error", context: [:], runtimeReport: nil))
    }

    func testHTTPAndURLFailuresAreExcludedAcrossServicesAndChains() {
        for context in [[:], ["chain": "arc"], ["chain": "robinhood"]] {
            for status in [408, 429, 500, 502, 503, 504, 520, 599] {
                XCTAssertTrue(DiagnosticUploadPolicy.excludes(event("Oath.HTTP", status, context: context)))
                XCTAssertTrue(DiagnosticUploadPolicy.excludes(event("Oath.Provider", -1, context: context.merging(["http_status": String(status)]) { $1 })))
                XCTAssertTrue(DiagnosticUploadPolicy.excludes(event("OathAnkr.AnkrError", 0, "http(\(status))", context: context)))
            }
            for code in [-1001, -1003, -1004, -1005, -1006, -1009, -1018, -1019, -1020, -1200, -1201, -1202, -1203, -1204, -1205, -1206] {
                XCTAssertTrue(DiagnosticUploadPolicy.excludes(event(NSURLErrorDomain, code, context: context)), "\(code)")
            }
        }
        for code: POSIXErrorCode in [.ENETDOWN, .ENETUNREACH, .ECONNRESET, .ECONNREFUSED, .ETIMEDOUT] {
            XCTAssertTrue(DiagnosticUploadPolicy.excludes(event(NSPOSIXErrorDomain, Int(code.rawValue))))
        }
    }

    func testKnownWrappersAndProviderEnvelopesDoNotLeakThrough() {
        for domain in ["AnkrError", "TonError", "TronError", "NearError", "AptosError", "SuiError",
                       "XrplError", "StellarError", "SolanaError", "ThorchainError", "EVMSendError", "TonSendError"] {
            XCTAssertTrue(DiagnosticUploadPolicy.excludes(event("OathAnkr." + domain, 7, "transport")))
        }
        for (domain, message) in [("OathAnkr.ThorchainError", "rateLimited"),
                                  ("OathAnkr.SuiError", "resourceExhausted"),
                                  ("OathMarketData.MarketDataError", "rateLimited"),
                                  ("OathMarketData.MarketDataError", "unavailable"),
                                  ("OathAnkr.TokenDiscoveryError", "http(429)"),
                                  ("OathTokenImages.ArtworkError", "http(503)"),
                                  ("OathBitcoin.BitcoinError", "timeout"),
                                  ("OathBitcoin.BitcoinError", "tls"),
                                  ("OathBitcoin.BitcoinError", "disconnected"),
                                  ("OathBitcoin.BitcoinError", "unavailable"),
                                  ("OathAnkr.AnkrError", "rpc(-32005)"),
                                  ("OathAnkr.XrplError", #"rpc("tooBusy")"#),
                                  ("OathAnkr.XrplSendError", #"rpc("slowDown")"#),
                                  ("OathAnkr.XrplError", #"rpc("noNetwork")"#)] {
            XCTAssertTrue(DiagnosticUploadPolicy.excludes(event(domain, 1, message)), message)
        }
        for message in ["Too many requests", "rate limit exceeded", "rate bucket full (5000). bucket drains 500/s.\nprivate@example.com",
                        "EAPI:Rate limit exceeded", "EGeneral:Too many requests", "service unavailable", "Gateway Timeout",
                        "connection refused", "connection reset by peer", "request timed out", "tooBusy", "noNetwork"] {
            XCTAssertTrue(DiagnosticUploadPolicy.excludes(event("Oath.Provider", -1, message)), message)
        }
        XCTAssertTrue(DiagnosticUploadPolicy.excludes(event("Oath.Provider", -32005)))
    }

    func testRPCNormalizationNeverPreservesArbitraryQuotedText() throws {
        let unknown = event("OathAnkr.XrplError", 1, #"rpc("fixture-private-value")"#)
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(unknown))
        XCTAssertFalse(unknown.error.message.contains("fixture-private-value"))
        XCTAssertNil(DiagnosticAvailabilityPolicy.normalizedPublicCode(domain: "Other", message: #"rpc("tooBusy")"#))
        XCTAssertNil(DiagnosticAvailabilityPolicy.normalizedPublicCode(domain: "OathAnkr.XrplError", message: #"rpc("tooBusy secret")"#))
    }

    func testValidationAuthenticationStorageAndRuntimeErrorsStayReportable() {
        for status in [400, 401, 403, 404, 409, 422] {
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("Oath.HTTP", status)))
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("OathAnkr.AnkrError", 0, "http(\(status))")))
        }
        for code in [-1000, -1002, -1011, -1022] {
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(event(NSURLErrorDomain, code)))
        }
        for (domain, message) in [("OathTokenImages.ArtworkError", "invalidImage"), ("OathTokenImages.ArtworkError", "http(404)"),
                                  ("OathAnkr.AnkrError", "invalidResponse"), ("OathAnkr.TonError", "wrongOwner"),
                                  ("OathAnkr.ThorchainError", "staleHeight"), ("OathAnkr.AnkrError", "rpc(-32000)"),
                                  ("OathAnkr.AnkrError", "rpc(-32603)"), ("OathAnkr.SuiError", "malformed"),
                                  ("OathAnkr.PermissionError", "unavailable"), ("OathMarketData.MarketDataError", "invalidResponse"),
                                  ("GRDB.DatabaseError", "connection refused"),
                                   ("CryptoKit.CryptoKitError", "rate limit exceeded"),
                                  ("Oath.Provider", "execution reverted: rate limit exceeded"),
                                  ("Oath.Provider", "Server error"), ("Oath.Provider", "invalid response field: connection refused")] {
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(event(domain, 1, message)), "\(domain): \(message)")
        }
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event(NSPOSIXErrorDomain, Int(POSIXErrorCode.EACCES.rawValue))))
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("NSCocoaErrorDomain", 513, context: ["http_status": "503"])))
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("Oath.HTTP", 503, severity: "fatal")))
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("Oath.HTTP", 503, runtime: "{}")))
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("Oath.HTTP", 503, component: "runtime")))
        let wrapper = DiagnosticEvent(error: NSError(domain: "NSCocoaErrorDomain", code: 4864,
            userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)]), component: "storage", operation: "decode", sessionID: UUID())
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(wrapper), "An underlying timeout must not hide a storage/decoding failure")
    }

    func testNewAvailabilityReportsNeverPersistUploadOrProduceRetentionLoss() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("outbox.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let capture = AvailabilityCapture(), box = DiagnosticOutbox(file: file, transport: capture, limit: 2)
        for _ in 0..<300 {
            let accepted = await box.enqueue(event("Oath.HTTP", 503))
            XCTAssertTrue(accepted)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        await box.flush()
        let status = await box.status(), sent = await capture.events
        XCTAssertEqual(status.pending, 0); XCTAssertEqual(status.dropped, 0); XCTAssertTrue(sent.isEmpty)
    }

    func testReopenedOutboxRemovesOldAvailabilityReportsButSendsActualBug() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("outbox.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let bug = event("OathAnkr.AnkrError", 4, "invalidResponse")
        let saved = [event(NSURLErrorDomain, -1200), event("Oath.HTTP", 429, context: ["service": "fixture"]),
                     event("OathAnkr.AnkrError", 7, "transport", context: ["chain": "arc"]), bug]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DiagnosticEvent.encoder().encode(saved).write(to: file)
        let capture = AvailabilityCapture(), box = DiagnosticOutbox(file: file, transport: capture)
        let status = await box.status()
        XCTAssertEqual(status.pending, 1); XCTAssertEqual(status.dropped, 0)
        let persisted = try DiagnosticEvent.decoder().decode([DiagnosticEvent].self, from: Data(contentsOf: file))
        XCTAssertEqual(persisted.map(\.id), [bug.id])
        await box.flush()
        let sent = await capture.events
        XCTAssertEqual(sent.map(\.id), [bug.id])
    }
}

extension AvailabilityPolicyTests {
    func testPolkadotSendFailuresRetainSafeContextAndRedactWalletAndTransactionData() async throws {
        let context=["chain":"polkadot","stage":"broadcast","method":"author_submitExtrinsic"]
        XCTAssertFalse(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(URLError(.timedOut),component:"polkadot_send",severity:"error",context:context,runtimeReport:nil))
        XCTAssertTrue(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(URLError(.timedOut),component:"polkadot_send",severity:"error",context:["chain":"polkadot"],runtimeReport:nil))
        let address="5CbcYHf3NmZshB1qKwrP7o8GDA4pAoaSbMEM29PV5W13tBWP"
        let raw="0x"+String(repeating:"ab",count:256)
        let report=DiagnosticEvent(error:NSError(domain:"Oath.Provider",code:1010,userInfo:[NSLocalizedDescriptionKey:"Invalid Transaction \(address) \(raw)"]),component:"polkadot_send",operation:"broadcast",context:context,sessionID:UUID())
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(report))
        let encoded=String(decoding:try JSONEncoder().encode(report),as:UTF8.self)
        XCTAssertFalse(encoded.contains(address));XCTAssertFalse(encoded.contains(raw));XCTAssertTrue(encoded.contains("polkadot"))
        let transport=AvailabilityCapture(),folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let queue=DiagnosticOutbox(file:folder.appendingPathComponent("outbox.json"),transport:transport)
        let accepted=await queue.enqueue(report);XCTAssertTrue(accepted);await queue.flush()
        let events=await transport.events;XCTAssertEqual(events.count,1);XCTAssertTrue(events[0].privacyFiltered)
    }
}
