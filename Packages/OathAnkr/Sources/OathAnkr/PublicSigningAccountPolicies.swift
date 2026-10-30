import CryptoKit
import Foundation

extension PublicSigningAuthority {
    static func accountPolicy(_ json: J, account: PublicMultisigAccount) throws -> PublicSigningAssessment {
        // Reuse the existing address, threshold, unique-signer and response
        // identity validation before inspecting additional authority paths.
        let original = try PublicMultisigCheck.parse(json, account: account)
        var findings = Set<PublicSigningFinding>()
        switch account.chain {
        case .xrpl:
            if case .confirmed = original { findings.insert(.multisig) }
            let data = json["result"]["account_data"]
            if !data["RegularKey"].isNull {
                guard let key = data["RegularKey"].string, (try? XrplIdentity.address(key)) == key else { throw Failure.malformed }
                if key != account.address { findings.insert(.differentSigner) }
            }
            if !data.isNull {
                let flags = try uint(data["Flags"])
                if flags & 0x0010_0000 != 0 { findings.insert(.restricted) }
            }
        case .stellar:
            guard let signers = json["signers"].array else { throw Failure.malformed }
            let active = signers.filter { ($0["weight"].integer ?? 0) > 0 }
            let thresholds = try ["low_threshold", "med_threshold", "high_threshold"].map { try uint(json["thresholds"][$0]) }
            let maximum = active.compactMap { $0["weight"].integer }.max() ?? 0
            let master = active.first { $0["key"].string == account.address }?["weight"].integer ?? 0
            if active.count > 1 { findings.insert(.additionalSigners) }
            if thresholds.contains(where: { $0 > maximum }) && active.count > 1 { findings.insert(.multisig) }
            if active.contains(where: { $0["key"].string != account.address }) { findings.insert(.differentSigner) }
            if master == 0 || thresholds.contains(where: { $0 > master }) { findings.insert(.restricted) }
        case .tron:
            if json == .object([:]) { return .init(coverage: .checked) }
            var permissions: [TronPermissionControl.Permission] = []
            if !json["owner_permission"].isNull {
                permissions.append(try tronPermission(json["owner_permission"], type: 0, id: 0))
            }
            if let actives = json["active_permission"].array {
                for (index, active) in actives.enumerated() {
                    permissions.append(try tronPermission(active, type: 2, id: UInt64(index + 2)))
                }
            }
            for permission in permissions where permission.type == 0 || permission.operations.contains(where: { $0 != "0" }) {
                if permission.keys.count > 1 { findings.insert(.additionalSigners) }
                if permission.keys.allSatisfy({ $0.weight < permission.threshold }) { findings.insert(.multisig) }
                if permission.keys.contains(where: { $0.address != account.address }) { findings.insert(.differentSigner) }
                if (permission.keys.first { $0.address == account.address }?.weight ?? 0) < permission.threshold {
                    findings.insert(.restricted)
                }
            }
        case .aptos:
            // The resource itself is a multisig account even for a 1-of-N policy.
            if case .confirmed = original { findings.insert(.multisig) }
        }
        return .init(coverage: .checked, findings: findings)
    }

    private static func tronPermission(_ json: J, type: UInt64, id: UInt64) throws -> TronPermissionControl.Permission {
        guard case .object(var fields) = json else { throw Failure.malformed }
        if fields["permission_name"] == nil { fields["permission_name"] = .string("") }
        return try .decode(.object(fields), type: type, id: id)
    }

    func aptosAuthentication(_ account: PublicSigningAccount) async throws -> PublicSigningAssessment {
        let address = try AptosIdentity.address(account.address)
        let url = (endpoints["aptos"] ?? URL(string: "https://api.mainnet.aptoslabs.com/v1")!)
            .appendingPathComponent("accounts").appendingPathComponent(address)
        let (json, status) = try await read(URLRequest(url: url, timeoutInterval: 12))
        if status == 404, json["error_code"].string == "account_not_found" { return .init(coverage: .checked) }
        guard status == 200, let key = json["authentication_key"].string else { throw Failure.provider }
        let normalized = try AptosIdentity.address(key)
        // A changed authentication key is evidence of alternate control, not
        // proof of a multi-key policy. Resource-account keys may also be zero.
        return .init(coverage: .checked, findings: normalized == address ? [] : [.differentSigner])
    }

