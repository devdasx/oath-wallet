import XCTest
@testable import OathAnkr

/// Opt-in, existing isolated TESTNET fixtures only. No production credentials,
/// keys or addresses are printed. Submission timing excludes finality polling.
final class BroadcastAcknowledgementLiveTests:XCTestCase {
    private func fixture(_ name:String) throws -> NearJSON {
        guard ProcessInfo.processInfo.environment["OATH_BROADCAST_LIVE"] == "1",
              let path=ProcessInfo.processInfo.environment[name] else { throw XCTSkip("Opt-in funded testnet fixture required") }
        return try JSONDecoder().decode(NearJSON.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
    }
    private func report(_ chain:String,_ elapsed:Duration) {
        let c=elapsed.components,ms=Double(c.seconds)*1000+Double(c.attoseconds)/1e15
        print("BROADCAST_ACK chain=\(chain) milliseconds=\(Int(ms)) finality_checked_separately=true")
    }
    func testStellarAcknowledgesThenConfirms() async throws {
        let f=try fixture("OATH_STELLAR_TESTNET_FIXTURE"),c=try StellarSendClient(network:.testnet)
        var key=try XCTUnwrap(Data(base64Encoded:XCTUnwrap(f["sender"]["seed"].string)));defer {key.resetBytes(in:0..<key.count)}
        let p=try await c.quote(sender:XCTUnwrap(f["sender"]["address"].string),recipient:XCTUnwrap(f["recipient"]["address"].string),reference:"native",decimals:7,amount:"10000",memo:.init(type:.id,value:"0"))
        let s=try StellarSendCrypto.sign(p,privateKey:key),start=ContinuousClock.now
        var receipt=try await c.submit(s,plan:p,reconcileFirst:false)
        report("stellar-testnet",start.duration(to:.now));XCTAssertEqual(receipt.outcome,.accepted);XCTAssertNil(receipt.ledger)
        for _ in 0..<30 where [.accepted,.unknown].contains(receipt.outcome) {
            try await Task.sleep(for:.seconds(1));receipt=try await c.status(s,plan:p)
        }
        XCTAssertEqual(receipt.outcome,.confirmed);XCTAssertNotNil(receipt.fee)
    }
    func testXRPLAcknowledgeThenConfirm() async throws {
        let f=try fixture("OATH_XRPL_TESTNET_FIXTURE"),c=try XrplSendClient(network:.testnet)
        var key=try TronIdentity.hex(String(XCTUnwrap(f["sender"]["privateKey"].string).suffix(64)));defer {key.resetBytes(in:0..<key.count)}
        let p=try await c.quote(sender:XCTUnwrap(f["sender"]["address"].string),recipient:XCTUnwrap(f["recipient"]["address"].string),reference:"native",amount:"100",destinationTag:0)
        let s=try XrplSendCrypto.sign(p,privateKey:key),start=ContinuousClock.now
        var receipt=try await c.submit(s,plan:p,reconcileFirst:false)
        report("xrpl-testnet",start.duration(to:.now));XCTAssertEqual(receipt.outcome,.accepted);XCTAssertNil(receipt.ledger)
        for _ in 0..<30 where [.accepted,.unknown].contains(receipt.outcome) {
            try await Task.sleep(for:.seconds(1));receipt=try await c.status(s,plan:p)
        }
        XCTAssertEqual(receipt.outcome,.confirmed);XCTAssertNotNil(receipt.fee)
    }
    func testNearAcknowledgeThenConfirm() async throws {
        let f=try fixture("OATH_NEAR_TESTNET_FIXTURE"),c=try NearSendClient(network:.testnet)
        var key=try XCTUnwrap(Data(base64Encoded:XCTUnwrap(f["seed"].string)));defer {key.resetBytes(in:0..<key.count)}
        let recipient=try XCTUnwrap(f["recipients"].array?.first?["address"].string)
        let p=try await c.quote(sender:XCTUnwrap(f["sender"].string),recipient:recipient,reference:"native",publicKey:NearSendCrypto.publicKey(privateKey:key),decimals:24,amount:"10000000000000000000")
        let s=try NearSendCrypto.sign(p,privateKey:key),start=ContinuousClock.now
        var receipt=try await c.submit(s,plan:p,reconcileFirst:false)
        report("near-testnet",start.duration(to:.now));XCTAssertEqual(receipt.outcome,.accepted);XCTAssertNil(receipt.block)
        for _ in 0..<30 where [.accepted,.unknown].contains(receipt.outcome) {
            try await Task.sleep(for:.seconds(1));receipt=try await c.status(s,plan:p)
        }
        XCTAssertEqual(receipt.outcome,.confirmed);XCTAssertNotNil(receipt.fee)
    }
}
