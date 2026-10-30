import CryptoKit
import Foundation
import OathDiagnostics

/// Only account formats whose signing configuration is discoverable from a
/// public address. Absence here is NOT proof that an address is single-signature.
public enum PublicMultisigChain: String, CaseIterable, Sendable {
    case xrpl, stellar, tron, aptos
}

public struct PublicMultisigAccount: Equatable, Hashable, Sendable {
    public let chain: PublicMultisigChain
    public let address: String
    public let testnet: Bool
    public init(chain: PublicMultisigChain, address: String, testnet: Bool = false) {
        self.chain = chain; self.address = address; self.testnet = testnet
    }
}

public struct PublicMultisigEvidence: Equatable, Sendable {
    public let account: PublicMultisigAccount
    /// Hash of the public signing policy, not a wallet identifier or credential.
    public let policyID: String
}

public enum PublicMultisigResult: Equatable, Sendable {
    case confirmed(PublicMultisigEvidence)
    case notDetected
    case unavailable
}

/// Read-only, bounded and shared across Home reappearances/wallet switches.
/// No vault, signing, credential, account mutation or broadcast dependency.
public actor PublicMultisigCheck {
    public static let shared = PublicMultisigCheck()
    private struct Cached { let result: PublicMultisigResult; let expires: Date }
    private let transport: any AnkrTransport
    private let endpoints: [String: URL]
    private var cache: [PublicMultisigAccount: Cached] = [:]
    private var running: [PublicMultisigAccount: Task<PublicMultisigResult, Never>] = [:]
    public init(endpoints: [String: URL] = [:], transport: any AnkrTransport = AnkrHTTPTransport()) {
        self.endpoints = endpoints; self.transport = transport
    }

    public func check(_ account: PublicMultisigAccount) async -> PublicMultisigResult {
        if let item = cache[account], item.expires > .now { return item.result }
        if let task = running[account] { return await task.value }
        // Saturation is not an app failure and must never hold up Home.
        guard running.count < 8 else { return .unavailable }
        let transport = transport
        // Mainnet configuration must never redirect testnet probes.
        let endpoint = account.testnet ? nil : endpoints[account.chain.rawValue]
        let task = Task {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                await OathDiagnostics.$chain.withValue(account.chain.rawValue) {
                    do { return try await Self.fetch(account, endpoint: endpoint, transport: transport) }
                    catch {
                        OathDiagnostics.record(error, component: "multisig", operation: "public_account_check",
                                               context: ["chain": account.chain.rawValue, "stage": "account_policy"])
                        return .unavailable
                    }
                }
            }
        }
        running[account] = task
        let result = await task.value
        running[account] = nil
        if cache.count >= 128, let oldest = cache.min(by: { $0.value.expires < $1.value.expires })?.key {
            cache[oldest] = nil
        }
        cache[account] = Cached(result: result, expires: .now.addingTimeInterval(result == .unavailable ? 30 : 300))
        return result
    }

    enum Failure: Error { case malformed, http(Int), provider, invalidAddress }

    static func fetch(_ account: PublicMultisigAccount, endpoint: URL? = nil,
                      transport: any AnkrTransport) async throws -> PublicMultisigResult {
        let primary = try request(account, endpoint: endpoint)
        do { return try await read(account, request: primary, transport: transport) }
        catch {
            // One independent read recovers a transient authenticated XRP node
            // failure. Invalid/mismatched policy data stays unavailable, never
            // a negative finding. Other chains retain their existing behavior.
            guard account.chain == .xrpl, !account.testnet, endpoint != nil,
                  primary.url != XrplSendNetwork.mainnet.endpoint,
                  !Task.isCancelled, !(error is CancellationError), Self.isTransient(error) else { throw error }
            OathDiagnostics.record(error, component: "multisig", operation: "public_account_retry",
                context: ["chain": account.chain.rawValue, "stage": "account_policy", "host": primary.url?.host ?? ""])
            try Task.checkCancellation()
            return try await read(account, request: request(account), transport: transport)
        }
    }

    private static func isTransient(_ error: any Error) -> Bool {
        if case AnkrError.transport = error { return true }
        if let url = error as? URLError {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                    .dnsLookupFailed, .notConnectedToInternet].contains(url.code)
        }
        if case Failure.http(let status) = error { return [408, 429, 500, 502, 503, 504].contains(status) }
        return false
    }

    private static func read(_ account: PublicMultisigAccount, request: URLRequest,
                             transport: any AnkrTransport) async throws -> PublicMultisigResult {
        try Task.checkCancellation()
        let (data, status) = try await DiagnosticHTTP.$publicAccountPolicyProbe.withValue(true) {
            try await transport.send(request)
        }
        try Task.checkCancellation()
        guard data.count <= 2 * 1024 * 1024 else { throw Failure.malformed }
        guard (200..<300).contains(status) || status == 404 else { throw Failure.http(status) }
        let json = try JSONDecoder().decode(TronJSON.self, from: data)
        // Unfunded accounts / absent standard resource are ordinary negative
        // probes. Generic HTTP failures, malformed 404s and RPC errors are not.
        if status == 404 {
            if account.chain == .stellar, json["status"].integer == 404,
               json["type"].string == "https://stellar.org/horizon-errors/not_found" { return .notDetected }
            if account.chain == .aptos, ["resource_not_found", "account_not_found"].contains(json["error_code"].string ?? "") {
                return .notDetected
            }
        }
        guard (200..<300).contains(status) else { throw Failure.http(status) }
        return try parse(json, account: account)
    }

    static func request(_ account: PublicMultisigAccount, endpoint: URL? = nil) throws -> URLRequest {
        let address = account.address
        var url: URL
        var body: TronJSON?
        switch account.chain {
        case .xrpl:
            guard (try? XrplIdentity.address(address)) == address else { throw Failure.invalidAddress }
            url = endpoint ?? (account.testnet ? XrplSendNetwork.testnet : .mainnet).endpoint
            body = .object(["method": .string("account_info"), "params": .array([.object([
                "account": .string(address), "ledger_index": .string("validated"),
                "signer_lists": .bool(true), "api_version": .number("2")])])])
        case .stellar:
            guard (try? StellarIdentity.address(address)) == address else { throw Failure.invalidAddress }
            url = (endpoint ?? (account.testnet ? StellarSendNetwork.testnet : .mainnet).horizon)
                .appendingPathComponent("accounts").appendingPathComponent(address)
        case .tron:
            guard TronIdentity.isAddress(address) else { throw Failure.invalidAddress }
            url = (endpoint ?? (account.testnet ? TronSendNetwork.nile : .mainnet).endpoint)
                .appendingPathComponent("walletsolidity/getaccount")
            body = .object(["address": .string(address), "visible": .bool(true)])
        case .aptos:
            guard (try? AptosIdentity.address(address)) != nil else { throw Failure.invalidAddress }
            url = (endpoint ?? URL(string: account.testnet ? "https://api.testnet.aptoslabs.com/v1" : "https://api.mainnet.aptoslabs.com/v1")!)
                .appendingPathComponent("accounts").appendingPathComponent(address)
                .appendingPathComponent("resource").appendingPathComponent("0x1::multisig_account::MultisigAccount")
        }
        guard url.scheme == "https", url.user == nil, url.password == nil else { throw Failure.malformed }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    static func parse(_ json: TronJSON, account: PublicMultisigAccount) throws -> PublicMultisigResult {
        var policy: TronJSON
        switch account.chain {
        case .xrpl:
            let result = json["result"]
            if result["error"].string == "actNotFound", result["error_code"].integer == 19,
               result["validated"] == .bool(true), result["account"].string == account.address {
                return .notDetected
            }
            guard result["error"].isNull, result["status"].string == "success",
                  result["validated"] == .bool(true), result["account_data"]["Account"].string == account.address else {
                throw Failure.provider
            }
            // v2/Clio puts signer_lists at result; v1 nests it in account_data.
            // Documented omission means no list, even with signer_lists=true.
            policy = result["signer_lists"].isNull ? result["account_data"]["signer_lists"] : result["signer_lists"]
            if policy.isNull { return .notDetected }
            guard let lists = policy.array, lists.count <= 1 else { throw Failure.malformed }
            if lists.isEmpty { return .notDetected }
            let list = lists[0]
            guard let quorum = list["SignerQuorum"].integer, quorum > 0, quorum <= UInt32.max,
                  let entries = list["SignerEntries"].array, (1...32).contains(entries.count) else { throw Failure.malformed }
            var keys = Set<String>(), total: UInt64 = 0
            for entry in entries {
                let entry = entry["SignerEntry"]
                guard let key = entry["Account"].string, key != account.address, (try? XrplIdentity.address(key)) == key,
                      keys.insert(key).inserted, let weight = entry["SignerWeight"].integer, (1...65535).contains(weight) else {
                    throw Failure.malformed
                }
                total += weight
            }
            guard quorum <= total else { throw Failure.malformed }
            // Exclude ledger/index metadata so unrelated transactions don't
            // produce a new warning. No assumption that the master is disabled.
            policy = .object(["quorum": .number(String(quorum)), "entries": list["SignerEntries"]])
        case .stellar:
            guard json["account_id"].string == account.address,
                  let signers = json["signers"].array, (1...21).contains(signers.count) else { throw Failure.malformed }
            for key in ["low_threshold", "med_threshold", "high_threshold"] {
                guard let value = json["thresholds"][key].integer, value <= 255 else { throw Failure.malformed }
            }
            var active = 0, keys = Set<String>()
            for signer in signers {
                guard let key = signer["key"].string, keys.insert(key).inserted, let type = signer["type"].string,
                      let weight = signer["weight"].integer, weight <= 255 else { throw Failure.malformed }
                try StellarIdentity.validateSigner(key, type: type)
                if weight > 0 { active += 1 }
            }
            // A disabled master plus one replacement signer is delegated
            // control, not evidence of a multiple-signer configuration.
            guard active > 1 else { return .notDetected }
            policy = .object(["thresholds": json["thresholds"], "signers": json["signers"]])
        case .tron:
            if json == .object([:]) { return .notDetected } // unactivated account
            guard let address = json["address"].string, (try? TronIdentity.address(address)) == account.address else { throw Failure.malformed }
            var permissions: [TronPermissionControl.Permission] = []
            if !json["owner_permission"].isNull {
                permissions.append(try tronPermission(json["owner_permission"], type: 0, id: 0))
            }
            if !json["active_permission"].isNull {
                guard let values = json["active_permission"].array, values.count <= 8 else { throw Failure.malformed }
                for (index, value) in values.enumerated() {
                    permissions.append(try tronPermission(value, type: 2, id: UInt64(index + 2)))
                }
            }
            guard permissions.contains(where: { $0.keys.count > 1 && ($0.type == 0 || $0.operations.contains(where: { $0 != "0" })) }) else {
                return .notDetected
            }
            policy = .object(["owner": json["owner_permission"], "active": json["active_permission"]])
        case .aptos:
            guard json["type"].string == "0x1::multisig_account::MultisigAccount",
                  let owners = json["data"]["owners"].array, !owners.isEmpty, owners.count <= 1024,
                  let raw = json["data"]["num_signatures_required"].string, let threshold = UInt64(raw),
                  threshold > 0, threshold <= owners.count else { throw Failure.malformed }
            var keys = Set<String>()
            for owner in owners {
                guard let raw = owner.string, let key = try? AptosIdentity.address(raw), keys.insert(key).inserted else { throw Failure.malformed }
            }
            policy = .object(["owners": json["data"]["owners"], "threshold": .string(raw)])
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let id = SHA256.hash(data: try encoder.encode(policy)).map { String(format: "%02x", $0) }.joined()
        return .confirmed(.init(account: account, policyID: id))
    }

    private static func tronPermission(_ json: TronJSON, type: UInt64, id: UInt64) throws -> TronPermissionControl.Permission {
        guard var fields = json.fields else { throw Failure.malformed }
        // Protobuf JSON can omit the empty name. It is optional display
        // metadata, not part of the threshold/weight authorization decision.
        if fields["permission_name"] == nil { fields["permission_name"] = .string("") }
        return try .decode(.object(fields), type: type, id: id)
    }
}