    func near(_ account: PublicSigningAccount) async throws -> PublicSigningAssessment {
        _ = try NearIdentity.address(account.address)
        let endpoint = endpoints["near"] ?? URL(string: "https://rpc.mainnet.near.org")!
        let result = try await rpc(endpoint.absoluteString, "query", .object([
            "request_type": .string("view_access_key_list"), "finality": .string("final"),
            "account_id": .string(account.address)]))
        // NEAR returns an empty access-key list even for an uncreated account.
        // Confirm existence at the same block before marking a keyless account
        // restricted; imported implicit addresses are frequently still unused.
        if result["keys"].array?.isEmpty == true {
            guard let block = result["block_hash"].string else { throw Failure.malformed }
            var request = URLRequest(url: endpoint, timeoutInterval: 12)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(J.object(["jsonrpc": .string("2.0"), "id": .number("1"),
                "method": .string("query"), "params": .object(["request_type": .string("view_account"),
                    "block_id": .string(block), "account_id": .string(account.address)])]))
            let (json, status) = try await read(request)
            guard status == 200 else { throw Failure.http(status) }
            if try !Self.nearAccountExists(json, address: account.address) { return .init(coverage: .checked) }
        }
        return try Self.nearPolicy(result, address: account.address)
    }

    static func nearAccountExists(_ json: J, address: String) throws -> Bool {
        guard json["jsonrpc"].string == "2.0", json["id"].integer == 1 else { throw Failure.malformed }
        if json["error"]["code"].text == "-32000",
           json["error"]["data"].string == "account \(address) does not exist while viewing" { return false }
        if json["error"]["cause"]["name"].string == "UNKNOWN_ACCOUNT",
           json["error"]["cause"]["info"]["account_id"].string == address { return false }
        guard json["error"].isNull, let amount = json["result"]["amount"].string, !amount.isEmpty,
              amount.allSatisfy({ $0.isASCII && $0.isNumber }),
              json["result"]["storage_usage"].integer != nil else { throw Failure.provider }
        return true
    }

    static func nearPolicy(_ result: J, address: String) throws -> PublicSigningAssessment {
        guard let keys = result["keys"].array, keys.count <= 1024 else { throw Failure.malformed }
        var seen = Set<String>(), full: [String] = [], limited = false
        for key in keys {
            guard let pubkey = key["public_key"].string, seen.insert(pubkey).inserted else { throw Failure.malformed }
            let pieces = pubkey.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count == 2, ["ed25519", "secp256k1"].contains(pieces[0]),
                  let bytes = try? SolanaSendCrypto.decode(String(pieces[1])),
                  bytes.count == (pieces[0] == "ed25519" ? 32 : 64) else { throw Failure.malformed }
            let permission = key["access_key"]["permission"]
            if permission == .string("FullAccess") { full.append(pubkey) }
            else if !permission["FunctionCall"].isNull { limited = true }
            else { throw Failure.malformed }
        }
        var findings = Set<PublicSigningFinding>()
        if keys.count > 1 { findings.insert(.additionalSigners) }
        if limited { findings.insert(.differentSigner) }
        if full.isEmpty { findings.insert(.restricted) }
        // Named NEAR accounts have no address-derived original signing key.
        // For implicit Ed25519 accounts, compare the actual public key bytes.
        if address.count == 64, let original = try? TronIdentity.hex(address) {
            let ownKey = "ed25519:" + SolanaSendCrypto.encode(original)
            if !full.contains(ownKey) { findings.formUnion([.differentSigner, .restricted]) }
        }
        return .init(coverage: .checked, findings: findings)
    }

