import Foundation

/// Presentation state only. Findings and acknowledgements stay independent
/// in their existing per-wallet stores. No polling or network work occurs here.
public struct WalletSecurityNoticeQueue: Equatable, Sendable {
    public struct Notice: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case multisig, stablecoin }
        public let walletID: UUID
        public let kind: Kind
    }

    public private(set) var presented: Notice?
    public init() {}

    public func next(walletID: UUID?, homeAvailable: Bool,
                     multisigPending: Bool, stablecoinPending: Bool) -> Notice? {
        // Hold the slot until UIKit finishes dismissal, even after Got it has
        // persisted its acknowledgement and SwiftUI's sheet item becomes nil.
        guard presented == nil, homeAvailable, let walletID else { return nil }
        if multisigPending { return Notice(walletID: walletID, kind: .multisig) }
        if stablecoinPending { return Notice(walletID: walletID, kind: .stablecoin) }
        return nil
    }

    @discardableResult
    public mutating func begin(_ notice: Notice) -> Bool {
        guard presented == nil else { return false }
        presented = notice
        return true
    }

    /// Call only from the native sheet's onDismiss, never from its Got it action.
    public mutating func didDismiss() { presented = nil }
}
