import Foundation

/// Match the signed external message and every internal-message edge. A sender
/// receipt alone does not prove that a swap or Jetton transfer finished.
struct WalletConnectTonProof {
    let complete: Bool, success: Bool, fee: UInt64, walletFee: UInt64
    static func decode(_ trace: TonJSON, plan: WalletConnectTonPlan, bytes: Data, emulated: Bool) throws -> Self {
        let root=trace["transaction"], expected=try TonCell.parse(bytes)
        guard let incoming=try TonSendProof.messages(root).incoming, incoming.hash==expected.hash,
              try TonSendProof.address(root["account"])==plan.request.account else { throw TonSendError.changed }
        var seen=Set<String>(), complete=true, success=true, fee:UInt64=0, walletFee:UInt64=0, nodes=0
        func walk(_ trace: TonJSON, depth: Int) throws {
            nodes += 1
            guard depth <= 32, nodes <= 256, emulated || trace["emulated"] != .bool(true) else { throw TonSendError.malformed }
            let tx=trace["transaction"], id=try TonIdentity.hash(tx["hash"].string ?? "")
            guard seen.insert(id).inserted else { throw TonSendError.malformed }
            let messages=try TonSendProof.messages(tx)
            let internalMessages=try messages.outgoing.filter { $0.bits.first==0 }.map(TonMessage.init)
            for cell in messages.outgoing where cell.bits.first == 0 {
                var reader = TonReader(cell); try reader.skip(4)
                _ = try reader.address(); _ = try reader.address(); _ = try reader.coins()
                if try reader.uint(1) == 1 { _ = try reader.ref() }
                for value in [try reader.coins(), try reader.coins()] {
                    let total = fee.addingReportingOverflow(value)
                    guard !total.overflow else { throw TonSendError.malformed }; fee = total.partialValue
                }
            }
            let addition=fee.addingReportingOverflow(try TonSendClient.uint(tx["total_fees"]))
            guard !addition.overflow else { throw TonSendError.malformed }; fee=addition.partialValue
            // Descendant contracts pay from their attached value. Only the
            // wallet transaction needs a reserve beyond the reviewed amounts.
            if depth == 0 { walletFee = fee }
            let message=try messages.incoming.map(TonMessage.init)
            let credited=tx["credit_phase"]["credit"].text.flatMap(UInt64.init)
            let plainCredit=message.map { !$0.bounce && !$0.bounced && credited == $0.value && internalMessages.isEmpty } ?? false
            if message?.bounced == true || !(tx["success"] == .bool(true) && tx["aborted"] == .bool(false) || (depth>0 && plainCredit)) { success=false }
            let children=trace["children"].array ?? []
            var matched=Set<Data>()
            for child in children {
                guard let input=try TonSendProof.messages(child["transaction"]).incoming,
                      messages.outgoing.contains(where:{$0.hash==input.hash}), matched.insert(input.hash).inserted else { throw TonSendError.changed }
                let parsed=try TonMessage(input)
                guard parsed.source == (try TonSendProof.address(tx["account"])), parsed.destination == (try TonSendProof.address(child["transaction"]["account"])) else { throw TonSendError.changed }
                try walk(child,depth:depth+1)
            }
            if children.count != internalMessages.count { complete=false }
        }
        try walk(trace,depth:0)
        // A successful wallet action must emit each reviewed message, in order.
        let outputs=try TonSendProof.messages(root).outgoing.filter { $0.bits.first==0 }.map(TonMessage.init)
        if root["success"] == .bool(true) && root["aborted"] == .bool(false) {
            // Send mode +2 can skip an action while the wallet transaction
            // succeeds. That is a failed batch, not a pending receipt.
            if outputs.count != plan.request.messages.count { success=false }
            for (actual,requested) in zip(outputs,plan.request.messages) where outputs.count == plan.request.messages.count {
                let body = try requested.payload.map(TonCell.parse) ?? TonCell()
                guard actual.destination==requested.address,actual.value==requested.amount,actual.bounce==requested.bounce,!actual.bounced,
                      actual.body.hash == body.hash else { throw TonSendError.changed }
            }
        }
        return .init(complete:complete,success:success,fee:fee,walletFee:walletFee)
    }
}
