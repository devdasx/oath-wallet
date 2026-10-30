import Foundation
import OathDiagnostics

/// Funding guidance for a confirmed absent/undeployed native account. Token
/// registration, trustlines, transaction gas and account activation differ.
public enum ReceiveActivationRequirement: Sendable, Equatable {
    case stellar(minimumStroops: UInt64)
    case xrpl(minimumDrops: UInt64)
    case solana(minimumLamports: UInt64)
    case tron
    case near
    case ton(needsFunding: Bool)
}

public enum ReceiveActivationStatus: Sendable, Equatable {
    case active
    case inactive(ReceiveActivationRequirement)
    case unavailable
}

/// Small public-state reads only; no inventory, key access or signing. Actor
/// isolation keeps decoding off MainActor. The Receive task owns cancellation
/// and refresh; results are never persisted as permanent account attributes.
///
/// Supported-catalog audit: EVM, UTXO, Sui, Aptos and THORChain have no separate
/// recipient activation reserve for ordinary wallet receipts. Their transfer
/// fees/dust or token-object costs do not make an address an inactive account.
/// References for the distinct account rules handled below:
/// https://developers.stellar.org/docs/build/apps/application-design-considerations
/// https://xrpl.org/docs/concepts/accounts/reserves
/// https://solana.com/docs/core/accounts/account-runtime
/// https://developers.tron.network/docs/account
/// https://github.com/near/nearcore/blob/master/docs/DataStructures/Account.md
/// https://docs.ton.org/standard/wallets/how-it-works
public actor ReceiveActivationCheck {
    public static let networks: Set<String> = ["stellar", "xrpl", "solana", "tron", "near", "ton"]
    private let endpoints: [String: URL]
    private let transport: any AnkrTransport
    typealias JSON = SolanaJSON
    enum Failure: Error { case configuration, malformed, wrongNetwork, http(Int), rpc(Int), provider }

    public init(endpoints: [String: URL], transport: any AnkrTransport = AnkrHTTPTransport()) {
        self.endpoints = endpoints; self.transport = transport
    }

    public func check(network: String, address: String) async -> ReceiveActivationStatus {
        guard Self.networks.contains(network) else { return .unavailable }
        return await OathDiagnostics.$chain.withValue(network) {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    try Task.checkCancellation()
                    guard let url = endpoints[network], url.scheme == "https" else { throw Failure.configuration }
                    let result: ReceiveActivationStatus
                    switch network {
                    case "stellar": result = try await stellar(url, address)
                    case "xrpl": result = try await xrpl(url, address)
                    case "solana": result = try await solana(url, address)
                    case "tron": result = try await tron(url, address)
                    case "near": result = try await near(url, address)
                    case "ton": result = try await ton(url, address)
                    default: return .unavailable
                    }
                    try Task.checkCancellation()
                    return result
                } catch {
                    // Navigation/lock teardown and expected absent accounts are
                    // not failures. Unknown state never becomes an activation warning.
                    if !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                        OathDiagnostics.record(error, component: "receive", operation: "account_activation",
                                               context: ["chain": network])
                    }
                    return .unavailable
                }
            }
        }
    }

    private func request(_ url: URL, body: JSON? = nil) async throws -> (JSON, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, status) = try await transport.send(request)
        try Task.checkCancellation()
        guard data.count <= 1_048_576 else { throw Failure.malformed }
        // AnkrHTTPTransport reports original provider envelopes via DiagnosticHTTP.
        // Decode 404 here only to recognize Horizon's exact account-not-found.
        guard status == 200 || status == 404 else { throw Failure.http(status) }
        return (try JSONDecoder().decode(JSON.self, from: data), status)
    }

    private func rest(_ url: URL, body: JSON? = nil) async throws -> JSON {
        let (json, status) = try await request(url, body: body)
        guard status == 200 else { throw Failure.http(status) }
        return json
    }

    private func envelope(_ url: URL, _ method: String, _ params: JSON) async throws -> JSON {
        let value = try await rest(url, body: .object(["jsonrpc": .string("2.0"), "id": .number("1"),
            "method": .string(method), "params": params]))
        guard value["jsonrpc"].string == "2.0", value["id"].text == "1" else { throw Failure.malformed }
        return value
    }

    private func rpc(_ url: URL, _ method: String, _ params: JSON = .array([])) async throws -> JSON {
        let value = try await envelope(url, method, params)
        guard value["error"].isNull else { throw Failure.rpc(Int(value["error"]["code"].text ?? "") ?? -1) }
        guard !value["result"].isNull else { throw Failure.malformed }
        return value["result"]
    }

    private func stellar(_ url: URL, _ address: String) async throws -> ReceiveActivationStatus {
        let owner = try StellarIdentity.address(address)
        async let infoRead = rest(url)
        async let accountRead = request(url.appendingPathComponent("accounts/" + owner))
        let (info, account) = try await (infoRead, accountRead)
        guard info["network_passphrase"].string == StellarIdentity.network else { throw Failure.wrongNetwork }
        if account.1 == 200 {
            guard account.0["account_id"].string == owner, account.0["sequence"].text != nil else { throw Failure.malformed }
            // Includes sponsored and below-reserve accounts: existence, not balance.
            return .active
        }
        guard account.1 == 404, account.0["status"].integer == 404,
              account.0["type"].string == "https://stellar.org/horizon-errors/not_found",
              let height = info["history_latest_ledger"].integer, height > 0 else { throw Failure.malformed }
        let ledger = try await rest(url.appendingPathComponent("ledgers/" + String(height)))
        guard ledger["sequence"].integer == height,
              let reserve = ledger["base_reserve_in_stroops"].integer, reserve > 0, reserve <= UInt64.max / 2 else {
            throw Failure.malformed
        }
        return .inactive(.stellar(minimumStroops: reserve * 2))
    }

    private func xrplCall(_ url: URL, _ method: String, _ params: [String: JSON]) async throws -> JSON {
        let result = try await rest(url, body: .object(["method": .string(method),
            "params": .array([.object(params.merging(["api_version": .number("2")]) { a, _ in a })])]))["result"]
        guard result.fields != nil else { throw Failure.malformed }
        return result
    }

    private func xrpl(_ url: URL, _ address: String) async throws -> ReceiveActivationStatus {
        let owner = try XrplIdentity.address(address)
        let server = try await xrplCall(url, "server_info", [:])
        guard server["status"].string == "success", server["error"].isNull else { throw Failure.provider }
        let info = server["info"], ledger = info["validated_ledger"]
        guard info["network_id"].isNull || info["network_id"].integer == 0 else { throw Failure.wrongNetwork }
        let hash = try XrplIdentity.hash(ledger["hash"])
        guard let height = ledger["seq"].integer, height > 0 else { throw Failure.malformed }
        let account = try await xrplCall(url, "account_info", ["account": .string(owner), "ledger_hash": .string(hash)])
        guard account["validated"] == .bool(true), account["ledger_hash"].string?.uppercased() == hash else {
            throw Failure.malformed
        }
        if account["status"].string == "success", account["error"].isNull {
            guard account["account_data"]["Account"].string == owner else { throw Failure.malformed }
            return .active
        }
        guard account["error"].string == "actNotFound", account["error_code"].integer == 19,
              account["account"].string == owner else { throw Failure.provider }
        guard let text = ledger["reserve_base_xrp"].text,
              let reserve = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), reserve > 0,
              let drops = UInt64(NSDecimalNumber(decimal: reserve * 1_000_000).stringValue), drops > 0 else {
            throw Failure.malformed
        }
        return .inactive(.xrpl(minimumDrops: drops))
    }

    private func solana(_ url: URL, _ address: String) async throws -> ReceiveActivationStatus {
        guard SolanaIdentity.isAddress(address) else { throw Failure.malformed }
        async let genesisRead = rpc(url, "getGenesisHash")
        async let accountRead = rpc(url, "getAccountInfo", .array([.string(address),
            .object(["encoding": .string("base64"), "commitment": .string("confirmed"),
                     "dataSlice": .object(["offset": .number("0"), "length": .number("0")])])]))
        let (genesis, account) = try await (genesisRead, accountRead)
        guard genesis.string == SolanaIdentity.genesis else { throw Failure.wrongNetwork }
        guard let slot = account["context"]["slot"].integer, slot > 0,
              let value = account.fields?["value"] else { throw Failure.malformed }
        if !value.isNull {
            guard value["lamports"].integer != nil, value["owner"].string != nil else { throw Failure.malformed }
            return .active
        }
        guard let minimum = try await rpc(url, "getMinimumBalanceForRentExemption", .array([
            .number("0"), .object(["commitment": .string("confirmed")])])).integer, minimum > 0 else { throw Failure.malformed }
        return .inactive(.solana(minimumLamports: minimum))
    }

    private func tron(_ url: URL, _ address: String) async throws -> ReceiveActivationStatus {
        guard TronIdentity.isAddress(address) else { throw Failure.malformed }
        async let genesisRead = rest(url.appendingPathComponent("wallet/getblockbynum"), body: .object(["num": .number("0")]))
        async let accountRead = rest(url.appendingPathComponent("walletsolidity/getaccount"), body: .object([
            "address": .string(address), "visible": .bool(true)]))
        let (genesis, account) = try await (genesisRead, accountRead)
        guard genesis["blockID"].string == TronSendNetwork.mainnet.genesisID else { throw Failure.wrongNetwork }
        // Exactly {} means absence; malformed/provider-error objects never do.
        if account == .object([:]) { return .inactive(.tron) }
        let hexAddress = TronSendCrypto.hex(try TronIdentity.bytes(address))
        guard let returned = account["address"].string,
              returned == address || returned.lowercased() == hexAddress else {
            throw Failure.malformed
        }
        return .active
    }

    private func near(_ url: URL, _ address: String) async throws -> ReceiveActivationStatus {
        _ = try NearIdentity.address(address)
        // Oath's derived NEAR addresses are implicit. Named-account creation
        // needs a different flow, not a warning to send funds to a missing name.
        guard address.count == 64, address.allSatisfy(\.isHexDigit) else { return .unavailable }
        async let networkRead = rpc(url, "EXPERIMENTAL_genesis_config", .object([:]))
        async let accountRead = envelope(url, "query", .object(["request_type": .string("view_account"),
            "finality": .string("final"), "account_id": .string(address)]))
        let (network, reply) = try await (networkRead, accountRead)
        guard network["chain_id"].string == "mainnet" else { throw Failure.wrongNetwork }
        if reply["error"].isNull {
            let result = reply["result"]
            guard result["block_height"].integer != nil, result["block_hash"].string != nil,
                  result["amount"].string != nil, result["code_hash"].string != nil else { throw Failure.malformed }
            return .active
        }
        let error = reply["error"]
        let cause = error["cause"].isNull ? error["data"]["cause"] : error["cause"]
        let missing = cause["name"].string == "UNKNOWN_ACCOUNT" && cause["info"]["requested_account_id"].string == address
        let legacyMissing = error["data"].string == "account \(address) does not exist while viewing"
        guard error["code"].text == "-32000", missing || legacyMissing else { throw Failure.provider }
        return .inactive(.near)
    }

    private func ton(_ url: URL, _ address: String) async throws -> ReceiveActivationStatus {
        let owner = try TonIdentity.raw(address)
        async let networkRead = rpc(url, "getMasterchainInfo", .object([:]))
        async let accountRead = rpc(url, "getAddressInformation", .object(["address": .string(owner)]))
        let (network, account) = try await (networkRead, accountRead)
        guard network["init"]["root_hash"].string == TonIdentity.genesis else { throw Failure.wrongNetwork }
        guard let balance = account["balance"].text.flatMap(UInt64.init) else { throw Failure.malformed }
        switch account["state"].string {
        case "active": return .active
        case "uninitialized": return .inactive(.ton(needsFunding: balance == 0))
        // Frozen contracts are not new accounts and need separate recovery.
        case "frozen": return .unavailable
        default: throw Failure.malformed
        }
    }
}
