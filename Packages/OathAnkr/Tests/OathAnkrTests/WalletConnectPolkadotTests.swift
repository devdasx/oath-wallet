import XCTest
import CryptoKit
@testable import OathAnkr

final class WalletConnectPolkadotTests: XCTestCase, @unchecked Sendable {
    struct Fixtures: Decodable {
        struct Vector: Decodable { let kind:String; let account:String; let params:TronJSON; let signature:String; let extrinsic:String; let payload:String }
        struct Message: Decodable { let account:String; let data:String; let wrapped:String; let signature:String }
        let vectors:[Vector]; let message:Message
    }
    func fixtures() throws -> Fixtures {
        try JSONDecoder().decode(Fixtures.self,from:Data(contentsOf:Bundle.module.url(forResource:"WalletConnectPolkadotVectors",withExtension:"json",subdirectory:"Fixtures")!))
    }
    func request(_ params:TronJSON, account:String, method:String = "polkadot_signTransaction", chain:String = PolkadotConnectNetwork.paseo.chain) throws -> WalletConnectPolkadotRequest {
        try .init(method:method,chain:chain,account:account,params:JSONEncoder().encode(params))
    }
    func review(_ request:WalletConnectPolkadotRequest, date:Date = .now) -> PolkadotConnectReview {
        .init(request:request,callName:"test",details:"{}",fee:"1",metadataHash:"test",recipient:nil,nativeAmount:nil,createdAt:date)
    }
    func testIndependentSDKPayloadSignaturesAndExtrinsics() throws {
        for f in try fixtures().vectors {
            let r = try request(f.params,account:f.account)
            let expected = try PolkadotIdentity.bytes(f.payload)
            XCTAssertEqual(try r.encoded().payload,expected.count > 256 ? SuiSendCrypto.hash(expected) : expected,f.kind)
            let signed = try r.sign(privateKey:Data(repeating:1,count:32),review:review(r))
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation:PolkadotIdentity.publicKey(f.account))
            let payload = try r.encoded().payload
            XCTAssertTrue(publicKey.isValidSignature(try PolkadotIdentity.bytes(f.signature).dropFirst(),for:payload),f.kind)
            let signature = try PolkadotIdentity.bytes(signed["signature"].string!)
            XCTAssertEqual(signature.first,0)
            XCTAssertTrue(publicKey.isValidSignature(signature.dropFirst(),for:payload),f.kind)
            XCTAssertEqual(try r.extrinsic(signature:PolkadotIdentity.bytes(f.signature).dropFirst()),try PolkadotIdentity.bytes(f.extrinsic),f.kind)
            XCTAssertEqual(signed["signedTransaction"].string,try PolkadotIdentity.hex(r.extrinsic(signature:signature.dropFirst())),f.kind)
        }
    }
    func testWrappedMessagesAndOwnerBinding() throws {
        let f = try fixtures().message
        for data in [f.data,f.wrapped] {
            let params:TronJSON = .object(["address":.string(f.account),"data":.string(data),"type":.string("bytes")])
            let r = try request(params,account:f.account,method:"polkadot_signMessage")
            XCTAssertEqual(r.message,try PolkadotIdentity.bytes(f.wrapped))
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation:PolkadotIdentity.publicKey(f.account))
            XCTAssertTrue(publicKey.isValidSignature(try PolkadotIdentity.bytes(f.signature),for:r.message!))
            XCTAssertTrue(publicKey.isValidSignature(try PolkadotIdentity.bytes(r.sign(privateKey:Data(repeating:1,count:32))["signature"].string!),for:r.message!))
            XCTAssertThrowsError(try r.sign(privateKey:Data(repeating:2,count:32)))
        }
        XCTAssertThrowsError(try request(.object(["address":.string(f.account),"data":.string(f.data),"type":.string("payload")]),account:f.account,method:"polkadot_signMessage"))
    }
    func testRejectsNetworkAccountExtensionsAndPayloadMutations() throws {
        let f = try fixtures().vectors[0]
        let other = try PolkadotIdentity.address(publicKey:PolkadotSendCrypto.publicKey(privateKey:Data(repeating:2,count:32)))
        XCTAssertThrowsError(try request(f.params,account:other))
        XCTAssertThrowsError(try request(f.params,account:f.account,chain:PolkadotConnectNetwork.relay.chain))
        XCTAssertThrowsError(try request(f.params,account:f.account,method:"polkadot_sendTransaction"))
        var body = f.params.fields!, p = body["transactionPayload"]!.fields!
        for (key,value) in [("genesisHash",TronJSON.string("0x"+String(repeating:"00",count:32))), ("version",.number("5")), ("mode",.number("1")), ("assetId",.string("0x01")), ("metadataHash",.string("0x00")), ("address",.string(other)), ("nonce",.string("0x0100000000")), ("era",.string("0xff")), ("unexpected",.bool(true))] {
            var changed = p; changed[key] = value; body["transactionPayload"] = .object(changed)
            XCTAssertThrowsError(try request(.object(body),account:f.account),key)
        }
        p["signedExtensions"] = .array([.string("CheckNonce"),.string("CheckNonce")]); body["transactionPayload"] = .object(p)
        XCTAssertThrowsError(try request(.object(body),account:f.account))
        let r = try request(f.params,account:f.account)
        XCTAssertThrowsError(try r.sign(privateKey:Data(repeating:1,count:32)))
        XCTAssertThrowsError(try r.sign(privateKey:Data(repeating:1,count:32),review:review(r,date:.now.addingTimeInterval(-100))))
        XCTAssertThrowsError(try r.extensionBytes("UnreviewedExtension"))
        let changed = try request(try fixtures().vectors[1].params,account:f.account)
        XCTAssertThrowsError(try r.sign(privateKey:Data(repeating:1,count:32),review:review(changed)))
    }
    func testCallDecodingAndTrailingBytes() throws {
        let runtime = try PolkadotRuntime(Data(contentsOf:Bundle.module.url(forResource:"PolkadotPaseoMetadata",withExtension:"scale",subdirectory:"Fixtures")!))
        let r = try request(try fixtures().vectors[0].params,account:fixtures().vectors[0].account)
        let decoded = try PolkadotConnectClient.decodeCall(r.call,runtime:runtime)
        XCTAssertEqual(decoded.name,"Balances.transfer_keep_alive")
        XCTAssertEqual(decoded.amount,"1234567890")
        XCTAssertNotNil(decoded.recipient)
        XCTAssertThrowsError(try PolkadotConnectClient.decodeCall(r.call+Data([0]),runtime:runtime))
    }
    func testReviewAndPreflightPreserveTipAndRejectChangedFee() async throws {
        let f = try fixtures().vectors[2], r = try request(f.params,account:f.account)
        let rpc = try PolkadotConnectRPCFixture(r)
        let client = PolkadotConnectClient(network:.paseo,transport:rpc)
        let review = try await client.review(r)
        XCTAssertEqual(review.fee,"133456")
        XCTAssertEqual(review.nativeAmount,"1234567890")
        try await client.preflight(review)
        await rpc.setFault(.fee)
        do { try await client.preflight(review); XCTFail("Increased fee must require another review") }
        catch { XCTAssertEqual(error as? PolkadotSendError,.changed) }
    }
    func testRejectsStaleNetworkRuntimeNonceAndLifetime() async throws {
        let f = try fixtures().vectors[1], r = try request(f.params,account:f.account)
        for (fault,expected) in [(PolkadotConnectRPCFixture.Fault.genesis,PolkadotSendError.wrongNetwork),(.checkpoint,.wrongNetwork),(.runtime,.metadataChanged),(.nonce,.changed),(.expired,.expired)] {
            let rpc = try PolkadotConnectRPCFixture(r); await rpc.setFault(fault)
            do { _ = try await PolkadotConnectClient(network:.paseo,transport:rpc).review(r); XCTFail("Accepted \(fault)") }
            catch { XCTAssertEqual(error as? PolkadotSendError,expected) }
        }
    }
    func testMissingAndLockedFeeBalancesCannotBeSigned() async throws {
        let f = try fixtures().vectors[0], r = try request(f.params,account:f.account)
        for fault in [PolkadotConnectRPCFixture.Fault.missingAccount,.locked,.empty] {
            let rpc = try PolkadotConnectRPCFixture(r); await rpc.setFault(fault)
            do { _ = try await PolkadotConnectClient(network:.paseo,transport:rpc).review(r); XCTFail("Accepted \(fault)") }
            catch { XCTAssertTrue(error is SendFeeFundingError) }
        }
    }
    func testNativeTransferCannotConsumeFrozenRemainder() async throws {
        let f = try fixtures().vectors[0], r = try request(f.params,account:f.account)
        let rpc = try PolkadotConnectRPCFixture(r); await rpc.setFault(.transferLocked)
        do { _ = try await PolkadotConnectClient(network:.paseo,transport:rpc).review(r); XCTFail("Fee fits but transfer consumes the lock") }
        catch { XCTAssertEqual(error as? PolkadotSendError,.insufficientFunds) }
    }
    func testLiveSupportedRuntimeEncoding() async throws {
        guard ProcessInfo.processInfo.environment["OATH_DOT_WC_READ_LIVE"] == "1" else { throw XCTSkip("Opt-in read-only runtime check") }
        let fixture = try fixtures().vectors[0]
        for network in PolkadotConnectNetwork.allCases {
            func rpc(_ method: String, _ params: [SolanaJSON] = []) async throws -> SolanaJSON {
                var http = URLRequest(url:network.endpoints[0]); http.httpMethod = "POST"; http.timeoutInterval = 25
                http.setValue("application/json",forHTTPHeaderField:"Content-Type")
                http.httpBody = try JSONEncoder().encode(SolanaJSON.object(["id":.number("1"),"jsonrpc":.string("2.0"),"method":.string(method),"params":.array(params)]))
                let (data,status) = try await AnkrHTTPTransport().send(http)
                XCTAssertEqual(status,200)
                let value = try JSONDecoder().decode(SolanaJSON.self,from:data)
                XCTAssertTrue(value["error"].isNull)
                return value["result"]
            }
            let genesis = try await rpc("chain_getBlockHash",[.number("0")])
            XCTAssertEqual(genesis.string,network.genesis)
            let hash = try await rpc("chain_getFinalizedHead")
            async let metadataTask = rpc("state_getMetadata",[hash])
            async let versionTask = rpc("state_getRuntimeVersion",[hash])
            let (metadata,version) = try await (metadataTask,versionTask)
            let runtime = try PolkadotRuntime(PolkadotIdentity.bytes(XCTUnwrap(metadata.string)))
            var body = fixture.params.fields!, payload = body["transactionPayload"]!.fields!
            payload["genesisHash"] = .string(network.genesis); payload["blockHash"] = .string(network.genesis)
            payload["specVersion"] = .string("0x"+String(try XCTUnwrap(UInt32(version["specVersion"].text ?? "")),radix:16).leftPaddedHex)
            payload["transactionVersion"] = .string("0x"+String(try XCTUnwrap(UInt32(version["transactionVersion"].text ?? "")),radix:16).leftPaddedHex)
            payload["signedExtensions"] = .array(runtime.extensions.map { .string($0.name) })
            body["transactionPayload"] = .object(payload)
            let r = try request(.object(body),account:fixture.account,chain:network.chain)
            for ext in runtime.extensions {
                let pair = try r.extensionBytes(ext.name)
                for (bytes,type) in [(pair.0,ext.type),(pair.1,ext.additional)] {
                    var reader = PolkadotScale(bytes), budget = 1_000
                    _ = try runtime.decode(type,reader:&reader,depth:0,budget:&budget)
                    XCTAssertEqual(reader.offset,bytes.count,network.name+" "+ext.name)
                }
            }
        }
    }
}

