import Foundation
import CoreFoundation

/// Ephemeral local comparison data, never diagnostic context or error payload.
public struct DiagnosticEVMBroadcastAttempt: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let transaction: String
    let chainID: UInt64
    public init(transaction: String, chainID: UInt64) { self.transaction = transaction; self.chainID = chainID }
    public var description: String { "Verified EVM submission" }
    public var debugDescription: String { description }
}

extension DiagnosticHTTP {
    /// This exact duplicate response is a request to reconcile, not proof of
    /// success. Unscoped requests, malformed batches and chain mismatches report.
    public static func expectedEVMDuplicateBroadcast(_ data: Data, status: Int, request: URLRequest) -> Bool {
        guard let attempt = submittedEVMBroadcast, attempt.chainID > 0,
              status == 200, request.httpMethod == "POST", data.count <= 16_384,
              let body = request.httpBody, body.count <= 1_048_576,
              let calls = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]], calls.count == 2,
              let replies = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], replies.count == 2,
              calls.allSatisfy({ $0["jsonrpc"] as? String == "2.0" }),
              replies.allSatisfy({ $0["jsonrpc"] as? String == "2.0" }) else { return false }
        func id(_ row: [String: Any], _ expected: Int) -> Bool {
            guard let n = row["id"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
            return n == NSNumber(value: expected)
        }
        guard let chainCall = calls.first(where: { id($0, 0) }), let sendCall = calls.first(where: { id($0, 1) }),
              chainCall["method"] as? String == "eth_chainId", (chainCall["params"] as? [Any])?.isEmpty == true,
              sendCall["method"] as? String == "eth_sendRawTransaction",
              sendCall["params"] as? [String] == [attempt.transaction],
              let chain = replies.first(where: { id($0, 0) }), let send = replies.first(where: { id($0, 1) }),
              chain["error"] == nil, chain["result"] as? String == "0x" + String(attempt.chainID, radix: 16),
              send["result"] == nil, let error = send["error"] as? [String: Any],
              let code = error["code"] as? NSNumber, CFGetTypeID(code) != CFBooleanGetTypeID(),
              let message = error["message"] as? String else { return false }
        // Geth and Anvil use distinct exact envelopes for the same pool condition.
        return (code == -32000 && message == "already known") ||
            (code == -32003 && message == "transaction already imported")
    }
}
