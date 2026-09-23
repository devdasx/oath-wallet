import SwiftUI
import Observation
import UIKit

@MainActor @Observable
final class PinFrameRecorder: NSObject {
    var result = "Ready"
    @ObservationIgnored var probes: [Int: UIView] = [:]
    @ObservationIgnored private var samples: [Sample] = []
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var commit: Sample?
    @ObservationIgnored private var commits = 0

    struct Sample {
        let id: Int
        let x: CGFloat
        let y: CGFloat
        let swiped: Bool
        let horizontalRemainder: CGFloat
    }

    func begin() {
        link?.invalidate()
        samples = []
        commits = 0
        commit = nil
        result = "Recording"
        sample()
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func committing(_ id: Int) {
        commits += 1
        commit = read(id)
    }

    @objc private func sample() {
        for id in probes.keys.sorted() {
            if let sample = read(id) { samples.append(sample) }
        }
        // Bound fixture-only diagnostics even if a test stops interacting.
        if samples.count > 8_000 { link?.invalidate(); link = nil }
    }

    private func read(_ id: Int) -> Sample? {
        var ancestor = probes[id]
        while let view = ancestor, !(view is UICollectionViewCell) { ancestor = view.superview }
        guard let cell = ancestor as? UICollectionViewCell, cell.window != nil else { return nil }
        let rendered = cell.layer.presentation() ?? cell.layer
        return Sample(id: id, x: rendered.position.x, y: rendered.position.y,
                      swiped: cell.configurationState.isSwiped,
                      horizontalRemainder: abs(rendered.position.x - cell.layer.position.x))
    }

    func report() {
        sample()
        link?.invalidate(); link = nil
        guard let commit, let final = read(commit.id) else { result = "Missing commit"; return }
        let lower = min(commit.y, final.y) - 1
        let upper = max(commit.y, final.y) + 1
        let frames = samples.filter { $0.id == commit.id }
        let outsideFrames = frames.filter { $0.y < lower || $0.y > upper }
        let outside = outsideFrames.count
        let diagonal = frames.filter {
            abs($0.y - commit.y) > 1 && abs($0.x - final.x) > 0.5
        }.count
        let intermediate = frames.filter {
            abs($0.y - commit.y) > 1 && abs($0.y - final.y) > 1
        }.count
        result = "commits=\(commits);swiped=\(commit.swiped);horizontal=\(commit.horizontalRemainder < 0.3);outside=\(outside);diagonal=\(diagonal);animated=\(intermediate > 0);id=\(commit.id);from=\(commit.y);to=\(final.y);escaped=\(outsideFrames.map { "y=\($0.y),swiped=\($0.swiped),x=\($0.x)" })"
    }
}

struct PinFrameProbe: UIViewRepresentable {
    let id: Int
    let recorder: PinFrameRecorder
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        recorder.probes[id] = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { recorder.probes[id] = view }
}