private extension String {
    var leftPaddedHex: String { count % 2 == 0 ? self : "0" + self }
}

private actor PolkadotConnectRPCFixture: AnkrTransport {
    enum Fault { case none,genesis,checkpoint,runtime,nonce,expired,fee,missingAccount,locked,empty,transferLocked }
    let input: WalletConnectPolkadotRequest, metadata: Data
    var fault: Fault = .none
    init(_ input: WalletConnectPolkadotRequest) throws {
        self.input = input
        metadata = try Data(contentsOf:Bundle.module.url(forResource:"PolkadotPaseoMetadata",withExtension:"scale",subdirectory:"Fixtures")!)
    }
    func setFault(_ value: Fault) { fault = value }
    func send(_ request: URLRequest) async throws -> (Data,Int) {
        let j = try JSONDecoder().decode(SolanaJSON.self,from:request.httpBody!), params = j["params"].array!
        let result: SolanaJSON
        switch j["method"].string! {
        case "chain_getBlockHash":
            if params[0].text == "0" { result = .string(fault == .genesis ? "0x00" : input.network.genesis) }
            else { result = .string(fault == .checkpoint ? "0x00" : input.blockHash) }
        case "chain_getFinalizedHead": result = .string(input.blockHash)
        case "chain_getHeader": result = .object(["number":.string("0x"+String(fault == .expired ? try input.lifetime().death : input.blockNumber,radix:16))])
        case "state_getRuntimeVersion": result = .object(["specVersion":.number(String(input.specVersion + (fault == .runtime ? 1 : 0))),"transactionVersion":.number(String(input.transactionVersion))])
        case "system_accountNextIndex": result = .number(String(input.nonce + (fault == .nonce ? 1 : 0)))
        case "state_getMetadata": result = .string(PolkadotIdentity.hex(metadata))
        case "payment_queryInfo": result = .object(["partialFee":.string(fault == .fee ? "20000" : "10000")])
        case "state_getStorage":
            if fault == .missingAccount { result = .null }
            else {
                let free = fault == .empty ? "0" : "100000000000"
                let prefix = PolkadotScale.le(input.nonce)+Data(repeating:0,count:12)
                let frozen = fault == .locked ? free : fault == .transferLocked ? "99999000000" : "0"
                let bytes = try prefix+NearSendCrypto.u128(free)+NearSendCrypto.u128("0")+NearSendCrypto.u128(frozen)+NearSendCrypto.u128("0")
                result = .string(PolkadotIdentity.hex(bytes))
            }
        default: throw PolkadotSendError.runtimeUnsupported
        }
        return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"result":result])),200)
    }
}
