import Foundation

/// Production playback and energy logic, run on the Mac without an iOS runtime.
@main struct CheckArtworkPlayback {
    static func main() {
        var playback = OathArtworkPlayback()
        precondition(playback.needsFrame && !playback.hasPresentedFrame)
        precondition(!playback.shouldTick(canDraw: false, animating: true))
        precondition(playback.shouldTick(canDraw: true, animating: false))

        let first = playback.revision
        playback.requestFrame() // New color arrives while the first frame waits.
        playback.didPresent(revision: first)
        precondition(playback.needsFrame, "An older completion must not consume the current color update")
        playback.didPresent(revision: playback.revision)
        precondition(!playback.needsFrame && playback.hasPresentedFrame)
        precondition(!playback.shouldTick(canDraw: true, animating: false))
        precondition(playback.shouldTick(canDraw: true, animating: true))

        _ = playback.advance(at: 10, animating: true)
        for tick in 1...240 {
            playback.requestFrame() // Continuous palette/layout edits.
            _ = playback.advance(at: 10 + Double(tick) / 60, animating: true)
            playback.didPresent(revision: playback.revision)
        }
        precondition(abs(playback.elapsed - 4) < 0.0001, "Color changes must not restart animation time")
        _ = playback.advance(at: 16, animating: true)
        precondition(abs(playback.elapsed - 6) < 0.0001, "Skipped frames must not slow the animation clock")
        playback.pause()
        _ = playback.advance(at: 100, animating: true)
        precondition(playback.elapsed == 6, "Time spent backgrounded must not jump the animation")
        _ = playback.advance(at: 101, animating: true)
        precondition(playback.elapsed == 7)

        playback.pause()
        _ = playback.advance(at: 105, animating: false) // Reduce Motion/covered.
        playback.requestFrame()
        _ = playback.advance(at: 110, animating: false)
        precondition(playback.elapsed == 7 && playback.needsFrame)
        playback.didPresent(revision: playback.revision)
        playback.didPresent(revision: first) // A delayed earlier completion.
        precondition(!playback.needsFrame, "Out-of-order callbacks cannot dirty completed colors")

        for expected in [0.25, 1.0, 3.0] {
            precondition(playback.renderingFailed() == expected)
        }
        precondition(playback.renderingFailed() == nil && playback.recoveryExhausted)
        precondition(!playback.shouldTick(canDraw: true, animating: true), "Permanent failure must not spin")
        playback.resume() // Return from background, reattach, or thermal recovery.
        precondition(!playback.recoveryExhausted && playback.needsFrame && playback.elapsed == 7)
        precondition(playback.shouldTick(canDraw: true, animating: true))
        precondition(playback.renderingFailed() == 0.25)
        playback.didPresent(revision: playback.revision)
        precondition(playback.failures == 0)

        for state: ProcessInfo.ThermalState in [.nominal, .fair, .serious] {
            let policy = OathArtworkEnergyPolicy(thermalState: state, lowPower: false)
            precondition(playback.shouldTick(canDraw: policy.rendersFrames, animating: policy.animates))
        }
        let critical = OathArtworkEnergyPolicy(thermalState: .critical, lowPower: false)
        precondition(!playback.shouldTick(canDraw: critical.rendersFrames, animating: critical.animates))
        print("PASS: color changes in flight, 240 palette updates, skipped frames, pause/resume, Reduce Motion, bounded retries and thermal recovery")
    }
}
