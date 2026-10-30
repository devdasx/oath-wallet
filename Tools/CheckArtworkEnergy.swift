import Foundation

@main struct CheckArtworkEnergy {
    static func main() {
        let nominal = OathArtworkEnergyPolicy(thermalState: .nominal, lowPower: false)
        precondition(nominal.animates && nominal.framesPerSecond == 60 && nominal.maximumScale == 2)
        let lowPower = OathArtworkEnergyPolicy(thermalState: .nominal, lowPower: true)
        precondition(lowPower.framesPerSecond == 30 && lowPower.maximumScale < nominal.maximumScale)
        for low in [false, true] {
            let fair = OathArtworkEnergyPolicy(thermalState: .fair, lowPower: low)
            precondition(fair.animates && fair.framesPerSecond == 30 && fair.maximumScale == 1.5)
            let serious = OathArtworkEnergyPolicy(thermalState: .serious, lowPower: low)
            precondition(serious.animates && serious.framesPerSecond == 15 && serious.rendersFrames && serious.maximumScale == 1,
                         "Elevated heat must reduce the artwork budget without making color changes the only moving part")
            let critical = OathArtworkEnergyPolicy(thermalState: .critical, lowPower: low)
            precondition(!critical.animates && !critical.rendersFrames)
        }
        print("PASS: full, low-power, warm, serious and critical artwork budgets")
    }
}
