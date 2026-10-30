import XCTest
import OathDiagnostics
@testable import OathAnkr

@MainActor final class CeloSendMainnetQuoteLiveTests:XCTestCase {
    func testRealMainnetANKRNativeNearMaxAndTokenQuotesWithoutSigning() async throws {
        guard ProcessInfo.processInfo.environment["OATH_CELO_SEND_MAINNET_QUOTES"]=="1",let path=ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"] else { throw XCTSkip("Opt-in public mainnet read-only quote validation") }
        let keys=try XCTUnwrap(PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:path)),format:nil) as? [String:String])
        let key=try XCTUnwrap(keys["AnkrAPIKey"])
        // Public holder fixture, no access to its signing credentials.
        let owner="0xf6436829cf96ea0f8bc49d300c536fcc4f84c4ed",recipient="0x000000000000000000000000000000000000dead"
        let inventory=try await IndexedEVMClient(chain:.celo,apiKey:key).inventory(owner:owner)
        let client=try EVMSendClient(network:.celo,endpoints:[URL(string:"https://rpc.ankr.com/celo")!.appendingPathComponent(key)])
        let native=try await client.balance(owner:owner,reference:"native")
        print("Celo mainnet: ANKR ordinary native")
        let ordinary=try await client.quote(sender:owner,recipient:recipient,reference:"native",decimals:18,amount:"1")
        XCTAssertEqual(ordinary.amount,"1");try await client.preflight(ordinary)
        print("Celo mainnet: ANKR near-Max native")
        let nearMax=try await client.quote(sender:owner,recipient:recipient,reference:"native",decimals:18,amount:EVMSendAmount.subtract(native,"1"))
        XCTAssertTrue(EVMSendAmount.less(nearMax.amount,nearMax.requestedAmount));try await client.preflight(nearMax)
        var tokens=0
        for decimals in [6,18] {
            print("Celo mainnet: ANKR token decimals=\(decimals)")
            let token=try XCTUnwrap(inventory.holdings.first { $0.token.reference != "native" && $0.token.decimals==decimals && $0.amount != nil && $0.amount != "0" })
            let quote=try await client.quote(sender:owner,recipient:recipient,reference:token.token.reference,decimals:decimals,amount:"1")
            XCTAssertEqual(quote.amount,"1");try await client.preflight(quote);tokens+=1
        }
        XCTAssertEqual(tokens,2)
        print("Celo mainnet: forced fallback")
        let fallback=try EVMSendClient(network:.celo,endpoints:[URL(string:"https://rpc.ankr.com/celo")!.appendingPathComponent(key),URL(string:"https://forno.celo.org")!],transport:CeloSendForcedFallback())
        let nativeFallback=try await fallback.quote(sender:owner,recipient:recipient,reference:"native",decimals:18,amount:"1")
        try await fallback.preflight(nativeFallback)
        let token=try XCTUnwrap(inventory.holdings.first { $0.token.reference != "native" && $0.token.decimals==6 && $0.amount != nil && $0.amount != "0" })
        let tokenFallback=try await fallback.quote(sender:owner,recipient:recipient,reference:token.token.reference,decimals:6,amount:"1")
        try await fallback.preflight(tokenFallback)
        print("CELO_MAINNET forced ANKR outage recovered through real chain-checked Forno native/token quote and preflight.")
        print("CELO_MAINNET ANKR ordinary/near-Max native and 6/18-decimal token quotes + preflight passed; no signing or broadcast.")
    }
}

private struct CeloSendForcedFallback:AnkrTransport {
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        if request.url?.host=="rpc.ankr.com" { return (Data(),503) }
        do {
            let response=try await AnkrHTTPTransport().send(request)
            if response.1 != 200 { print("Forno HTTP status=\(response.1)") }
            let json=try JSONDecoder().decode(SolanaJSON.self,from:response.0)
            for row in json.array ?? [json] where !row["error"].isNull {
                let event=DiagnosticEvent(error:DiagnosticFailure(row["error"]["message"].string ?? "RPC rejected"),component:"celo_send_test",operation:"fallback",context:[:],sessionID:UUID())
                let calls=(try? JSONDecoder().decode(SolanaJSON.self,from:request.httpBody ?? Data()).array) ?? []
                print("Forno RPC rejected methods=\(calls.compactMap { $0["method"].string }.joined(separator:",")): \(event.error.message)")
            }
            return response
        } catch {
            print("Forno transport failure: \(String(describing:error as? AnkrError))")
            throw error
        }
    }
}
