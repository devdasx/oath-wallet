import Foundation

/// Names the observed call, not its success or a predicted balance change.
/// Missing/malformed optional evidence is an expected classification gap.
public enum EVMHistoryContractCall: String, Codable, Sendable {
    case approval, approvalRemoval, contractInteraction

    public static func classify(transaction tx: SolanaJSON, receipt: SolanaJSON,
                                owner: String, chainID: UInt64) throws -> Self? {
        let owner = try EVMSendIdentity.address(owner)
        guard let hash = tx["hash"].string?.lowercased(), hash.count == 66,
              receipt["transactionHash"].string?.lowercased() == hash,
              let block = tx["blockHash"].string?.lowercased(), block.count == 66,
              receipt["blockHash"].string?.lowercased() == block,
              ["0x0", "0x1"].contains(receipt["status"].string),
              tx["from"].string?.lowercased() == owner,
              receipt["from"].string?.lowercased() == owner,
              let to = tx["to"].string?.lowercased(), to != EVMPermissionRemoval.zero,
              receipt["to"].string?.lowercased() == to,
              let input = tx["input"].string, input.count > 2, input.count <= 262_146,
              let value = tx["value"].string, try AnkrQuantity.decimal(value) == "0" else { return nil }
        if let chain = tx["chainId"].string, try AnkrQuantity.decimal(chain) != String(chainID) { return nil }
        let params = try JSONEncoder().encode(SolanaJSON.array([.object([
            "from": .string(owner), "to": .string(to), "data": .string(input), "value": .string(value)
        ])]))
        let request = try WalletConnectEVMRequest(params: params, account: owner, chainID: chainID)
        let action = WalletConnectEVMAction(request)
        if action.kind == .operatorApproval {
            return action.fields.contains { $0.label == .access && $0.value == "0" } ? .approvalRemoval : .approval
        }
        if action.kind == .approval {
            let spender = action.fields.first { $0.label == .spender }?.value
            if spender == EVMPermissionRemoval.zero { return .approvalRemoval }
            // approve(spender, 0) can also approve NFT #0. Only a matching
            // ERC20 Approval event proves this is a zero allowance removal.
            if action.fields.contains(where: { $0.label == .amount && $0.value == "0" }),
               let logs = receipt["logs"].array, logs.count <= 2048,
               logs.contains(where: { log in
                   let topics = log["topics"].array?.compactMap(\.string).map { $0.lowercased() }
                   return log["removed"] != .bool(true) && log["address"].string?.lowercased() == to
                       && log["transactionHash"].string?.lowercased() == hash
                       && log["blockHash"].string?.lowercased() == block
                       && topics == [approvalTopic, addressTopic(owner), addressTopic(spender ?? "")]
                       && log["data"].string == "0x" + String(repeating: "0", count: 64)
               }) { return .approvalRemoval }
            return .approval
        }
        // Permit2 lockdown is a canonical bounded array of token/spender pairs.
        let bytes = Array(request.call.bytes)
        if to == EVMPermissionRemoval.permit2, bytes.count >= 132,
           Data(bytes.prefix(4)) == EVMPermissionRemoval.selector("lockdown((address,address)[])"),
           bytes[4..<35].allSatisfy({ $0 == 0 }), bytes[35] == 32,
           bytes[36..<67].allSatisfy({ $0 == 0 }) {
            let count = Int(bytes[67])
            if count > 0, count <= 128, bytes.count == 68 + count * 64,
               (0..<(count * 2)).allSatisfy({ index in
                   let start = 68 + index * 32
                   return bytes[start..<(start + 12)].allSatisfy { $0 == 0 }
               }) { return .approvalRemoval }
        }
        return .contractInteraction
    }

    private static let approvalTopic = "0x" + TronSendCrypto.hex(TronSendCrypto.keccak(Data("Approval(address,address,uint256)".utf8)))
    private static func addressTopic(_ address: String) -> String {
        "0x" + String(repeating: "0", count: 24) + address.dropFirst(2)
    }
}
