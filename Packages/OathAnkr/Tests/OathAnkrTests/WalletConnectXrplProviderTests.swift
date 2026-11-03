import XCTest
@testable import OathAnkr

private actor WCXrplTransport: AnkrTransport {
    let reply: @Sendable (XrplJSON) throws -> XrplJSON
    private(set) var submitted = 0
    init(_ reply: @escaping @Sendable (XrplJSON) throws -> XrplJSON) { self.reply = reply }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let input = try JSONDecoder().decode(XrplJSON.self, from: request.httpBody!)
        if input["method"].string == "submit" { submitted += 1 }
        var result = try reply(input).fields ?? [:]
        result["status"] = .string(result["error"] == nil ? "success" : "error")
        return (try JSONEncoder().encode(XrplJSON.object(["result":.object(result)])),200)
    }
}
final class WalletConnectXrplProviderTests: XCTestCase {
    static func state(_ height: Int = 100, network: Int = 1) -> XrplJSON {
        .object(["info":.object(["network_id":.number(String(network)),"validated_ledger":.object([
            "seq":.number(String(height)),"hash":.string(String(repeating:"A",count:64)),"age":.number("1"),
            "reserve_base_xrp":.number("1"),"reserve_inc_xrp":.number("0.2")])])])
    }
    private func simulationTransport(_ request: WalletConnectXrplRequest, engine: String = "tesSUCCESS", metadata: XrplJSON, alias: Bool = false) -> WCXrplTransport {
        WCXrplTransport { input in
            switch input["method"].string {
            case "server_info": return Self.state(100)
            case "fee": return .object(["drops":.object(["open_ledger_fee":.string("10"),"minimum_fee":.string("10")])])
            case "account_info": return .object(["validated":.bool(true),"ledger_hash":.string(String(repeating:"A",count:64)),
                "account_data":.object(["Account":.string(request.account),"Balance":.string("10000000"),"Sequence":.number("42"),"Flags":.number("0")])])
            case "simulate":
                var tx = input["params"].array![0]["tx_json"].fields!
                if alias { tx["DeliverMax"] = tx.removeValue(forKey:"Amount") }
                return .object(["engine_result":.string(engine),"meta":metadata,"tx_json":.object(tx)])
            default: throw XrplSendError.malformed
            }
        }
    }
    func testReviewRejectsFailedOrMissingSimulationMetadata() async throws {
        let base=WalletConnectXrplTests(), request=try base.request()
        let cases: [(XrplJSON,String)] = [(.object(["TransactionResult":.string("tecPATH_DRY")]),"tecPATH_DRY"),
            (.null,"UNKNOWN"),(.object([:]),"UNKNOWN"),(.object(["TransactionResult":.number("0")]),"UNKNOWN")]
        for (metadata,code) in cases {
            let transport=simulationTransport(request,metadata:metadata),client=try XrplSendClient(network:.testnet,transport:transport)
            do { _ = try await client.walletConnectReview(request);XCTFail("Contradictory or absent simulation metadata accepted") }
            catch { XCTAssertEqual(error as? XrplSendError,.simulation(code)) }
            let writes=await transport.submitted;XCTAssertEqual(writes,0)
        }
    }
    func testPreflightRejectsFailedOrMissingSimulationMetadata() async throws {
        let base=WalletConnectXrplTests(),request=try base.request(),review=base.review(request)
        let cases: [(XrplJSON,String)] = [(.object(["TransactionResult":.string("tecPATH_DRY")]),"tecPATH_DRY"),
            (.null,"UNKNOWN"),(.object([:]),"UNKNOWN"),(.object(["TransactionResult":.number("0")]),"UNKNOWN")]
        for (metadata,code) in cases {
            let transport=simulationTransport(request,metadata:metadata),client=try XrplSendClient(network:.testnet,transport:transport)
            do { try await client.walletConnectPreflight(review);XCTFail("Contradictory or absent preflight metadata accepted") }
            catch { XCTAssertEqual(error as? XrplSendError,.simulation(code)) }
            let writes=await transport.submitted;XCTAssertEqual(writes,0)
        }
    }
    func testSuccessfulSimulationAndDeliverMaxAliasRemainAccepted() async throws {
        let base=WalletConnectXrplTests(),request=try base.request()
        for alias in [false,true] {
            let transport=simulationTransport(request,metadata:.object(["TransactionResult":.string("tesSUCCESS")]),alias:alias)
            let client=try XrplSendClient(network:.testnet,transport:transport)
            let review=try await client.walletConnectReview(request)
            try await client.walletConnectPreflight(review)
            XCTAssertEqual(review.transaction,request.transaction)
            let writes=await transport.submitted;XCTAssertEqual(writes,0)
        }
    }
    func testEngineFailureCannotBeHiddenBySuccessfulMetadata() async throws {
        let base=WalletConnectXrplTests(),request=try base.request()
        for engine in ["tecPATH_DRY","UNTRUSTED_PROVIDER_TEXT"] {
            let transport=simulationTransport(request,engine:engine,metadata:.object(["TransactionResult":.string("tesSUCCESS")]))
            let client=try XrplSendClient(network:.testnet,transport:transport)
            do { _=try await client.walletConnectReview(request);XCTFail("Failed engine result accepted") }
            catch { XCTAssertEqual(error as? XrplSendError,.simulation(engine == "tecPATH_DRY" ? engine:"UNKNOWN")) }
        }
    }
    func testReceiptNeverConfusesUncertainSubmissionWithFailure() async throws {
        let base=WalletConnectXrplTests(),request=try base.request(),review=base.review(request)
        let signed=try request.sign(privateKey:base.key,review:review)
        for (searched,expected) in [(false,XrplSendReceipt.Outcome.unknown),(true,.expired)] {
            let transport=WCXrplTransport { input in
                if input["method"].string == "server_info" { return Self.state(121) }
                return .object(["error":.string("txnNotFound"),"searched_all":.bool(searched)])
            }
            let client=try XrplSendClient(network:.testnet,transport:transport)
            let result=try await client.walletConnectSubmit(signed,review:review)
            XCTAssertEqual(result,expected)
            let count=await transport.submitted;XCTAssertEqual(count,0)
        }
        for validated in [false,true] {
            let transport=WCXrplTransport { input in
                switch input["method"].string {
                case "server_info":return Self.state(110)
                case "tx":return .object(["validated":.bool(validated),"hash":.string(signed.hash),"tx_json":review.transaction,"ledger_index":.number("110"),"meta":.object(["TransactionResult":.string("tesSUCCESS")])])
                default:return .object(["accepted":.bool(false),"engine_result":.string("tefPAST_SEQ")])
                }
            }
            let client=try XrplSendClient(network:.testnet,transport:transport)
            let result=try await client.walletConnectSubmit(signed,review:review)
            XCTAssertEqual(result,validated ? .confirmed:.unknown)
            let count=await transport.submitted;XCTAssertEqual(count,validated ? 0:1)
        }
    }
    func testWrongNetworkAndReceiptHashCannotConfirm() async throws {
        let base=WalletConnectXrplTests(),request=try base.request(),review=base.review(request)
        let signed=try request.sign(privateKey:base.key,review:review)
        let wrong=WCXrplTransport { _ in Self.state(network:0) }
        do { _=try await XrplSendClient(network:.testnet,transport:wrong).walletConnectSubmit(signed,review:review);XCTFail("Network mismatch accepted") }
        catch { XCTAssertEqual(error as? XrplSendError,.wrongNetwork) }
        let altered=WCXrplTransport { input in
            if input["method"].string == "server_info" { return Self.state(110) }
            return .object(["validated":.bool(true),"hash":.string(String(repeating:"B",count:64)),"tx_json":review.transaction,"ledger_index":.number("110"),"meta":.object(["TransactionResult":.string("tesSUCCESS")])])
        }
        let result=try await XrplSendClient(network:.testnet,transport:altered).walletConnectSubmit(signed,review:review)
        XCTAssertEqual(result,.unknown)
        let count=await altered.submitted;XCTAssertEqual(count,0)
    }
}
