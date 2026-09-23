import SwiftUI

/// Visibility starts the interval; the operation owns it after navigation removes this view.
struct SendActivityAutomaticDismissal: ViewModifier {
    let operation: SendOperation
    var isEnabled = true
    var dismissConfirming = false
    let onDismiss: @MainActor () -> Void

    private var deadlineIdentity: SendActivityDismissalTimer.Identity? {
        let status = operation.capsuleStatus
        guard isEnabled, !operation.isAcknowledged,
              status == .confirmed || (dismissConfirming && status == .confirming) else { return nil }
        return .init(operation: operation)
    }

    func body(content: Content) -> some View {
        let deadline = deadlineIdentity
        content.task(id: deadline) {
            guard let deadline, !Task.isCancelled else { return }
            operation.capsuleDismissal.start(for: operation, identity: deadline, onDismiss: onDismiss)
        }
    }
}

/// One monotonic deadline per seen status, retained independently of its SwiftUI presentation.
@MainActor
final class SendActivityDismissalTimer {
    struct Identity: Equatable, Sendable {
        let presentationID: UUID
        let status: SendOperation.CapsuleStatus

        @MainActor init(operation: SendOperation) {
            presentationID = operation.capsulePresentationID
            status = operation.capsuleStatus
        }
    }

    private var identity: Identity?
    private var work: Task<Void, Never>?

    func start(for operation: SendOperation, identity: Identity,
               onDismiss: @escaping @MainActor () -> Void) {
        guard !operation.isAcknowledged, identity == Identity(operation: operation),
              identity.status == .confirming || identity.status == .confirmed,
              self.identity != identity else { return }
        cancel()
        self.identity = identity
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        work = Task { @concurrent [weak self, weak operation] in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
                try Task.checkCancellation()
                await self?.finish(for: operation, identity: identity, onDismiss: onDismiss)
            } catch {
                // Only acknowledgement, a new status, or owner cleanup cancels this interval.
            }
        }
    }

    func invalidateIfNeeded(for operation: SendOperation) {
        if let identity, operation.isAcknowledged || identity != Identity(operation: operation) {
            cancel()
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        identity = nil
    }

    private func finish(for operation: SendOperation?, identity: Identity,
                        onDismiss: @MainActor () -> Void) {
        guard !Task.isCancelled, let operation, self.identity == identity,
              !operation.isAcknowledged, identity == Identity(operation: operation) else { return }
        work = nil
        // Acknowledge even if no banner is mounted. Returning Home must not replay this status.
        operation.isAcknowledged = true
        onDismiss()
    }

    deinit { work?.cancel() }
}
