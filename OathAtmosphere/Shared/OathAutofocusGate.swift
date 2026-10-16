import Foundation

/// Event-driven readiness for a screen's initial keyboard request. No timer is
/// used: native appearance, content loading and animation completions unblock it.
@MainActor
final class OathAutofocusGate {
    private var appeared = false
    private var enabled = false
    private var active = false
    private var presentationReady = true
    private var delivered = false
    private var valid = true
    private var revision: UInt64 = 0
    private var animations = Set<UUID>()
    private var action: (@MainActor () -> Void)?

    func activate() {
        valid = true
        presentationReady = true
        schedule()
    }

    func update(enabled: Bool, active: Bool, action: @escaping @MainActor () -> Void) {
        self.enabled = enabled
        self.active = active
        self.action = action
        schedule()
    }

    func setAppeared(_ appeared: Bool) {
        guard self.appeared != appeared else { return }
        self.appeared = appeared
        if !appeared { delivered = false }
        schedule()
    }

    func setPresentationReady(_ ready: Bool) {
        presentationReady = ready
        schedule()
    }

    func beginAnimation() -> UUID {
        let token = UUID()
        animations.insert(token)
        revision &+= 1
        return token
    }

    func endAnimation(_ token: UUID) {
        guard animations.remove(token) != nil else { return }
        schedule()
    }

    func invalidate() {
        valid = false
        appeared = false
        delivered = false
        revision &+= 1
        action = nil
        animations.removeAll()
    }

    private var ready: Bool {
        valid && appeared && enabled && active && presentationReady && !delivered && animations.isEmpty
    }

    private func schedule() {
        revision &+= 1
        guard ready else { return }
        let request = revision
        // Also leave SwiftUI's current update/layout transaction before writing
        // the focus binding. A pop, dismissal or newer update cancels this work.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revision == request, self.ready else { return }
            self.delivered = true
            self.action?()
        }
    }
}

/// A measured bottom sheet can finish appearing before a newly inserted form
/// has finished resizing it. All its descendants share these layout barriers.
@MainActor
final class OathAutofocusPresentation {
    private var pending = Set<UUID>()
    private var observers: [UUID: @MainActor (Bool) -> Void] = [:]
    private var valid = true
    var isReady: Bool { valid && pending.isEmpty }

    func begin() -> UUID {
        let token = UUID()
        pending.insert(token)
        notify()
        return token
    }

    func end(_ token: UUID) {
        guard pending.remove(token) != nil else { return }
        notify()
    }

    func observe(_ observer: @escaping @MainActor (Bool) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        observer(isReady)
        return token
    }

    func removeObserver(_ token: UUID) { observers[token] = nil }

    func invalidate() {
        valid = false
        notify()
        observers.removeAll()
        pending.removeAll()
    }

    private func notify() {
        for observer in Array(observers.values) { observer(isReady) }
    }
}
