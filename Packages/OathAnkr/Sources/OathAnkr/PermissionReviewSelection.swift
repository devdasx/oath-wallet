import Foundation

/// One immutable presentation value: the wallet and permissions must arrive
/// together when the review sheet is created. Never present an empty batch.
public struct PermissionReviewSelection: Identifiable, Sendable {
    public let id = UUID()
    public let walletID: String
    public let items: [WalletPermission]

    public init?(walletID: String, items: [WalletPermission]) {
        guard !walletID.isEmpty, !items.isEmpty,
              items.count <= PermissionBatchScope.maximumItems,
              Set(items.map(\.id)).count == items.count else { return nil }
        self.walletID = walletID
        self.items = items
    }
}

extension WalletPermission {
    /// Permit2's stored value also contains expiry and nonce. Only its first
    /// field is a token allowance; NFT IDs and control fingerprints are not.
    public var tokenAllowance: String? {
        switch kind {
        case .token, .delegate, .permanentDelegate: amount
        case .permit2: amount.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init)
        default: nil
        }
    }
    public var hasUnlimitedTokenAllowance: Bool {
        tokenAllowance == (kind == .permit2
            ? "1461501637330902918203684832716283019655932542975"
            : "115792089237316195423570985008687907853269984665640564039457584007913129639935")
    }
}
