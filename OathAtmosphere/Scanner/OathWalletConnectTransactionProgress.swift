import OathDatabase

/// Retained with this completion, so restarting observation on foreground or
/// navigation cannot repeat the success haptic for the same transaction.
struct OathWalletConnectTransactionProgress {
    private(set) var snapshot: SendProgress?
    private var announcedConfirmation = false
    var outcome: SendProgress.Outcome { snapshot?.outcome ?? .pending }

    /// True exactly once, including a receipt already settled before the sheet
    /// subscribes. Pending, failed, canceled and replaced never imply success.
    mutating func update(_ snapshot: SendProgress) -> Bool {
        self.snapshot = snapshot
        guard snapshot.outcome == .confirmed, !announcedConfirmation else { return false }
        announcedConfirmation = true
        return true
    }
}
