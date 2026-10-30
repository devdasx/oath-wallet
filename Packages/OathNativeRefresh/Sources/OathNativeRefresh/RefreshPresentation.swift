#if canImport(UIKit)
import UIKit

/// Keeps the attached UIKit control alive through the native scroll settlement.
/// UIKit retains its pan recognizer, scroll delegate, and inset animation.
/// This object never changes an offset, inset, or content height.
@MainActor
final class RefreshPresentation: NSObject {
    private weak var scroll: UIScrollView?
    private var link: CADisplayLink?
    private var pending: [UUID: Pending] = [:]

    private struct Pending {
        var policy: RefreshCompletion
        let continuation: CheckedContinuation<Void, Never>
    }

    func attach(_ scroll: UIScrollView) {
        if let previous = self.scroll, previous !== scroll { detach() }
        self.scroll = scroll
    }

    func detach() {
        scroll = nil
        finishAll()
    }

    /// Awaited after the background action, including on failure. Letting the
    /// refresh action return calls endRefreshing. Returning mid-pan races UIKit's
    /// reveal and can remove the indicator before it is displayed.
    func finishPresentation(startedAt: TimeInterval,
                            minimumDuration: TimeInterval = RefreshCompletion.minimumPresentation) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, scroll?.window != nil else {
                    continuation.resume()
                    return
                }
                pending[id] = Pending(policy: RefreshCompletion(startedAt: startedAt, minimumDuration: minimumDuration),
                                      continuation: continuation)
                if link == nil {
                    let link = CADisplayLink(target: self, selector: #selector(frame))
                    link.add(to: .main, forMode: .common)
                    self.link = link
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finish(id) }
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard let scroll, scroll.window != nil else { finishAll(); return }
        let presented = scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y
        for id in Array(pending.keys) {
            guard var wait = pending[id] else { continue }
            let ready = wait.policy.canFinish(at: CACurrentMediaTime(),
                tracking: scroll.isTracking, dragging: scroll.isDragging,
                decelerating: scroll.isDecelerating, modelOffset: scroll.contentOffset.y,
                presentedOffset: presented)
            pending[id] = wait
            if ready { finish(id) }
        }
    }

    private func finish(_ id: UUID) {
        pending.removeValue(forKey: id)?.continuation.resume()
        if pending.isEmpty { link?.invalidate(); link = nil }
    }

    private func finishAll() {
        for id in Array(pending.keys) { finish(id) }
    }
}

#endif
