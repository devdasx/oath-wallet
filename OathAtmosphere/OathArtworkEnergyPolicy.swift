import Foundation

/// Only the decorative artwork is scaled/throttled. Text, buttons, gestures
/// and native transitions keep the display's normal resolution and timing.
struct OathArtworkEnergyPolicy: Equatable {
    let framesPerSecond: Int
    let maximumScale: CGFloat
    let rendersFrames: Bool
    var animates: Bool { framesPerSecond > 0 }

    init(thermalState: ProcessInfo.ThermalState, lowPower: Bool) {
        switch thermalState {
        case .nominal:
            framesPerSecond = lowPower ? 30 : 60
            maximumScale = lowPower ? 1.5 : 2
            rendersFrames = true
        case .fair:
            framesPerSecond = 30
            maximumScale = 1.5
            rendersFrames = true
        case .serious:
            // Keep the slow silk moving with 1/16 of the nominal pixel budget
            // (15 fps at 1x versus 60 fps at 2x), rather than freezing colors.
            framesPerSecond = 15
            maximumScale = 1
            rendersFrames = true
        case .critical:
            framesPerSecond = 0
            maximumScale = 1
            rendersFrames = false // Keep the last drawable or the bundled poster.
        @unknown default:
            framesPerSecond = 0
            maximumScale = 1
            rendersFrames = false
        }
    }
}
