import Foundation

/// A permission restricts this wallet when the wallet's own key cannot satisfy it
/// alone: the threshold needs several signers, or the owner permission has been
/// moved to other keys. Extra keys or a high threshold by themselves prove nothing;
/// weights are compared exactly against the threshold.
struct TronAccountPermissions: Equatable, Sendable {
    let address: String
    let isActivated: Bool
    /// Permission IDs this wallet's key cannot satisfy on its own. 0 is the owner.
    let restrictedPermissionIDs: [Int]

    var isRestricted: Bool { !restrictedPermissionIDs.isEmpty }

    static func decode(_ data: Data, expectedAddress: String) throws -> Self {
        guard let expected = canonicalAddress(expectedAddress) else {
            throw invalid("requested_address")
        }
        let account: Account
        do { account = try JSONDecoder().decode(Account.self, from: data) }
        catch { throw invalid("schema") }
        // An empty object is the node's inactive-account response. It is not a
        // positive permission finding. Error objects must never become defaults.
        guard let returned = account.address else {
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard object?.isEmpty == true else { throw invalid("missing_address") }
            return Self(address: expectedAddress, isActivated: false, restrictedPermissionIDs: [])
        }
        guard canonicalAddress(returned) == expected else { throw invalid("address_mismatch") }
        // Modified active permissions must come with a valid owner permission.
        guard account.active_permission == nil || account.owner_permission != nil else {
            throw invalid("missing_owner")
        }
        var ids = Set<Int>()
        var multi: [Int] = []
        if let owner = account.owner_permission {
            guard (owner.id ?? 0) == 0, owner.type == nil || owner.type == "Owner",
                  owner.parent_id == nil || owner.parent_id == 0 else { throw invalid("owner") }
            // The owner permission covers every operation, so it must stay within
            // reach of this wallet's key alone; otherwise another key holds the account.
            if try owner.requiresMultipleSigners() || !owner.isSatisfiedAlone(by: expected) {
                multi.append(0)
            }
            ids.insert(0)
        }
        let active = account.active_permission ?? []
        guard active.count <= 8 else { throw invalid("active_count") }
        for permission in active {
            guard let id = permission.id, (2...9).contains(id), ids.insert(id).inserted,
                  permission.type == "Active",
                  permission.parent_id == nil || permission.parent_id == 0,
                  let operations = permission.operations,
                  operations.utf8.count == 64, operations.utf8.allSatisfy(isHex)
            else { throw invalid("active") }
            if try permission.requiresMultipleSigners() { multi.append(id) }
        }
        return Self(address: expectedAddress, isActivated: true, restrictedPermissionIDs: multi.sorted())
    }

    static func canonicalAddress(_ value: String) -> String? {
        if let hex = TronValueParser.accountHexAddress(value) { return hex.lowercased() }
        let hex = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
        guard hex.utf8.count == 42, hex.lowercased().hasPrefix("41"),
              hex.utf8.allSatisfy(isHex) else { return nil }
        return hex.lowercased()
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private static func invalid(_ detail: String) -> SendTransactionSubmissionError {
        .provider(networkID: TronConstants.networkID,
                  code: "invalid_account_permissions_" + detail,
                  message: WalletLocalization.string("tron.permissions.unavailable"))
    }

    private struct Account: Decodable {
        let address: String?
        let owner_permission: Permission?
        let active_permission: [Permission]?
    }

    private struct Permission: Decodable {
        let id: Int?
        let type: String?
        let parent_id: Int?
        let threshold: Int64
        let keys: [Key]
        let operations: String?

        func requiresMultipleSigners() throws -> Bool {
            guard threshold > 0, !keys.isEmpty, keys.count <= 5 else {
                throw invalid("threshold_or_keys")
            }
            var addresses = Set<String>()
            var total: Int64 = 0
            var greatest: Int64 = 0
            for key in keys {
                guard key.weight > 0, let address = canonicalAddress(key.address),
                      addresses.insert(address).inserted else { throw invalid("key") }
                let sum = total.addingReportingOverflow(key.weight)
                guard !sum.overflow else { throw invalid("weight_overflow") }
                total = sum.partialValue
                greatest = max(greatest, key.weight)
            }
            guard total >= threshold else { throw invalid("unreachable_threshold") }
            return greatest < threshold
        }

        /// Whether `address` on its own carries enough weight to meet the threshold.
        /// Call after `requiresMultipleSigners()` has validated the keys.
        func isSatisfiedAlone(by address: String) -> Bool {
            keys.contains { canonicalAddress($0.address) == address && $0.weight >= threshold }
        }
    }

    private struct Key: Decodable {
        let address: String
        let weight: Int64
    }
}
