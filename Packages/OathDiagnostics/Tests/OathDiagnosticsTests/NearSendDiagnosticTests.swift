import XCTest
@testable import OathDiagnostics

final class NearSendDiagnosticTests:XCTestCase {
    func testContractPanicAndArbitraryProviderTextCannotExposeInputs() {
        for text in ["wasm execution failed with error: HostError(GuestPanic(sender alice.near secret pizza))",
                     "account shortname rejected password open-sesame", "Server error: raw transaction sensitive"] {
            let safe=DiagnosticHTTP.nearProviderMessage(text)
            for value in ["alice.near","pizza","shortname","open-sesame","sensitive"] { XCTAssertFalse(safe.contains(value)) }
        }
        XCTAssertEqual(DiagnosticHTTP.nearProviderMessage("Parse error"),"Parse error")
    }
    func testOptionalStorageProbeRequiresExactMethodErrorBlockAndEnvelope() throws {
        let hash=String(repeating:"1",count:32)
        var request=URLRequest(url:URL(string:"https://test.rpc.fastnear.com")!)
        request.httpMethod="POST"
        request.httpBody=try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":1,"method":"query","params":["request_type":"call_function","method_name":"storage_balance_of","block_id":hash,"account_id":"private-recipient.testnet"]])
        let result:[String:Any]=["block_hash":hash,"error":"wasm execution failed with error: MethodResolveError(MethodNotFound)"]
        var envelope:[String:Any]=["jsonrpc":"2.0","id":1,"result":result]
        XCTAssertTrue(DiagnosticHTTP.expectedNearControlFlow(envelope,status:200,request:request))
        XCTAssertFalse(DiagnosticHTTP.expectedNearControlFlow(envelope,status:500,request:request))
        for change:[String:Any] in [["block_hash":"different","error":result["error"]!],["block_hash":hash,"error":"HostError(GuestPanic)"]] {
            envelope["result"]=change
            XCTAssertFalse(DiagnosticHTTP.expectedNearControlFlow(envelope,status:200,request:request))
        }
        envelope["result"]=result;envelope["id"]=2
        XCTAssertFalse(DiagnosticHTTP.expectedNearControlFlow(envelope,status:200,request:request))
        let context=DiagnosticHTTP.context(request)
        XCTAssertEqual(context["chain"],"near")
        XCTAssertFalse(String(describing:context).contains("private-recipient"))
    }
    func testPendingStateNeverHidesTimeoutInternalOrOtherMethodFailures() throws {
        var request=URLRequest(url:URL(string:"https://rpc.mainnet.near.org")!)
        request.httpMethod="POST"
        func body(_ method:String) throws -> Data {
            try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":1,"method":method,"params":["tx_hash":String(repeating:"1",count:32),"sender_account_id":"private.near"]])
        }
        request.httpBody=try body("tx")
        for name in ["UNKNOWN_TRANSACTION","TIMEOUT_ERROR","INTERNAL_ERROR","INVALID_TRANSACTION"] {
            let envelope:[String:Any]=["jsonrpc":"2.0","id":1,"error":["code":-32000,"cause":["name":name]]]
            XCTAssertEqual(DiagnosticHTTP.expectedNearControlFlow(envelope,status:200,request:request),name=="UNKNOWN_TRANSACTION")
        }
        request.httpBody=try body("send_tx")
        XCTAssertFalse(DiagnosticHTTP.expectedNearControlFlow(["jsonrpc":"2.0","id":1,"error":["code":-32000,"cause":["name":"UNKNOWN_TRANSACTION"]]],status:200,request:request))
        request.url=URL(string:"https://unrelated.example")
        XCTAssertNil(DiagnosticHTTP.context(request)["chain"])
    }
}

final class NearMetadataDiagnosticTests: XCTestCase {
    func testOnlyPinnedOptionalMetadataMethodAbsenceIsExcluded() throws {
        let hash = String(repeating:"1", count:32)
        var request = URLRequest(url:URL(string:"https://rpc.mainnet.near.org")!)
        request.httpMethod = "POST"
        func body(_ method:String = "ft_metadata") throws -> Data {
            try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0", "id":1, "method":"query",
                "params":["request_type":"call_function", "method_name":method, "block_id":hash, "account_id":"private-fixture.near"]])
        }
        request.httpBody = try body()
        let result:[String:Any] = ["block_hash":hash, "block_height":123,
            "error":"wasm execution failed with error: MethodResolveError(MethodNotFound)", "logs":[]]
        func envelope(_ result:[String:Any]) -> [String:Any] { ["jsonrpc":"2.0", "id":1, "result":result] }
        XCTAssertTrue(DiagnosticHTTP.expectedNearControlFlow(envelope(result), status:200, request:request))
        XCTAssertFalse(DiagnosticHTTP.expectedNearControlFlow(envelope(result), status:503, request:request))
        for (key, value) in [("block_hash", "wrong" as Any), ("block_height", -1), ("block_height", true), ("logs", [123]),
                             ("result", [1]), ("error", "wasm execution failed with error: HostError(GasExceeded)")] {
            var invalid = result; invalid[key] = value
            XCTAssertFalse(DiagnosticHTTP.expectedNearControlFlow(envelope(invalid), status:200, request:request), key)
        }
        var mismatched = envelope(result); mismatched["id"] = 2
        XCTAssertFalse(DiagnosticHTTP.expectedNearControlFlow(mismatched, status:200, request:request))
        for method in ["ft_balance_of", "ft_transfer", "unrelated"] {
            request.httpBody = try body(method)
            XCTAssertFalse(DiagnosticHTTP.expectedNearControlFlow(envelope(result), status:200, request:request), method)
        }
    }
}
