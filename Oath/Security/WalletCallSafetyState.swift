import Foundation
import Observation

struct WalletCallSnapshot: Equatable, Sendable {
    let id: UUID
    let hasEnded: Bool
}

/// Ephemeral call-state only. No caller identity, audio, persistence or analytics.
@MainActor
@Observable
final class WalletCallSafetyState {
    private(set) var activeCallIDs: Set<UUID> = []
    private var hiddenCallIDs: Set<UUID> = []
    @ObservationIgnored private var endedCallIDs: [UUID] = []

    var hasActiveCall: Bool { !activeCallIDs.isEmpty }
    var shouldShowWarning: Bool { !activeCallIDs.subtracting(hiddenCallIDs).isEmpty }

    /// Silence only calls that exist now; a new CallKit UUID always warns again.
    func hideForCurrentCalls() {
        hiddenCallIDs.formUnion(activeCallIDs)
    }

    func callChanged(_ call: WalletCallSnapshot) {
        if call.hasEnded {
            rememberEnded(call.id)
            activeCallIDs.remove(call.id)
            hiddenCallIDs.remove(call.id)
        } else if !endedCallIDs.contains(call.id) {
            // Ringing, dialing, connected and held calls all warrant the warning.
            activeCallIDs.insert(call.id)
        }
    }

    func refresh(_ calls: [WalletCallSnapshot]) {
        for call in calls where call.hasEnded { rememberEnded(call.id) }
        // A late system snapshot must not resurrect a call whose end was observed.
        activeCallIDs = Set(calls.filter {
            !$0.hasEnded && !endedCallIDs.contains($0.id)
        }.map(\.id))
        hiddenCallIDs.formIntersection(activeCallIDs)
    }

    private func rememberEnded(_ id: UUID) {
        guard !endedCallIDs.contains(id) else { return }
        endedCallIDs.append(id)
        if endedCallIDs.count > 64 { endedCallIDs.removeFirst() }
    }
}
