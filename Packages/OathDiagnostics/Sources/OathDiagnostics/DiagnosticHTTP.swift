import Foundation
import CoreFoundation

/// Inspects error envelopes only. Successful balances/history, request params,
/// headers, URLs and binary bodies are never copied into diagnostics.
public enum DiagnosticHTTP {
    // Compared only inside one bounded response envelope. These raw values
    // remain local; the emitted error still goes through shared privacy filters.
    private struct ProviderErrorIdentity: Hashable {
        let code: Int
        let rpcCode: String
        let message: String
    }
    /// Scoped only around optional ERC-20 discovery. Never used for transaction
    /// simulation, balance validation or submission. Still requires a matching
    /// read-only metadata selector, reply ID and explicit EVM revert below.
    @TaskLocal public static var optionalEVMMetadataProbe = false
    /// Arc inventory/history permit missing names and symbols, but require
    /// decimals and balances. Keep this narrower than discovery probes.
    @TaskLocal public static var optionalEVMTokenLabels = false
    /// Only read-only multisig discovery. A missing policy is a normal result;
    /// other callers, malformed envelopes and provider failures still report.
    @TaskLocal public static var publicAccountPolicyProbe = false
    /// Only the stablecoin holder lookup, never the issuer lookup. Clio omits
    /// validated/account fields from absence errors and echoes the request.
    @TaskLocal public static var xrplHolderPolicyProbe = false
    /// Scoped only after signature/chain verification by the Polkadot submitter.
    /// Used locally to recognize acknowledgement of the exact persisted bytes;
    /// never included in diagnostic context or emitted error text.
    @TaskLocal public static var submittedPolkadotHash: String? = nil
    /// Only around a locally verified signed EVM submission. The submitter must
    /// reconcile the exact transaction after this control-flow response, and
    /// report an unresolved reconciliation. Nothing here proves acceptance.
    @TaskLocal public static var submittedEVMBroadcast: DiagnosticEVMBroadcastAttempt? = nil
    /// Only the v1 Verify attestation lookup. Missing origin evidence remains
    /// unverified in the SDK and must still require the wallet's acknowledgement.
    @TaskLocal public static var walletConnectAttestationLookup = false
    public static func context(_ request: URLRequest) -> [String: String] {
        var context: [String: String] = ["host": request.url?.host ?? "unknown"]
        if let body = request.httpBody, body.count < 1_048_576,
           let json = try? JSONSerialization.jsonObject(with: body) {
            let rows = (json as? [[String: Any]]) ?? ((json as? [String: Any]).map { [$0] } ?? [])
            let methods = rows.compactMap { $0["method"] as? String }.filter {
                $0.count < 100 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_./".contains($0)) }
            }
            if !methods.isEmpty { context["method"] = Array(Set(methods)).sorted().prefix(4).joined(separator: ",") }
            // Only accept known chain names from the request, never wallet fields.
            if let params = rows.first?["params"] as? [String: Any] {
                let candidate = (params["blockchain"] as? [String])?.first ?? params["blockchain"] as? String
                if let candidate, chains.contains(candidate) { context["chain"] = candidate }
            }
        }
        if context["chain"] == nil, let url = request.url {
        if ["api.mainnet.aptoslabs.com", "api.testnet.aptoslabs.com", "archive.mainnet.aptoslabs.com"].contains(url.host ?? "") { context["chain"] = "aptos" }
            if ["api.mainnet-beta.solana.com", "api.devnet.solana.com", "api.testnet.solana.com"].contains(url.host ?? "") { context["chain"] = "solana" }
            if ["rpc.mainnet.arc.io","rpc.testnet.arc.io","rpc.blockdaemon.mainnet.arc.io","rpc.blockdaemon.testnet.arc.io","rpc.drpc.mainnet.arc.io","rpc.drpc.testnet.arc.io"].contains(url.host ?? "") { context["chain"] = "arc" }
            if ["babel-api.mainnet.iotex.io", "babel-api.mainnet.iotex.one", "archive-mainnet.iotex.io", "dev.iotexscan.io", "api.iotex.one", "api.mainnet.iotex.one"].contains(url.host ?? "") { context["chain"] = "iotex" }
            if ["babel-api.testnet.iotex.io", "babel-api.testnet.iotex.one"].contains(url.host ?? "") { context["chain"] = "iotexTestnet" }
            if ["evmrpc.0g.ai", "evmrpc-testnet.0g.ai", "chainscan.0g.ai"].contains(url.host ?? "") { context["chain"] = "zerog" }
            if ["api-v2.seistream.app", "evm-rpc.sei-apis.com", "evm-rpc-testnet.sei-apis.com", "sei-mainnet.g.alchemy.com"].contains(url.host ?? "") { context["chain"] = "sei" }
            if url.host == "trace.hypurrscan.io" { context["chain"] = "hyperevm" }
            if url.host == "api.rujira.network" || (url.host == "gateway.liquify.com" && url.pathComponents.contains(where: { ["thorchain_api","thorchain_rpc","thorchain_midgard"].contains($0) })) { context["chain"] = "thorchain" }
            if url.host == "xrplcluster.com" { context["chain"] = "xrpl" }
            if ["rpc.mainnet.near.org", "rpc.testnet.near.org", "test.rpc.fastnear.com"].contains(url.host ?? "") { context["chain"] = "near" }
            if ["tonapi.io", "testnet.tonapi.io", "toncenter.com", "testnet.toncenter.com"].contains(url.host ?? "") { context["chain"] = "ton" }
            let parts = url.pathComponents
            if parts.contains("0g_mainnet_evm") { context["chain"] = "zerog" }
            if parts.contains("xrp_mainnet") { context["chain"] = "xrpl" }
            for chain in chains.sorted(by: { $0.count > $1.count }) where parts.contains(where: { $0 == chain || $0.hasPrefix(chain + "_") }) {
                context["chain"] = chain; break
            }
        }
        return context
    }
    private static let chains: Set<String> = ["eth", "ethereum", "bsc", "polygon", "arbitrum", "optimism", "base", "avalanche", "scroll", "linea", "zksync", "gnosis", "fantom", "sonic", "blast", "mantle", "chiliz", "filecoin", "sei", "zerog", "iotex", "celo", "solana", "ton", "tron", "aptos", "sui", "near", "polkadot", "stellar", "xrpl", "arc", "monad", "unichain", "hyperevm", "robinhood"]
    public static func response(_ data: Data, status: Int, request: URLRequest,
                                file: String = #fileID, function: String = #function, line: UInt = #line) {
        if expectedMarketDataAbsence(data, status: status, request: request) { return }
        if expectedPolkadotAlreadyImported(data, status: status, request: request) { return }
        if expectedEVMDuplicateBroadcast(data, status: status, request: request) { return }
        if expectedWalletConnectAttestationAbsence(data, status: status, request: request) { return }
        var context = context(request); context["http_status"] = String(status)
        // Do not deserialize large successful payloads twice. Error responses are
        // bounded separately from balance/history body limits.
        guard data.count <= 1_048_576 else {
            if !(200...299).contains(status) {
                OathDiagnostics.record(DiagnosticFailure("HTTP error; response exceeds diagnostic limit"), component: "network",
                    context: context, file: file, function: function, line: line)
            }
            return
        }
        var found = false
        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let object = json as? [String: Any], (expectedAccountAbsence(object, status: status, request: request) || expectedNearControlFlow(object,status:status,request:request)) { return }
            let rootRows = (json as? [[String: Any]]) ?? ((json as? [String: Any]).map { [$0] } ?? [])
            // XRPL reports RPC errors inside result while HTTP still succeeds.
            let rows = rootRows.flatMap { row -> [[String: Any]] in
                if let result = row["result"] as? [String: Any], result["error"] != nil { return [row, result] }
                return [row]
            }
            for row in rows.prefix(100) {
                if optionalEVMMetadataProbe, expectedEVMMetadataAbsence(row, status: status, request: request) { continue }
                if optionalEVMTokenLabels, expectedEVMMetadataAbsence(row, status: status, request: request, labelsOnly: true) { continue }
                // Kraken and other REST providers use an array of errors, with
                // [] on success. GraphQL may repeat the same failure at many
                // field paths. Coalesce exact duplicates within this envelope,
                // retaining their count, every distinct error and later failures.
                let fields: [Any] = [row["error"], row["Error"]].compactMap { $0 }
                let candidates = fields.flatMap { ($0 as? [Any]) ?? [$0] } + (row["errors"] as? [Any] ?? [])
                var positions: [ProviderErrorIdentity: Int] = [:]
                var failures: [(error: NSError, context: [String: String], count: Int)] = []
                for candidate in candidates.prefix(100) where !(candidate is NSNull) {
                    found = true
                    let object = candidate as? [String: Any]
                    let rawCode = object?["code"] ?? object?["error_code"] ?? row["code"] ?? row["error_code"]
                    let code = (rawCode as? NSNumber)?.intValue ?? (rawCode as? String).flatMap(Int.init) ?? -1
                    var itemContext = context
                    itemContext.merge(rpcFailureContext(row, request: request)) { _, new in new }
                    itemContext["rpc_code"] = (rawCode as? String) ?? String(code)
                    var message = object?["message"] as? String ?? row["error_message"] as? String ?? candidate as? String ?? "Provider returned an error envelope"
                    if context["chain"] == "near" { message = nearProviderMessage(message) }
                    // NEAR often uses the generic 'Server error' and puts the
                    // actionable classification in cause.name. Preserve only
                    // that bounded protocol name, never account/contract info.
                    let cause = object?["cause"] as? [String: Any] ?? (object?["data"] as? [String: Any])?["cause"] as? [String: Any]
                    if let name = cause?["name"] as? String, name.count <= 80,
                       name.allSatisfy({ $0.isASCII && ($0.isUppercase || $0 == "_") }) { message += ": " + name }
                    let identity = ProviderErrorIdentity(code: code, rpcCode: itemContext["rpc_code"] ?? "", message: message)
                    if let index = positions[identity] {
                        failures[index].count += 1
                        continue
                    }
                    positions[identity] = failures.count
                    let error = NSError(domain: "Oath.Provider", code: code, userInfo: [NSLocalizedDescriptionKey: message])
                    failures.append((error, itemContext, 1))
                }
                for failure in failures {
                    var itemContext = failure.context
                    if failure.count > 1 { itemContext["count"] = String(failure.count) }
                    OathDiagnostics.record(failure.error, component: "network", operation: "provider_response", context: itemContext,
                                           file: file, function: function, line: line)
                }
                // REST errors (Aptos, TON, TRON, indexers); inspect only named
                // error fields, never arbitrary provider data or GraphQL variables.
                if !(200...299).contains(status), !found {
                    let message = row["message"] as? String ?? row["detail"] as? String ?? row["error_description"] as? String
                    if let message {
                        found = true
                        let rawCode = row["error_code"] ?? row["code"]
                        if let code = rawCode as? String { context["rpc_code"] = code }
                        else if let code = rawCode as? NSNumber { context["rpc_code"] = code.stringValue }
                        OathDiagnostics.record(NSError(domain: "Oath.HTTP", code: status, userInfo: [NSLocalizedDescriptionKey: message]),
                            component: "network", context: context, file: file, function: function, line: line)
                    }
                }
            }
        }
        if !(200...299).contains(status), !found {
            // Plain text/HTML may contain request echoes or login pages. Preserve
            // status and MIME-independent failure, never upload the body wholesale.
            OathDiagnostics.record(NSError(domain: "Oath.HTTP", code: status), component: "network",
                context: context, file: file, function: function, line: line)
        }
    }

    /// Substrate reports an already pooled extrinsic as RPC 1013 with its hash.
    /// This is submission acknowledgement, not confirmation. Do not classify a
    /// different hash, unscoped request, malformed reply or other RPC as success.
    public static func expectedPolkadotAlreadyImported(_ data: Data, status: Int, request: URLRequest) -> Bool {
        guard let hash = submittedPolkadotHash, hash.count == 66, hash.hasPrefix("0x"),
              hash.dropFirst(2).allSatisfy({ $0.isASCII && $0.isHexDigit }),
              status == 200, request.httpMethod == "POST", data.count <= 16_384,
              let body = request.httpBody, body.count <= 1_048_576,
              let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              sent["jsonrpc"] as? String == "2.0", sent["method"] as? String == "author_submitExtrinsic",
              let params = sent["params"] as? [String], params.count == 1,
              let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              reply["jsonrpc"] as? String == "2.0", reply["result"] == nil,
              let requestID = sent["id"] as? NSNumber, let responseID = reply["id"] as? NSNumber,
              CFGetTypeID(requestID) != CFBooleanGetTypeID(), CFGetTypeID(responseID) != CFBooleanGetTypeID(),
              requestID == responseID,
              let error = reply["error"] as? [String: Any], let code = error["code"] as? NSNumber,
              CFGetTypeID(code) != CFBooleanGetTypeID(), code == 1013,
              error["message"] as? String == "Transaction Already Imported",
              let reported = error["data"] as? String, reported.lowercased() == hash.lowercased() else { return false }
        return true
    }

    /// An unregistered attestation is absent evidence, not a verified origin.
    /// Keep other endpoints, invalid IDs, access denial and malformed requests
    /// reportable. In particular, never exclude the verification signing key.
    public static func expectedWalletConnectAttestationAbsence(_ data: Data, status: Int, request: URLRequest) -> Bool {
        guard walletConnectAttestationLookup, status == 404, data.count <= 4096,
              request.httpMethod == "GET", request.httpBody == nil,
              let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "verify.walletconnect.org",
              parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.queryItems == [URLQueryItem(name: "v2Supported", value: "true")],
              parts.percentEncodedPath.hasPrefix("/attestation/") else { return false }
        let identifier = parts.percentEncodedPath.dropFirst("/attestation/".count)
        return identifier.utf8.count == 64 && identifier.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Public optional market lookups may legitimately have no listing. Match
    /// the exact observed provider envelope and read endpoint; a proxy 404,
    /// malformed response, catalog failure or any other status still reports.
    /// The response is inspected locally only, never copied to diagnostics.
    public static func expectedMarketDataAbsence(_ data: Data, status: Int, request: URLRequest) -> Bool {
        guard status == 404, request.httpMethod == nil || request.httpMethod == "GET",
              request.httpBody == nil, let url = request.url, url.scheme == "https",
              url.user == nil, url.password == nil, data.count <= 16_384,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        let parts = url.path.split(separator: "/").map(String.init)
        func code(_ value: String) -> Bool {
            value.count <= 34 && value.range(of: "^[A-Z0-9]+-USD$", options: .regularExpression) != nil
        }
        switch url.host {
        case "api.geckoterminal.com":
            // Exact optional token-lookup envelope. The provider reference ID
            // stays local; malformed responses and catalog failures still report.
            guard parts.count == 6, Array(parts.prefix(3)) == ["api", "v2", "networks"],
                  parts[3].range(of: "^[a-z0-9-]{1,64}$", options: .regularExpression) != nil,
                  parts[4] == "tokens", !parts[5].isEmpty, parts[5].utf8.count <= 512,
                  Set(object.keys) == ["errors", "meta"],
                  let errors = object["errors"] as? [[String: String]], errors == [["status": "404", "title": "Not Found"]],
                  let meta = object["meta"] as? [String: String], Set(meta.keys) == ["ref_id"],
                  let ref = meta["ref_id"], UUID(uuidString: ref) != nil else { return false }
            return true
        case "api.exchange.coinbase.com":
            return parts.count == 3 && parts[0] == "products" && code(parts[1]) &&
                ["candles", "stats"].contains(parts[2]) && object.count == 1 && object["message"] as? String == "NotFound"
        case "api.coinbase.com":
            // Coinbase also returns NotFound when its own quote is stale. This
            // is unavailable market data, never permission to use the stale rate.
            guard request.allHTTPHeaderFields?.keys.allSatisfy({ ["accept", "user-agent"].contains($0.lowercased()) }) ?? true,
                  url.query == nil, url.port == nil, url.fragment == nil,
                  let message = object["message"] as? String,
                  ["rpc error: code = NotFound desc = not found",
                   "rpc error: code = NotFound desc = rate found but was stale"].contains(message) else { return false }
            return parts.count == 4 && parts[0] == "v2" && parts[1] == "prices" && code(parts[2]) && parts[3] == "spot" &&
                Set(object.keys) == ["error", "code", "message"] && object["code"] as? Int == 5 &&
                object["error"] as? String == message && object["message"] as? String == message
        case "api.coingecko.com":
            guard object.count == 1, ["coin not found", "Could not find coin with the given id"].contains(object["error"] as? String ?? ""),
                  parts.count >= 4, Array(parts.prefix(3)) == ["api", "v3", "coins"],
                  parts[3].range(of: "^[a-z0-9-]{1,200}$", options: .regularExpression) != nil else { return false }
            if parts.count == 4 { return parts[3] != "list" && parts[3] != "markets" }
            if parts.count == 5 { return parts[4] == "market_chart" }
            guard [6, 7].contains(parts.count), parts[4] == "contract",
                  parts[5].range(of: "^[a-zA-Z0-9]{1,128}$", options: .regularExpression) != nil else { return false }
            return parts.count == 6 || parts[6] == "market_chart"
        default: return false
        }
    }

    /// Shared classification for optional discovery clients. No payload, address
    /// or request identifier leaves this local comparison.
    public static func expectedEVMMetadataAbsence(_ data: Data, status: Int, request: URLRequest) -> Bool {
        guard data.count <= 16_384,
              let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return expectedEVMMetadataAbsence(row, status: status, request: request)
    }

    static func expectedEVMMetadataAbsence(_ row: [String: Any], status: Int, request: URLRequest, labelsOnly: Bool = false) -> Bool {
        guard status == 200, request.httpMethod == "POST", row["jsonrpc"] as? String == "2.0",
              row["result"] == nil, row["id"] != nil,
              let error = row["error"] as? [String: Any], let code = error["code"] as? Int,
              [3, -32000, -32015].contains(code),
              let message = error["message"] as? String, message.lowercased().contains("revert"),
              let body = request.httpBody, body.count < 8192,
              let call = matchingRPCCall(row, request: request) else { return false }
        guard call["jsonrpc"] as? String == "2.0", call["method"] as? String == "eth_call",
              let params = call["params"] as? [Any], params.count == 2, let tag = params[1] as? String,
              tag == "latest" || (labelsOnly && tag.hasPrefix("0x") && (3...18).contains(tag.count) &&
                tag.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })),
              let tx = params[0] as? [String: Any], Set(tx.keys) == ["to", "data"],
              let to = tx["to"] as? String, to.count == 42, to.hasPrefix("0x"),
              to.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let data = tx["data"] as? String, data.hasPrefix("0x"),
              data.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        if labelsOnly {
            return message.lowercased() == "execution reverted" && (data == "0x06fdde03" || data == "0x95d89b41")
        }
        // Exact ABI lengths, not arbitrary contract calls with these prefixes.
        return data == "0x313ce567" || data == "0x06fdde03" || data == "0x95d89b41" || data == "0x18160ddd" ||
            (data.hasPrefix("0x70a08231") && data.count == 74) ||
            (data.hasPrefix("0xdd62ed3e") && data.count == 138) ||
            data == "0x01ffc9a780ac58cd" + String(repeating: "0", count: 56)
    }

    private static func matchingRPCCall(_ row: [String: Any], request: URLRequest) -> [String: Any]? {
        guard row["jsonrpc"] as? String == "2.0", let replyID = row["id"],
              let body = request.httpBody, body.count < 1_048_576,
              let json = try? JSONSerialization.jsonObject(with: body) else { return nil }
        let calls = (json as? [[String: Any]]) ?? ((json as? [String: Any]).map { [$0] } ?? [])
        guard calls.count <= 100 else { return nil }
        func matchesID(_ value: Any?) -> Bool {
            if let reply = replyID as? String, let value = value as? String {
                return !reply.isEmpty && reply.utf8.count <= 128 && reply == value
            }
            guard let reply = replyID as? NSNumber, let value = value as? NSNumber,
                  CFGetTypeID(reply) != CFBooleanGetTypeID(), CFGetTypeID(value) != CFBooleanGetTypeID(),
                  reply.doubleValue.isFinite, reply.doubleValue.rounded() == reply.doubleValue else { return false }
            return reply == value
        }
        let matches = calls.filter { matchesID($0["id"]) }
        return matches.count == 1 ? matches.first : nil
    }

    /// Correlate shuffled batch replies locally. Emit only constant operation
    /// labels, never IDs, targets, calldata, block tags or arbitrary selectors.
    static func rpcFailureContext(_ row: [String: Any], request: URLRequest) -> [String: String] {
        guard let call = matchingRPCCall(row, request: request),
              call["method"] as? String == "eth_call" else { return [:] }
        let params = call["params"] as? [Any]
        let data = (params?.first as? [String: Any])?["data"] as? String
        let stage: String
        switch data {
        case "0x06fdde03": stage = "token_name"
        case "0x95d89b41": stage = "token_symbol"
        case "0x313ce567": stage = "token_decimals"
        default: stage = "contract_read"
        }
        return ["method": "eth_call", "stage": stage]
    }

    /// These exact envelopes are normal results for an unfunded account. This
    /// only controls diagnostics; each chain client still validates the reply.
    /// Any wrong ledger/owner, other method, malformed body or provider outage
    /// continues to be reported. No request values leave this local comparison.
    static func expectedAccountAbsence(_ json: [String: Any], status: Int, request: URLRequest) -> Bool {
        if expectedClioHolderAbsence(json, status: status, request: request) { return true }
        let context = context(request)
        if publicAccountPolicyProbe, status == 404, request.httpMethod == nil || request.httpMethod == "GET",
           request.httpBody == nil, let url = request.url, url.scheme == "https",
           ["api.mainnet.aptoslabs.com", "api.testnet.aptoslabs.com"].contains(url.host ?? ""),
           url.pathComponents.count == 6, url.pathComponents[1] == "v1", url.pathComponents[2] == "accounts",
           url.pathComponents[4] == "resource", url.pathComponents[5] == "0x1::multisig_account::MultisigAccount",
           ["resource_not_found", "account_not_found"].contains(json["error_code"] as? String ?? "") {
            let address = url.pathComponents[3]
            if address.hasPrefix("0x"), (3...66).contains(address.count),
               address.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) { return true }
        }
        // Exact Aptos lookup absence is normal while awaiting mempool propagation.
        // Do not suppress account/resource failures or any other 404 envelope.
        if context["chain"] == "aptos", status == 404, request.httpMethod == nil || request.httpMethod == "GET",
           let parts = request.url?.pathComponents, parts.dropLast().suffix(2) == ["transactions", "by_hash"],
           let hash = parts.last, hash.hasPrefix("0x"), hash.count == 66,
           hash.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
           json["error_code"] as? String == "transaction_not_found" { return true }
        if status == 404, request.httpMethod == nil || request.httpMethod == "GET",
           let url = request.url, let value = url.pathComponents.last,
           (url.host == "horizon.stellar.org" || url.host == "horizon-testnet.stellar.org" ||
            (url.host == "rpc.ankr.com" && url.pathComponents.contains("stellar_horizon"))),
           json["type"] as? String == "https://stellar.org/horizon-errors/not_found", json["status"] as? Int == 404 {
            // A new account and a not-yet-ingested transaction are expected
            // absence. Only exact leaf endpoints and Horizon envelopes qualify.
            if url.pathComponents.dropLast().last == "accounts", value.count == 56, value.first == "G",
               value.allSatisfy({ $0.isASCII && ($0.isUppercase || ("2"..."7").contains(String($0))) }) { return true }
            if url.pathComponents.dropLast().last == "transactions", value.count == 64,
               value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) { return true }
        }
        // TON trace indexing is asynchronous. Only the exact read endpoint and
        // the provider's not-found envelope are expected pending control flow.
        if status==404,request.httpMethod==nil || request.httpMethod=="GET",
           let url=request.url,["tonapi.io","testnet.tonapi.io"].contains(url.host ?? ""),
           url.pathComponents.count==4,url.pathComponents[1]=="v2",url.pathComponents[2]=="traces",
           url.lastPathComponent.count==64,url.lastPathComponent.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),
           json["error"] as? String=="entity not found" { return true }
        guard status == 200, let body = request.httpBody, body.count <= 1_048_576,
              let call = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return false }
        if publicAccountPolicyProbe, context["method"] == "account_info", request.httpMethod == "POST",
           let params = (call["params"] as? [[String: Any]])?.first,
           params["ledger_index"] as? String == "validated", params["signer_lists"] as? Bool == true,
           let owner = params["account"] as? String, !owner.isEmpty,
           let result = json["result"] as? [String: Any], result["error"] as? String == "actNotFound",
           result["error_code"] as? Int == 19, result["validated"] as? Bool == true,
           result["account"] as? String == owner { return true }
        // A signed transaction may not have propagated to this XRPL node yet.
        // Suppress only its exact request-bound lookup absence, never submit,
        // account history, provider overload or a mismatched transaction hash.
        if context["chain"] == "xrpl", request.httpMethod == "POST", call["method"] as? String == "tx",
           let params = (call["params"] as? [[String: Any]])?.first,
           let hash = params["transaction"] as? String, hash.count == 64, hash.allSatisfy(\.isHexDigit),
           let result = json["result"] as? [String: Any], result["error"] as? String == "txnNotFound",
           result["error_code"] as? Int == 29, result["status"] as? String == "error",
           let echoed = result["request"] as? [String: Any], echoed["command"] as? String == "tx",
           (echoed["transaction"] as? String)?.uppercased() == hash.uppercased() { return true }
        if context["chain"] == "xrpl", call["method"] as? String == "account_info",
           let params = (call["params"] as? [[String: Any]])?.first,
           let owner = params["account"] as? String, !owner.isEmpty,
           let ledger = params["ledger_hash"] as? String, ledger.count == 64,
           let result = json["result"] as? [String: Any], result["error"] as? String == "actNotFound",
           result["error_code"] as? Int == 19, result["validated"] as? Bool == true,
           result["account"] as? String == owner,
           (result["ledger_hash"] as? String)?.uppercased() == ledger.uppercased() { return true }
        if context["chain"] == "near", call["method"] as? String == "query",
           let params = call["params"] as? [String: Any], params["request_type"] as? String == "view_account",
           let owner = params["account_id"] as? String, !owner.isEmpty,
           let error = json["error"] as? [String: Any], error["code"] as? Int == -32000 {
            if error["data"] as? String == "account \(owner) does not exist while viewing" { return true }
            let cause = error["cause"] as? [String: Any] ?? (error["data"] as? [String: Any])?["cause"] as? [String: Any]
            return cause?["name"] as? String == "UNKNOWN_ACCOUNT" &&
                (cause?["info"] as? [String: Any])?["requested_account_id"] as? String == owner
        }
        return false
    }
    /// NEAR contract panics may embed arbitrary plaintext input, including short
    /// named accounts that cannot be recognized by address-pattern redaction.
    /// Preserve known protocol classifications, not contract-authored panic text.
    static func nearProviderMessage(_ raw:String) -> String {
        let known:Set<String>=["Server error","Parse error","Invalid params","Invalid Request","Method not found",
            "Method disabled, reason: restricted by blockchain schema","Internal error"]
        if known.contains(raw) { return raw }
        if raw=="wasm execution failed with error: MethodResolveError(MethodNotFound)" { return "NEAR contract method not found" }
        if raw.hasPrefix("wasm execution failed with error:") { return "NEAR contract execution failed" }
        return "NEAR provider returned an error"
    }
    /// Optional NEP-145/NEP-148 probing and polling a not-yet-observed transaction are
    /// control flow, not failures. Match only these narrow, request-bound envelopes.
    static func expectedNearControlFlow(_ json:[String:Any],status:Int,request:URLRequest) -> Bool {
        guard status==200,context(request)["chain"]=="near",request.httpMethod=="POST",
              let body=request.httpBody,body.count<=1_048_576,
              let call=(try? JSONSerialization.jsonObject(with:body)) as? [String:Any],
              json["jsonrpc"] as? String=="2.0",
              let replyID=json["id"] as? NSNumber,let callID=call["id"] as? NSNumber,replyID==callID,
              let params=call["params"] as? [String:Any] else { return false }
        if call["method"] as? String == "query", params["request_type"] as? String == "call_function",
           params["method_name"] as? String == "ft_metadata",
           let hash = params["block_id"] as? String, (32...44).contains(hash.count),
           hash.allSatisfy({ "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".contains($0) }),
           json["error"] == nil,
           let result = json["result"] as? [String:Any], result["block_hash"] as? String == hash,
           let height = result["block_height"] as? NSNumber,
           CFGetTypeID(height) != CFBooleanGetTypeID(), Int64(height.stringValue).map({ $0 >= 0 }) == true,
           result["result"] == nil, result["logs"] as? [String] != nil,
           result["error"] as? String == "wasm execution failed with error: MethodResolveError(MethodNotFound)" {
            return true  // No contract metadata extension; never excludes a failed balance/send read.
        }
        if call["method"] as? String=="query",params["request_type"] as? String=="call_function",
           params["method_name"] as? String=="storage_balance_of",
           let hash=params["block_id"] as? String,!hash.isEmpty,
           let result=json["result"] as? [String:Any],result["block_hash"] as? String==hash,
           result["error"] as? String=="wasm execution failed with error: MethodResolveError(MethodNotFound)" { return true }
        if call["method"] as? String=="tx",let hash=params["tx_hash"] as? String,(32...44).contains(hash.count),
           hash.allSatisfy({ "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".contains($0) }),
           let owner=params["sender_account_id"] as? String,!owner.isEmpty,
           let error=json["error"] as? [String:Any],error["code"] as? Int == -32000 {
            let cause=error["cause"] as? [String:Any] ?? (error["data"] as? [String:Any])?["cause"] as? [String:Any]
            // TIMEOUT_ERROR remains diagnostic: an overloaded or non-tracking node
            // can cause it. Only an explicit unknown-transaction state is excluded.
            return cause?["name"] as? String=="UNKNOWN_TRANSACTION"
        }
        return false
    }
    public static func data(for request: URLRequest, session: URLSession,
                            file: String = #fileID, function: String = #function, line: UInt = #line) async throws -> (Data, URLResponse) {
        do {
            let result = try await session.data(for: request)
            if let http = result.1 as? HTTPURLResponse { response(result.0, status: http.statusCode, request: request, file: file, function: function, line: line) }
            return result
        } catch {
            OathDiagnostics.record(error, component: "network", context: context(request), file: file, function: function, line: line)
            throw error
        }
    }
}
