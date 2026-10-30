import CryptoKit
import Foundation
import OathDiagnostics

/// Public account policy only. No secret, signing, approval or broadcast API.
public struct PublicSigningAccount: Codable, Hashable, Sendable {
    public let network: String
    public let address: String
    public init(network: String, address: String) {
        self.network = ["eth": "ethereum", "bsc": "bnb", "xrp": "xrpl",
                        "bitcoin_cash": "bitcoincash"][network] ?? network
        self.address = address
    }
}

public enum PublicSigningFinding: String, Codable, Hashable, Sendable {
    case multisig, additionalSigners, differentSigner, restricted, delegatedCode, contractControlled
}

public struct PublicSigningAssessment: Codable, Equatable, Sendable {
    public enum Coverage: String, Codable, Sendable { case checked, unavailable, notDiscoverable }
    public let coverage: Coverage
    public let findings: Set<PublicSigningFinding>
    public let checkedAt: Date
    public init(coverage: Coverage, findings: Set<PublicSigningFinding> = [], checkedAt: Date = .now) {
        self.coverage = coverage; self.findings = findings; self.checkedAt = checkedAt
    }
    public var hasFinding: Bool { !findings.isEmpty }
}

/// Caller supplies scheduling. Each request is read-only, has a timeout and a
/// byte limit; cancellation propagates instead of becoming a negative result.
public struct PublicSigningAuthority: Sendable {
    let transport: any AnkrTransport
    let endpoints: [String: URL]
    public init(endpoints: [String: URL] = [:], transport: any AnkrTransport = AnkrHTTPTransport()) {
        self.endpoints = endpoints; self.transport = transport
    }
    enum Failure: Error { case malformed, provider, http(Int), wrongNetwork }
    typealias J = SolanaJSON

    public func check(_ account: PublicSigningAccount) async throws -> PublicSigningAssessment {
        try await OathDiagnostics.$operationID.withValue(UUID()) {
            try await OathDiagnostics.$chain.withValue(account.network) {
                do {
                    try Task.checkCancellation()
                    let result = try await fetch(account)
                    try Task.checkCancellation()
                    return result
                } catch {
                    if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                        throw CancellationError()
                    }
                    OathDiagnostics.record(error, component: "multisig", operation: "vault_public_authority",
                                           context: ["chain": account.network, "stage": "account_policy"])
                    return .init(coverage: .unavailable)
                }
            }
        }
    }

    func fetch(_ account: PublicSigningAccount) async throws -> PublicSigningAssessment {
        guard !account.address.isEmpty, account.address.utf8.count <= 256 else { throw Failure.malformed }
        if let chain = PublicMultisigChain(rawValue: account.network) {
            let publicAccount = PublicMultisigAccount(chain: chain, address: account.address)
            let request = try PublicMultisigCheck.request(publicAccount, endpoint: endpoints[account.network])
            let (json, status) = try await read(request)
            if status == 404 {
                if chain == .stellar, json["status"].integer == 404,
                   json["type"].string == "https://stellar.org/horizon-errors/not_found" {
                    return .init(coverage: .checked)
                }
                if chain == .aptos, ["resource_not_found", "account_not_found"].contains(json["error_code"].string ?? "") {
                    return try await aptosAuthentication(account)
                }
            }
            guard status == 200 else { throw Failure.http(status) }
            return try Self.accountPolicy(json, account: publicAccount)
        }
        if let endpoint = Self.evmEndpoints[account.network] {
            return try await evm(account, endpoint: endpoints[account.network]?.absoluteString ?? endpoint)
        }
        switch account.network {
        case "solana":
            guard SolanaIdentity.isAddress(account.address) else { throw Failure.malformed }
            let result = try await rpc(endpoints["solana"]?.absoluteString ?? "https://api.mainnet-beta.solana.com", "getAccountInfo",
                .array([.string(account.address), .object(["encoding": .string("base64"), "commitment": .string("finalized")])]))
            return try Self.solanaPolicy(result)
        case "near": return try await near(account)
        case "thorchain":
            let address = try ThorchainIdentity.address(account.address)
            let json = try await get(ThorchainClient.node.appendingPathComponent("cosmos/auth/v1beta1/accounts").appendingPathComponent(address))
            return try Self.cosmosPolicy(json, address: address)
        default:
            // Script hashes, Taproot/MPC, Sui and arbitrary TON/custom contracts
            // do not reveal their signer policy from a public address alone.
            return .init(coverage: .notDiscoverable)
        }
    }

    func read(_ request: URLRequest) async throws -> (J, Int) {
        var request = request
        request.setValue("OathVault/1.0", forHTTPHeaderField: "User-Agent")
        let (data, status) = try await DiagnosticHTTP.$publicAccountPolicyProbe.withValue(true) {
            try await transport.send(request)
        }
        try Task.checkCancellation()
        guard data.count <= 2 * 1024 * 1024 else { throw Failure.malformed }
        return (try JSONDecoder().decode(J.self, from: data), status)
    }

    func get(_ url: URL) async throws -> J {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (json, status) = try await read(request)
        guard status == 200 else { throw Failure.http(status) }
        return json
    }

    func rpc(_ endpoint: String, _ method: String, _ params: J) async throws -> J {
        guard let url = URL(string: endpoint), url.scheme == "https" else { throw Failure.malformed }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(J.object([
            "jsonrpc": .string("2.0"), "id": .number("1"), "method": .string(method), "params": params]))
        let (json, status) = try await read(request)
        guard status == 200 else { throw Failure.http(status) }
        guard json["error"].isNull, json["id"].integer == 1,
              case .object(let fields) = json, fields["result"] != nil else { throw Failure.provider }
        return json["result"]
    }

    static func uint(_ value: J) throws -> UInt64 {
        if let n = value.integer { return n }
        if let s = value.string, !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }), let n = UInt64(s) { return n }
        throw Failure.malformed
    }
}
