import Foundation

struct WalletSetupSheetCompletion: Equatable {
    private(set) var pendingWalletAddress: String?

    @discardableResult
    mutating func queue(walletAddress: String) -> Bool {
        let normalizedAddress = walletAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedAddress.isEmpty else {
            return false
        }
        pendingWalletAddress = normalizedAddress
        return true
    }

    mutating func consumeAfterSheetDismissal() -> String? {
        defer {
            pendingWalletAddress = nil
        }
        return pendingWalletAddress
    }

    mutating func cancel() {
        pendingWalletAddress = nil
    }
}

/// Activation belongs to the committed wallet, not to the sheet's dismissal.
/// Success preparation and Open Wallet share one asynchronous request.
@MainActor
final class WalletSetupActivation {
    private var readyAddress: String?
    private var pending: (id: UUID, address: String, task: Task<Bool, Never>)?

    func prepare(
        address: String,
        activate: @escaping @MainActor (String) async -> Bool
    ) async -> Bool {
        guard !address.isEmpty else { return false }
        if readyAddress == address { return true }
        if let pending, pending.address == address {
            return await pending.task.value
        }
        let id = UUID()
        // Intentionally independent of the caller's cancellation: a swipe to
        // dismiss must not leave a persisted, selected wallet inactive in Home.
        let task = Task { @MainActor in await activate(address) }
        pending = (id, address, task)
        let ready = await task.value
        if pending?.id == id {
            readyAddress = ready ? address : nil
            pending = nil
        }
        return ready
    }
}