    static func solanaPolicy(_ result: J) throws -> PublicSigningAssessment {
        guard case .object(let fields) = result, fields["value"] != nil else { throw Failure.malformed }
        let value = result["value"]
        if value.isNull { return .init(coverage: .checked) }
        guard let owner = value["owner"].string, SolanaIdentity.isAddress(owner),
              let data = value["data"].array, data.count == 2, data[1].string == "base64",
              let encoded = data[0].string, let bytes = Data(base64Encoded: encoded),
              value["executable"] == .bool(false) else { throw Failure.malformed }
        if owner == SolanaIdentity.tokenProgram || owner == SolanaIdentity.token2022Program {
            // SPL Multisig is exactly 355 bytes; token/mint accounts are not multisigs.
            if bytes.count == 355 {
                let m = Int(bytes[0]), n = Int(bytes[1])
                guard bytes[2] == 1, (1...11).contains(n), (1...n).contains(m) else { throw Failure.malformed }
                let keys = (0..<n).map { bytes.subdata(in: (3 + $0 * 32)..<(35 + $0 * 32)) }
                guard Set(keys).count == n else { throw Failure.malformed }
                return .init(coverage: .checked, findings: [.multisig])
            }
            return .init(coverage: .checked, findings: [.contractControlled])
        }
        if owner == "SQDS4ep65T869zMMBKyuUq6aD6EgTu8psMjkvj52pCf" {
            guard bytes.count >= 100,
                  bytes.prefix(8) == Data(SHA256.hash(data: Data("account:Multisig".utf8)).prefix(8)) else {
                return .init(coverage: .notDiscoverable, findings: [.contractControlled])
            }
            let threshold = Int(bytes[72]) | Int(bytes[73]) << 8
            let option = bytes[94]
            guard option <= 1 else { throw Failure.malformed }
            let countOffset = 96 + (option == 1 ? 32 : 0)
            guard bytes.count >= countOffset + 4 else { throw Failure.malformed }
            let count = (0..<4).reduce(0) { $0 | Int(bytes[countOffset + $1]) << (8 * $1) }
            guard (1...1024).contains(count), bytes.count >= countOffset + 4 + count * 33 else { throw Failure.malformed }
            var keys = Set<Data>(), voters = 0
            for i in 0..<count {
                let start = countOffset + 4 + i * 33
                guard keys.insert(bytes.subdata(in: start..<(start + 32))).inserted else { throw Failure.malformed }
                let permissions = bytes[start + 32]
                guard permissions <= 7 else { throw Failure.malformed }
                if permissions & 2 != 0 { voters += 1 }
            }
            guard threshold > 0, threshold <= voters else { throw Failure.malformed }
            var findings: Set<PublicSigningFinding> = [.multisig]
            if bytes[40..<72].contains(where: { $0 != 0 }) { findings.insert(.differentSigner) }
            return .init(coverage: .checked, findings: findings)
        }
        if owner == "11111111111111111111111111111111" {
            // A system-owned PDA may still be a program's vault. Do not claim
            // that account ownership proves a single signer.
            return .init(coverage: .notDiscoverable)
        }
        return .init(coverage: .notDiscoverable, findings: [.contractControlled])
    }

    static func cosmosPolicy(_ json: J, address: String) throws -> PublicSigningAssessment {
        var account = json["account"]
        if !account["base_account"].isNull { account = account["base_account"] }
        guard account["address"].string == address else { throw Failure.malformed }
        let key = account["pub_key"]
        if key.isNull { return .init(coverage: .notDiscoverable) }
        if key["@type"].string == "/cosmos.crypto.multisig.LegacyAminoPubKey" {
            guard let keys = key["public_keys"].array, !keys.isEmpty, keys.count <= 1024 else { throw Failure.malformed }
            let threshold = try uint(key["threshold"])
            guard threshold > 0, threshold <= keys.count else { throw Failure.malformed }
            return .init(coverage: .checked, findings: [.multisig])
        }
        guard key["@type"].string == "/cosmos.crypto.secp256k1.PubKey" else {
            return .init(coverage: .notDiscoverable)
        }
        return .init(coverage: .checked)
    }
}
