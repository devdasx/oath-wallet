import XCTest
@testable import OathAnkr

final class NearSendMainnetTests:XCTestCase,@unchecked Sendable {
    func testReadOnlyAppPrimaryMainnetQuote() async throws {
        guard let path=ProcessInfo.processInfo.environment["OATH_NEAR_MAINNET_RPC_PLIST"] else { throw XCTSkip("Opt-in read-only app RPC validation") }
        let settings=try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:path)),format:nil) as! [String:Any]
        let transport=NearReadOnlyProbe(),client=try NearSendClient(apiKey:try XCTUnwrap(settings["AnkrAPIKey"] as? String),transport:transport)
        let sender="root.near",header=try await client.finalBlock(),block=try NearIdentity.hash(header["hash"])
        let keys=try await client.query(["request_type":.string("view_access_key_list"),"account_id":.string(sender)],block:block)
        let key=try XCTUnwrap(keys["keys"].array?.first(where:{$0["access_key"]["permission"].string=="FullAccess" && $0["public_key"].string?.hasPrefix("ed25519:")==true}))
        let pub=try SuiSendCrypto.unbase58(String(key["public_key"].string!.dropFirst(8)))
        let native=try await client.quote(sender:sender,recipient:"mob.near",reference:"native",publicKey:pub,decimals:24,amount:"1")
        XCTAssertEqual(native.network,.mainnet);XCTAssertEqual(native.amount,"1");XCTAssertNotEqual(native.fee,"0")
        try await client.preflight(native)
        // Fresh implicit-recipient quote must work with ANKR's missing-account envelope.
        let fresh=try await client.quote(sender:sender,recipient:String(repeating:"a1",count:32),reference:"native",publicKey:pub,decimals:24,amount:"1")
        XCTAssertEqual(fresh.amount,"1")
        // Read the six-decimal FT interfaces without relying on a public account
        // retaining a particular token balance. Never sign or broadcast on mainnet.
        let latest=try await client.finalBlock(),tokenBlock=try NearIdentity.hash(latest["hash"])
        let metadata=try await client.call("usdt.tether-token.near","ft_metadata",block:tokenBlock)
        XCTAssertEqual(metadata["decimals"].integer,6)
        _ = try NearIdentity.amount(await client.call("usdt.tether-token.near","ft_balance_of",["account_id":.string(sender)],block:tokenBlock))
        let storage=try await client.call("usdt.tether-token.near","storage_balance_of",["account_id":.string(sender)],block:tokenBlock)
        if !storage.isNull { _ = try NearIdentity.amount(storage["total"]) }
        let hosts=await transport.hosts
        XCTAssertEqual(hosts,["rpc.ankr.com"],"The app's configured primary must support the complete quote")
    }
}
private actor NearReadOnlyProbe:AnkrTransport {
    var hosts=Set<String>()
    let base=AnkrHTTPTransport()
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let j=try JSONDecoder().decode(NearJSON.self,from:request.httpBody!)
        guard ["status","block","query","gas_price","EXPERIMENTAL_protocol_config"].contains(j["method"].string ?? "") else { throw NearSendError.configuration }
        hosts.insert(request.url!.host!)
        return try await base.send(request)
    }
}
