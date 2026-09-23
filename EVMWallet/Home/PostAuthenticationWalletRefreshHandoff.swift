import Foundation

struct PostAuthenticationWalletRefreshRequest:
    Equatable,
    Sendable
{
    let requestID: UUID
    let identity: PersistedWalletIdentity
}

struct PostAuthenticationWalletRefreshHandoff:
    Equatable,
    Sendable
{
    private(set) var pendingRequest:
        PostAuthenticationWalletRefreshRequest?

    mutating func stage(
        requestID: UUID,
        identity: PersistedWalletIdentity
    ) {
        pendingRequest = PostAuthenticationWalletRefreshRequest(
            requestID: requestID,
            identity: identity
        )
    }

    mutating func consumeAfterFirstRenderedFrame(
        requestID: UUID,
        identity: PersistedWalletIdentity?
    ) -> Bool {
        guard let pendingRequest else { return false }
        self.pendingRequest = nil
        return pendingRequest.requestID == requestID
            && pendingRequest.identity == identity
    }

    mutating func reset() {
        pendingRequest = nil
    }
}
