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
