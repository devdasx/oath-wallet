import Foundation

struct SettingsWalletSetupDismissal: Equatable {
    private(set) var pendingWalletAddress: String?

    @discardableResult
    mutating func request(walletAddress: String) -> Bool {
        let normalizedAddress = walletAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedAddress.isEmpty else {
            return false
        }
        pendingWalletAddress = normalizedAddress
        return true
    }

    mutating func consumeAfterSettingsDismissal() -> String? {
        defer {
            pendingWalletAddress = nil
        }
        return pendingWalletAddress
    }

    mutating func cancel() {
        pendingWalletAddress = nil
    }
}
