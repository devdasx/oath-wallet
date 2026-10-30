import XCTest
@testable import OathAnkr

/// Opt-in read-only production fee checks with public block senders, never a
/// user wallet or a signing key. The local probe supplies only public metadata.
@MainActor final class EVMSendReadOnlyLiveTests:XCTestCase {
    func testPublicMainnetFeeQuotes() async throws {
        guard let config=ProcessInfo.processInfo.environment["OATH_EVM_READ_CONFIG"] else { throw XCTSkip("Opt-in public read-only RPC checks") }
        let data=try Data(contentsOf:URL(fileURLWithPath:config))
        let credentials=try PropertyListDecoder().decode([String:String].self,from:data)
        let key=try XCTUnwrap(credentials["AnkrAPIKey"])
        let probes=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"/tmp/oath-evm-public-read.json"))) as? [[String:Any]])
        var passed=0,unavailable=0
        for probe in probes {
            let name=try XCTUnwrap(probe["chain"] as? String),network=try XCTUnwrap(EVMSendNetwork(rawValue:name))
            guard let path=probe["path"] as? String,let senders=probe["candidates"] as? [String],!senders.isEmpty else {
                print("EVM_READ_QUOTE chain=\(name) no_public_sample");unavailable+=1;continue
            }
            let endpoint=URL(string:"https://rpc.ankr.com")!.appendingPathComponent(path).appendingPathComponent(key)
            let client=try EVMSendClient(network:network,endpoints:[endpoint]+(network == .linea ? [URL(string:"https://rpc.linea.build")!]:[]))
            var success=false,last="none"
            for sender in senders {
                do {
                    let plan=try await client.quote(sender:sender,recipient:"0x000000000000000000000000000000000000dead",reference:"native",decimals:18,amount:"1")
                    try plan.validate()
                    XCTAssertEqual(plan.network,network);XCTAssertGreaterThan(plan.fee,0)
                    print("EVM_READ_QUOTE chain=\(name) success gas=\(plan.gasLimit) fee=\(plan.fee) legacy=\(plan.legacy)")
                    success=true;passed+=1;break
                } catch {
                    // Print only our finite domain enum, never underlying URL/params.
                    last=(error as? EVMSendError).map { String(describing:$0) } ?? "transport_or_decode"
                }
            }
            if !success { print("EVM_READ_QUOTE chain=\(name) unavailable=\(last)");unavailable+=1 }
        }
        print("EVM_READ_QUOTE_SUMMARY passed=\(passed) unavailable=\(unavailable) broadcasts=0")
        XCTAssertGreaterThan(passed,0)
    }
}
