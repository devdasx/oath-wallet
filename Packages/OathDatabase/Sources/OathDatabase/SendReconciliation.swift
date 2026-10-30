import Foundation
import OathAnkr

/// Reconcile only the exact bytes durably authorized by the user. These methods
/// need no vault/key access and never construct or sign a replacement transfer.
extension OathDatabase {
    public func reconcileSuiSend(_ id: String, client: SuiSendClient) async throws {
        guard let send = try await send(id), ["signed","broadcast"].contains(send.state) else { return }
        guard let payload = send.signedPayload, let plan = try await self.suiSendPlan(sendID:send.id), plan.network == (await client.network) else { throw SuiSendError.changed }
        let signed = try JSONDecoder().decode(SuiSignedSend.self,from:payload)
        try SuiSendCrypto.verify(signed,sender:plan.sender)
        guard signed.bytes == (try plan.transactionBytes()) else { throw SuiSendError.changed }
        if send.state == "signed" { _ = try await self.transitionSend(send.id,from:"signed",to:"broadcast") }
        var receipt = if send.state == "signed" { try await client.submit(signed,sender:plan.sender) }
            else { try await client.status(digest:signed.digest) }
        if receipt.outcome == .unknown { receipt = try await client.submit(signed,sender:plan.sender) }
        try await self.settleSuiSend(sendID:send.id,receipt:receipt)
    }
    public func reconcileXrplSend(_ id: String, client: XrplSendClient) async throws {
        guard let send = try await send(id), ["signed","broadcast"].contains(send.state) else { return }
        guard let payload = send.signedPayload, let plan = try await self.xrplSendPlan(sendID:send.id), plan.network == (await client.network) else { throw XrplSendError.changed }
        let signed = try JSONDecoder().decode(XrplSignedSend.self,from:payload)
        try XrplSendCrypto.verify(signed,plan:plan)
        if send.state == "signed" { _ = try await self.transitionSend(send.id,from:"signed",to:"broadcast") }
        var receipt = if send.state == "signed" { try await client.submit(signed,plan:plan) }
            else { try await client.status(signed,plan:plan) }
        if receipt.outcome == .unknown { receipt = try await client.submit(signed,plan:plan) }
        try await self.settleXrplSend(sendID:send.id,receipt:receipt)
    }
    public func reconcileStellarSend(_ id: String, client: StellarSendClient) async throws {
        guard let send = try await send(id), ["signed","broadcast"].contains(send.state) else { return }
        guard let payload = send.signedPayload, let plan = try await self.stellarSendPlan(sendID:send.id), plan.network == (await client.network) else { throw StellarSendError.changed }
        let signed = try JSONDecoder().decode(StellarSignedSend.self,from:payload)
        try StellarSendCrypto.verify(signed,plan:plan)
        if send.state == "signed" { _ = try await self.transitionSend(send.id,from:"signed",to:"broadcast") }
        var receipt = if send.state == "signed" { try await client.submit(signed,plan:plan) }
            else { try await client.status(signed,plan:plan) }
        if receipt.outcome == .unknown { receipt = try await client.submit(signed,plan:plan) }
        try await self.settleStellarSend(sendID:send.id,receipt:receipt)
    }
    public func reconcileTronSend(_ id: String, client: TronSendClient) async throws {
        guard let send = try await send(id), ["signed","broadcast"].contains(send.state) else { return }
        guard let payload = send.signedPayload, let plan = try await self.tronSendPlan(sendID:send.id), plan.network == (await client.network) else { throw TronSendError.changed }
        let signed = try JSONDecoder().decode(TronSignedSend.self,from:payload)
        try TronSendCrypto.verify(signed,plan:plan)
        if send.state == "signed" { _ = try await self.transitionSend(send.id,from:"signed",to:"broadcast") }
        var receipt = if send.state == "signed" { try await client.submit(signed,plan:plan) }
            else { try await client.status(signed,plan:plan) }
        if receipt.outcome == .unknown { receipt = try await client.submit(signed,plan:plan) }
        try await self.settleTronSend(sendID:send.id,receipt:receipt)
    }
    public func reconcileNearSend(_ id: String, client: NearSendClient) async throws {
        guard let send = try await send(id), ["signed","broadcast"].contains(send.state) else { return }
        guard let payload = send.signedPayload, let plan = try await self.nearSendPlan(sendID:send.id), plan.network == (await client.network) else { throw NearSendError.changed }
        let signed = try JSONDecoder().decode(NearSignedSend.self,from:payload)
        try NearSendCrypto.verify(signed,plan:plan)
        if send.state == "signed" { _ = try await self.transitionSend(send.id,from:"signed",to:"broadcast") }
        var receipt = if send.state == "signed" { try await client.submit(signed,plan:plan) }
            else { try await client.status(signed,plan:plan) }
        if receipt.outcome == .unknown { receipt = try await client.submit(signed,plan:plan) }
        try await self.settleNearSend(sendID:send.id,receipt:receipt)
    }
    public func reconcilePolkadotSend(_ id: String, client: PolkadotSendClient) async throws {
        guard let send = try await send(id), ["signed","broadcast"].contains(send.state) else { return }
        guard let payload = send.signedPayload, let plan = try await self.polkadotSendPlan(sendID:send.id), plan.network == (await client.network) else { throw PolkadotSendError.changed }
        let signed = try JSONDecoder().decode(PolkadotSignedSend.self,from:payload)
        try PolkadotSendCrypto.verify(signed,plan:plan)
        if send.state == "signed" { _ = try await self.transitionSend(send.id,from:"signed",to:"broadcast") }
        var receipt = if send.state == "signed" { try await client.submit(signed,plan:plan) }
            else { try await client.status(signed,plan:plan) }
        if receipt.outcome == .unknown { receipt = try await client.submit(signed,plan:plan) }
        try await self.settlePolkadotSend(sendID:send.id,receipt:receipt)
    }
}
