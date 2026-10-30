import Foundation

/// Immutable EVM transaction input. Chain/account and every supported envelope
/// field are checked before a quote is prepared. Unknown transaction extensions
/// are rejected; they are never dropped silently from a signed transaction.
public struct WalletConnectEVMRequest: Sendable, Equatable {
    public enum Failure: Error, Equatable, Sendable { case malformed, unsupported, wrongAccount, wrongChain }
    public let sender: String, recipient: String, value: String
    public let call: EVMContractCall
    public let chainID: UInt64
    public let gas: UInt64?, nonce: UInt64?, gasPrice: UInt64?, maxFeePerGas: UInt64?, maxPriorityFeePerGas: UInt64?
    public let legacy: Bool?

    /// Change only the unsigned approve() amount. The caller must first verify
    /// ERC-20 allowance/decimals and obtain explicit user consent. ERC-721 has
    /// the same selector, so selector recognition alone is not sufficient.
    public func replacingApprovalAmount(_ amount: String) throws -> Self {
        guard WalletConnectEVMAction(self).kind == .approval else { throw Failure.unsupported }
        let word = TronSendCrypto.hex(try TronSendCrypto.uint256(EVMSendAmount.checked(amount)))
        var fields: [String: String] = ["from": sender, "to": recipient, "value": "0x0",
            "data": String(call.hex.prefix(74)) + word, "chainId": "0x" + String(chainID, radix: 16)]
        for (key, value) in [("gas", gas), ("nonce", nonce), ("gasPrice", gasPrice),
                             ("maxFeePerGas", maxFeePerGas), ("maxPriorityFeePerGas", maxPriorityFeePerGas)] {
            if let value { fields[key] = "0x" + String(value, radix: 16) }
        }
        if let legacy { fields["type"] = legacy ? "0x0" : "0x2" }
        return try Self(params: JSONEncoder().encode([fields]), account: sender, chainID: chainID)
    }

    /// Recovery only: a repeated original relay request may recover a locally
    /// signed approval whose amount the user edited. No other bytes can differ.
    public func matchesCommittedApproval(_ plan: EVMSendPlan) -> Bool {
        guard WalletConnectEVMAction(self).kind == .approval, let call = plan.call,
              call.bytes.count == 68, call.bytes.prefix(36) == self.call.bytes.prefix(36),
              let amount = try? AnkrQuantity.decimal("0x" + TronSendCrypto.hex(call.bytes.suffix(32))),
              let edited = try? replacingApprovalAmount(amount) else { return false }
        return edited.matches(plan)
    }

    /// A repeated relay request can recover only its already approved intent.
    /// Omitted fees may have been quoted by the wallet; supplied fields cannot
    /// change between review, restart and the final signature.
    public func matches(_ plan: EVMSendPlan) -> Bool {
        plan.network.chainID == chainID && plan.sender == sender && plan.recipient == recipient &&
        plan.call == call && plan.value == value && plan.removal == nil &&
        (gas == nil || gas == plan.gasLimit) && (nonce == nil || nonce == plan.nonce) &&
        (legacy == nil || legacy == plan.legacy) &&
        (gasPrice == nil || (plan.legacy && gasPrice == plan.maxFeePerGas)) &&
        (maxFeePerGas == nil || maxFeePerGas == plan.maxFeePerGas) &&
        (maxPriorityFeePerGas == nil || maxPriorityFeePerGas == plan.maxPriorityFeePerGas)
    }

    public init(params: Data, account: String, chainID: UInt64) throws {
        let root = try WalletConnectJSON.decode(params)
        guard case .array(let array) = root, array.count == 1, case .object(let object) = array[0] else { throw Failure.malformed }
        let allowed: Set<String> = ["from", "to", "value", "data", "input", "chainId", "gas", "gasLimit", "nonce", "gasPrice", "maxFeePerGas", "maxPriorityFeePerGas", "type", "accessList"]
        guard Set(object.keys).isSubset(of: allowed) else { throw Failure.unsupported }
        guard let from = object["from"]?.string, let to = object["to"]?.string else { throw Failure.malformed }
        sender = try EVMSendIdentity.address(from); recipient = try EVMSendIdentity.address(to)
        guard sender == (try EVMSendIdentity.address(account)) else { throw Failure.wrongAccount }
        guard recipient != EVMPermissionRemoval.zero else { throw Failure.malformed }
        self.chainID = chainID
        func quantity(_ key: String) throws -> String? {
            guard let value = object[key] else { return nil }
            guard let raw = value.string, raw.hasPrefix("0x"), raw.count >= 3, raw.count <= 66,
                  raw.dropFirst(2).allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  raw.count == 3 || raw.dropFirst(2).first != "0" else { throw Failure.malformed }
            return try EVMSendAmount.checked(AnkrQuantity.decimal(raw))
        }
        func uint(_ key: String) throws -> UInt64? {
            guard let raw = try quantity(key) else { return nil }
            guard let n = UInt64(raw) else { throw Failure.unsupported }; return n
        }
        if let supplied = try uint("chainId"), supplied != chainID { throw Failure.wrongChain }
        value = try quantity("value") ?? "0"
        if let first = object["data"], let second = object["input"], first != second { throw Failure.malformed }
        let raw = object["data"] ?? object["input"] ?? .string("0x")
        guard let hex = raw.string else { throw Failure.malformed }
        call = try EVMContractCall(hex: hex)
        let gas = try uint("gas"), alias = try uint("gasLimit")
        guard gas == nil || alias == nil || gas == alias else { throw Failure.malformed }
        self.gas = gas ?? alias; nonce = try uint("nonce")
        gasPrice = try uint("gasPrice"); maxFeePerGas = try uint("maxFeePerGas"); maxPriorityFeePerGas = try uint("maxPriorityFeePerGas")
        guard gasPrice == nil || (maxFeePerGas == nil && maxPriorityFeePerGas == nil) else { throw Failure.malformed }
        guard maxPriorityFeePerGas == nil || maxFeePerGas != nil else { throw Failure.malformed }
        if let maxFeePerGas, let maxPriorityFeePerGas, maxPriorityFeePerGas > maxFeePerGas { throw Failure.malformed }
        if let type = try uint("type") {
            guard type == 0 || type == 2 else { throw Failure.unsupported }
            guard type != 0 || maxFeePerGas == nil, type != 2 || gasPrice == nil else { throw Failure.malformed }
            legacy = type == 0
        } else { legacy = gasPrice == nil ? nil : true }
        if let list = object["accessList"] {
            guard case .array(let entries) = list, entries.isEmpty else { throw Failure.unsupported }
        }
        let maximumGas = EVMSendNetwork.allCases.first { $0.chainID == chainID }?.maximumGas ?? EVMSendPlan.maximumGas
        if let gas = self.gas, !(21_000...maximumGas).contains(gas) { throw Failure.unsupported }
    }
}

/// Arbitrary contract bytes are explicit in the approved plan and local journal.
/// A four-byte selector alone never proves a token standard or a swap outcome.
public struct EVMContractCall: Codable, Sendable, Equatable {
    public let bytes: Data
    public var hex: String { "0x" + TronSendCrypto.hex(bytes) }
    public init(hex: String) throws {
        guard hex.hasPrefix("0x"), hex.count <= 32_770, hex.count % 2 == 0,
              hex.dropFirst(2).allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw WalletConnectEVMRequest.Failure.malformed }
        bytes = try TronIdentity.hex(String(hex.dropFirst(2)))
    }
    public func validate() throws {
        guard bytes.count <= 16_384 else { throw WalletConnectEVMRequest.Failure.malformed }
    }
}
