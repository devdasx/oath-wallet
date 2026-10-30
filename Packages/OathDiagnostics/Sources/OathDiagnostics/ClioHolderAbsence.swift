import Foundation

extension DiagnosticHTTP {
    /// Shared decoding/diagnostics predicate. Request values are compared only
    /// in memory and never retained or reported. Unknown failures stay failures.
    public static func expectedClioHolderAbsence(_ data: Data, status: Int, request: URLRequest) -> Bool {
        guard data.count <= 1_048_576,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return expectedClioHolderAbsence(json, status: status, request: request)
    }

    static func expectedClioHolderAbsence(_ json: [String: Any], status: Int, request: URLRequest) -> Bool {
        guard xrplHolderPolicyProbe, status == 200, request.httpMethod == "POST",
              let url = request.url, url.scheme == "https", url.host == "s1.ripple.com",
              url.port == 51234, ["", "/"].contains(url.path), url.query == nil,
              let body = request.httpBody, body.count <= 1_048_576,
              let call = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              call["method"] as? String == "account_info",
              let params = call["params"] as? [[String: Any]], params.count == 1,
              Set(params[0].keys) == ["account", "ledger_index"],
              let owner = params[0]["account"] as? String, !owner.isEmpty,
              params[0]["ledger_index"] as? String == "validated",
              let result = json["result"] as? [String: Any],
              result["error"] as? String == "actNotFound", result["error_code"] as? Int == 19,
              result["status"] as? String == "error", result["type"] as? String == "response",
              result["validated"] == nil, result["account_data"] == nil,
              let echoed = result["request"] as? [String: Any],
              NSDictionary(dictionary: echoed).isEqual(to: call),
              let warnings = json["warnings"] as? [[String: Any]],
              warnings.contains(where: { $0["id"] as? Int == 2001 }),
              !warnings.contains(where: { $0["id"] as? Int == 2002 }) else { return false }
        return true
    }
}
