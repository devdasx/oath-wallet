import UIKit

@MainActor
enum ExactTextRenderingProbe {
    static func report(in root: UIView) -> String {
        func views(_ view: UIView) -> [UITextView] {
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { views($0) }
        }
        func drawnLayers(_ layer: CALayer) -> Int {
            guard !layer.isHidden, layer.opacity > 0 else { return 0 }
            return (layer.contents == nil ? 0 : 1) + (layer.sublayers ?? []).reduce(0) { $0 + drawnLayers($1) }
        }
        return views(root).map { view in
            let viewport = view.textLayoutManager?.textViewportLayoutController
            return "hidden=\(view.isHidden),alpha=\(view.alpha),chars=\(view.text.count),layers=\(drawnLayers(view.layer)),viewport=\(viewport?.viewportRange != nil),offset=\(view.contentOffset)"
        }.joined(separator: ";")
    }
}
