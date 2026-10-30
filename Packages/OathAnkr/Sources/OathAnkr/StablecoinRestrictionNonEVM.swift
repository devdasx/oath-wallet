import Foundation
import OathDiagnostics

extension StablecoinRestrictionCheck {
    func xrplRestricted(_ account: StablecoinRestrictionAccount, _ token: StablecoinRestrictionToken, _ url: URL) async throws -> Bool {
        let envelope = try await DiagnosticHTTP.$xrplHolderPolicyProbe.withValue(true) {
            try await request(url, .object(["method": .string("account_info"), "params": .array([.object([
                "account": .string(account.address), "ledger_index": .string("validated")])])]))
        }
        // Clio's exact request-bound absence means this holder has no trustline.
        // The issuer request below deliberately runs outside that scope.
        if envelope.isNull { return false }
        let owner = envelope["result"]
        if owner["error"].string == "actNotFound", owner["error_code"].integer == 19,
           owner["validated"] == .bool(true), owner["account"].string == account.address { return false }
        guard owner["status"].string == "success", owner["error"].isNull, owner["validated"] == .bool(true),
              owner["account_data"]["Account"].string == account.address,
              let ledger = owner["ledger_index"].integer else { throw Failure.provider }
        let issuer = try await xrpl(url, "account_info", ["account": .string(token.reference), "ledger_index": .number(String(ledger))])
        guard issuer["validated"] == .bool(true), issuer["account_data"]["Account"].string == token.reference,
              let flags = issuer["account_data"]["Flags"].integer else { throw Failure.malformed }
        let lines = try await xrpl(url, "account_lines", ["account": .string(account.address),
            "peer": .string(token.reference), "ledger_index": .number(String(ledger)), "limit": .number("400")])
        guard lines["validated"] == .bool(true), lines["account"].string == account.address,
              lines["marker"].isNull, let rows = lines["lines"].array else { throw Failure.malformed }
        // Omitted flags in rippled mean false. Our own freeze flag does not
        // mean the issuer blocked us: inspect the peer's freeze flags.
        for row in rows where row["account"].string == token.reference && row["currency"].string == token.method {
            for key in ["freeze_peer", "deep_freeze_peer"] where !row[key].isNull {
                if try Self.boolean(row[key]) { return true }
            }
            if flags & 0x00400000 != 0 { return true } // issuer GlobalFreeze
        }
        return false
    }

    func tonRestricted(_ account: StablecoinRestrictionAccount, _ token: StablecoinRestrictionToken, _ url: URL) async throws -> Bool {
        let owner = try TonIdentity.raw(account.address)
        let derived = try await rpc(url, "runGetMethod", .object(["address": .string(token.reference),
            "method": .string("get_wallet_address"), "stack": .array([.array([.string("tvm.Slice"), .string(try TonIdentity.addressSlice(owner))])])]))
        let wallet = try TonIdentity.walletAddress(derived)
        let state = try await rpc(url, "getAddressInformation", .object(["address": .string(wallet)]))
        if state["state"].string == "uninitialized" { return false }
        guard state["state"].string == "active" else { throw Failure.malformed }
        let data = try await rpc(url, "getTokenData", .object(["address": .string(wallet)]))
        guard data["contract_type"].string == "jetton_wallet",
              let holder = data["owner"].string, try TonIdentity.raw(holder) == owner,
              let master = data["jetton"].string, try TonIdentity.raw(master) == token.reference else { throw Failure.malformed }
        let result = try await rpc(url, "runGetMethod", .object(["address": .string(wallet),
            "method": .string(token.method), "stack": .array([])]))
        return try Self.tonFrozen(result)
    }
    static func tonFrozen(_ result: JSON) throws -> Bool {
        guard result["exit_code"].integer == 0, let stack = result["stack"].array, stack.count == 1,
              let value = stack[0].array, value.count == 2, value[0].string == "num",
              let raw = value[1].string, raw.hasPrefix("0x"), let status = UInt8(raw.dropFirst(2), radix: 16),
              status <= 3 else { throw Failure.malformed }
        return status != 0 // outgoing and/or incoming lock, not a scam-list flag
    }

    func suiQuery(_ url: URL, _ query: String, _ variables: [String: JSON]) async throws -> JSON {
        let response = try await request(url, .object(["query": .string(query), "variables": .object(variables)]))
        guard response["errors"].isNull || response["errors"] == .array([]) else { throw Failure.provider }
        guard response["data"]["chainIdentifier"].string == SuiIdentity.mainnet else { throw Failure.wrongNetwork }
        return response["data"]
    }
    func suiRestricted(_ account: StablecoinRestrictionAccount, _ token: StablecoinRestrictionToken, _ url: URL) async throws -> Bool {
        let object = try await suiQuery(url, """
            {chainIdentifier address(address:"0x403"){asObject{owner{__typename ...on Shared{initialSharedVersion}}}}}
            """, [:])["address"]["asObject"]["owner"]
        guard object["__typename"].string == "Shared", let version = object["initialSharedVersion"].integer else { throw Failure.malformed }
        let bytes = try Self.suiReadOnlyBytes(owner: account.address, type: token.reference, sharedVersion: version)
        // Simulation only: fixed read functions, no signing, submission, wallet
        // funds or gas coins. Both epochs matter during blocklist transitions.
        let result = try await suiQuery(url, """
            query($tx:JSON!){chainIdentifier simulateTransaction(transaction:$tx,checksEnabled:false,doGasSelection:false){
              effects{status} outputs{returnValues{value{type{repr} bcs}}}
            }}
            """, ["tx": .object(["bcs": .object(["value": .string(bytes.base64EncodedString())])])])
        return try Self.suiRestrictedResult(result["simulateTransaction"])
    }
    static func suiReadOnlyBytes(owner: String, type: String, sharedVersion: UInt64) throws -> Data {
        let inputs = [
            Data([1, 1]) + (try SuiBCS.address("0x403")) + SuiBCS.u64(sharedVersion) + Data([0]),
            Data([0]) + SuiBCS.vector(try SuiBCS.address(owner))
        ]
        let commands = try ["deny_list_v2_contains_current_epoch", "deny_list_v2_contains_next_epoch"].map { function in
            Data([0]) + (try SuiBCS.address("0x2")) + SuiBCS.string("coin") + SuiBCS.string(function)
                + SuiBCS.list([try SuiBCS.type(type)]) + SuiBCS.list([SuiBCS.input(0), SuiBCS.input(1)])
        }
        // TransactionData::V1, programmable transaction, empty gas payment,
        // synthetic zero sender (not the wallet), no expiration.
        return Data([0, 0]) + SuiBCS.list(inputs) + SuiBCS.list(commands) + (try SuiBCS.address("0x0"))
            + Data([0]) + (try SuiBCS.address("0x0")) + SuiBCS.u64(1000) + SuiBCS.u64(100_000_000) + Data([0])
    }
    static func suiRestrictedResult(_ json: JSON) throws -> Bool {
        guard json["effects"]["status"].string == "SUCCESS", let outputs = json["outputs"].array, outputs.count == 2 else { throw Failure.provider }
        var restricted = false
        for output in outputs {
            guard let values = output["returnValues"].array, values.count == 1,
                  values[0]["value"]["type"]["repr"].string == "bool",
                  let raw = values[0]["value"]["bcs"].string, let bytes = Data(base64Encoded: raw), bytes.count == 1,
                  bytes[0] <= 1 else { throw Failure.malformed }
            restricted = restricted || bytes[0] == 1
        }
        return restricted
    }
}
