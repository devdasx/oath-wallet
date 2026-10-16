import XCTest
import Combine
import CryptoKit
@testable import Schemas
@testable import HTTPClient
@testable import WalletConnectNetworking
@testable import WalletConnectKMS
@testable import WalletConnectRelay
import OathDiagnostics

@MainActor final class SDKTests: XCTestCase {
    func testStoredEventConstantsAndPayloadRoundTrip() throws {
        let initJSON=Data(#"{"eventId":"fixture","bundleId":"fixture.bundle","timestamp":1,"props":{"event":"INIT","type":"None","properties":{"client_id":"fixture-id","user_agent":"fixture-agent"}}}"#.utf8)
        let initial=try JSONDecoder().decode(Schemas.InitEvent.self,from:initJSON)
        let first=try JSONSerialization.jsonObject(with:JSONEncoder().encode(initial)) as! NSDictionary
        XCTAssertEqual(first,try JSONSerialization.jsonObject(with:initJSON) as? NSDictionary)
        let messageJSON=Data(#"{"eventId":"fixture","bundleId":"fixture.bundle","timestamp":1,"props":{"event":"SUCCESS","type":"publish","properties":{"correlation_id":42,"client_id":"fixture-id","direction":"sent"}}}"#.utf8)
        let message=try JSONDecoder().decode(Schemas.MessageEvent.self,from:messageJSON)
        XCTAssertEqual(try JSONSerialization.jsonObject(with:JSONEncoder().encode(message)) as? NSDictionary,try JSONSerialization.jsonObject(with:messageJSON) as? NSDictionary)
    }
    func testLegacyAuthAndSessionCodingKeysStayCompatible() throws {
        let params=try AuthRequestParams(domain:"fixture.invalid",chains:["eip155:1"],nonce:"fixture",uri:"https://fixture.invalid",nbf:nil,exp:nil,statement:nil,requestId:nil,resources:nil,methods:["personal_sign"])
        let encoded=try JSONEncoder().encode(params)
        let object=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        XCTAssertEqual(object["methods"] as? [String],["personal_sign"]);XCTAssertNil(object["legacyMethods"])
        XCTAssertEqual(try JSONDecoder().decode(AuthRequestParams.self,from:encoded).legacyMethods,["personal_sign"])
        let peer=AppMetadata(name:"Fixture",description:"Fixture",url:"https://fixture.invalid",icons:[],redirect:try AppMetadata.Redirect(native:"",universal:nil))
        let session=Session(topic:"fixture-topic",pairingTopic:"fixture-pairing",peer:peer,requiredNamespaces:[:],namespaces:[:],sessionProperties:nil,scopedProperties:nil,expiryDate:Date(timeIntervalSince1970:2_000_000_000))
        let data=try JSONEncoder().encode(session)
        let json=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        XCTAssertEqual(json["pairingTopic"] as? String,"fixture-pairing");XCTAssertNil(json["storedPairingTopic"])
        let reencoded=try JSONEncoder().encode(JSONDecoder().decode(Session.self,from:data))
        XCTAssertEqual(try JSONSerialization.jsonObject(with:reencoded) as? NSDictionary,json as NSDictionary)
    }
    func testOwnKeyWrappersCompareBytesWithoutForeignConformances() throws {
        let one=Data(repeating:1,count:32),two=Data(repeating:2,count:32)
        let a=try AgreementPrivateKey(rawRepresentation:one),b=try AgreementPrivateKey(rawRepresentation:two)
        XCTAssertEqual(a,try AgreementPrivateKey(rawRepresentation:one));XCTAssertNotEqual(a,b)
        XCTAssertEqual(a.publicKey,try AgreementPublicKey(rawRepresentation:a.publicKey.rawRepresentation));XCTAssertNotEqual(a.publicKey,b.publicKey)
        let x=try SigningPrivateKey(rawRepresentation:one),y=try SigningPrivateKey(rawRepresentation:two)
        XCTAssertEqual(x,try SigningPrivateKey(rawRepresentation:one));XCTAssertNotEqual(x,y)
        XCTAssertEqual(x.publicKey,try SigningPublicKey(rawRepresentation:x.publicKey.rawRepresentation));XCTAssertNotEqual(x.publicKey,y.publicKey)
        let message=Data("fixture-message".utf8)
        XCTAssertTrue(x.publicKey.isValid(signature:try x.signature(message),for:message))
    }
    func testVerificationFactoryIsStatelessAcrossConcurrentCalls() async throws {
        let factory=VerifyContextFactory()
        await withTaskGroup(of:VerifyContext.self) { group in
            for _ in 0..<100 { group.addTask { factory.createVerifyContext(origin:"https://fixture.invalid",domain:"fixture.invalid",isScam:false,isVerified:true) } }
            for await context in group { XCTAssertEqual(context.validation,.valid) }
        }
        XCTAssertEqual(factory.createVerifyContext(origin:"https://bad.invalid",domain:"fixture.invalid",isScam:false,isVerified:true).validation,.invalid)
        XCTAssertEqual(factory.createVerifyContext(origin:"https://fixture.invalid",domain:"fixture.invalid",isScam:true,isVerified:true).validation,.scam)
        XCTAssertEqual(factory.createVerifyContextForLinkMode(redirectUniversalLink:"https://evilfixture.invalid",domain:"https://fixture.invalid").validation,.invalid)
    }
    func testHTTPDecodeHostUpdateAndStatusFailure() async throws {
        HTTPFixture.reset()
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[HTTPFixture.self]
        let session=URLSession(configuration:config);defer { session.invalidateAndCancel() }
        let client=HTTPNetworkClient(host:"one.invalid",session:session)
        let value=try await client.request(ReferenceReply.self,at:Service(path:"/ok"))
        XCTAssertEqual(value.value,"fixture") // Deliberately not Sendable.
        await client.updateHost(host:"two.invalid")
        try await client.request(service:Service(path:"/empty"))
        XCTAssertEqual(HTTPFixture.hosts,["one.invalid","two.invalid"])
        do { try await client.request(service:Service(path:"/failure"));XCTFail("Accepted 503") }
        catch { XCTAssertEqual(error as? HTTPError,.badStatusCode(503)) }
    }
    func testSDKHTTPFailuresUseSharedPrivateDiagnosticsAndCancellationIsExcluded() async throws {
        let transport=SDKDiagnosticCapture()
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        defer { try? FileManager.default.removeItem(at:file) }
        OathDiagnostics.configure(file:file,transport:transport)
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[HTTPFixture.self]
        let session=URLSession(configuration:config);defer { session.invalidateAndCancel() }
        let client=HTTPNetworkClient(host:"fixture.invalid",session:session)
        let work=Task { try await client.request(service:Service(path:"/wait")) }
        try await Task.sleep(nanoseconds:10_000_000);work.cancel()
        do { try await work.value } catch { XCTAssertTrue(error is CancellationError) }
        await OathDiagnostics.flush()
        let before=await transport.events
        XCTAssertTrue(before.isEmpty,"User cancellation is not an app failure")
        do { try await client.request(service:Service(path:"/failure"));XCTFail("Accepted 503") } catch {}
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await !transport.events.isEmpty { break }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        let events=await transport.events
        XCTAssertEqual(events.count,1)
        let event=try XCTUnwrap(events.first)
        XCTAssertEqual(event.error.code,503);XCTAssertNotNil(event.operationID)
        XCTAssertEqual(event.context["host"],"fixture.invalid")
        let report=String(decoding:try JSONEncoder().encode(events),as:UTF8.self)
        XCTAssertFalse(report.contains("https://fixture.invalid"))
        XCTAssertFalse(report.contains("/failure"))
        let background=BackgroundFailureFixture()
        background.reconnect()
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await transport.events.contains(where: { $0.operation == "pairing_resubscribe" }) { break }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        let updated=await transport.events
        let failure=try XCTUnwrap(updated.first { $0.operation == "pairing_resubscribe" })
        XCTAssertEqual(failure.error.domain,"Fixture.Transport")
        XCTAssertEqual(failure.error.code,503);XCTAssertNotNil(failure.operationID)
        XCTAssertNotEqual(failure.operationID,event.operationID)
        let backgroundReport=String(decoding:try JSONEncoder().encode(failure),as:UTF8.self)
        XCTAssertFalse(backgroundReport.contains("private-path"));XCTAssertFalse(backgroundReport.contains("fixture-secret"))
        withExtendedLifetime(background) {}

        XCTAssertFalse(report.contains("\"value\":\"fixture\""))
    }
    func testHTTPCancellationStopsTheUnderlyingRequest() async throws {
        HTTPFixture.reset()
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[HTTPFixture.self]
        let session=URLSession(configuration:config);defer { session.invalidateAndCancel() }
        let client=HTTPNetworkClient(host:"fixture.invalid",session:session)
        let work=Task { try await client.request(service:Service(path:"/wait")) }
        for _ in 0..<200 where HTTPFixture.hosts.isEmpty { try await Task.sleep(nanoseconds:5_000_000) }
        XCTAssertEqual(HTTPFixture.hosts.count,1)
        work.cancel()
        // The URLProtocol watchdog returns after 800 ms in the broken callback
        // implementation, so this test cannot leave the host suite hanging.
        let start=Date()
        do { try await work.value;XCTFail("Cancellation was ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start),0.6)
        XCTAssertGreaterThan(HTTPFixture.stops,0)
    }
}

private final class ReferenceReply: Decodable { let value:String }
private struct Service: HTTPService {
    let path:String
    var scheme:String { "https" }
    var method:HTTPMethod { .get }
    var body:Data? { nil }
    var queryParameters:[String:String]? { nil }
    var additionalHeaderFields:[String:String]? { nil }
}
private final class HTTPFixture: URLProtocol, @unchecked Sendable {
    private static let lock=NSLock()
    private static var recordedHosts=[String](), stopped=0
    private let stateLock=NSLock()
    private var cancelled=false
    static var hosts:[String] { lock.withLock { recordedHosts } }
    static var stops:Int { lock.withLock { stopped } }
    static func reset() { lock.withLock { recordedHosts=[];stopped=0 } }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.recordedHosts.append(request.url!.host!) }
        if request.url!.path=="/wait" {
            DispatchQueue.global().asyncAfter(deadline:.now()+0.8) { self.finish() }
        } else { finish() }
    }
    private func finish() {
        guard stateLock.withLock({ !cancelled }) else { return }
        let response=HTTPURLResponse(url:request.url!,statusCode:request.url!.path=="/failure" ? 503:200,httpVersion:nil,headerFields:nil)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(#"{"value":"fixture"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { stateLock.withLock { cancelled=true }; Self.lock.withLock { Self.stopped+=1 } }
}

private actor SDKDiagnosticCapture: DiagnosticTransport {
    var events=[DiagnosticEvent]()
    func upload(_ events:[DiagnosticEvent]) async throws { self.events += events }
}
