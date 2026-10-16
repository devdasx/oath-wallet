import Foundation

@main struct CheckWalletPalette {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String = "Palette invariant failed") { precondition(value, message); checks += 1 }
        func luminance(_ color: SIMD4<Float>) -> Double {
            func linear(_ channel: Float) -> Double {
                let channel = Double(channel)
                return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.x) + 0.7152 * linear(color.y) + 0.0722 * linear(color.z)
        }
        func neutral(_ color: SIMD4<Float>) -> Bool { color.x == color.y && color.y == color.z }
        check(MemoryLayout<OathSilkColors>.stride == 128)
        let original = OathColorway.cobalt.colors
        check(original == OathSilkColors.custom(0x244DE0), "Default blue and custom blue share the palette generator")
        for surface in [OathNeutralColors.lightCanvas, OathNeutralColors.lightGroupedCanvas,
                        OathNeutralColors.lightField, OathNeutralColors.darkCanvas, OathNeutralColors.darkCard,
                        OathNeutralColors.darkField, OathNeutralColors.darkSheet, OathNeutralColors.darkSheetCard] {
            check((surface >> 16) & 255 == (surface >> 8) & 255 && (surface >> 8) & 255 == surface & 255,
                  "Every app surface must be achromatic")
        }
        // Cube samples include black, white, every primary and mixed hues.
        for red in stride(from: UInt32(0), through: 255, by: 17) {
            for green in stride(from: UInt32(0), through: 255, by: 17) {
                for blue in stride(from: UInt32(0), through: 255, by: 17) {
                    let palette = OathSilkColors.custom((red << 16) | (green << 8) | blue)
                    for shade in [palette.lightDeep, palette.lightCrest, palette.darkDeep, palette.darkCrest,
                                  palette.lightReflection, palette.darkReflection, palette.lightRest, palette.darkRest] {
                        check((0..<4).allSatisfy { shade[$0].isFinite && (0...1).contains(shade[$0]) })
                        check(shade.w == 1)
                    }
                    check(palette.lightRest == original.lightRest && palette.darkRest == original.darkRest)
                    check(luminance(palette.lightCrest) > luminance(palette.lightDeep) * 2, "Light folds retain depth")
                    check(luminance(palette.darkCrest) > luminance(palette.darkDeep) * 2, "Dark folds retain depth")
                    check(luminance(palette.lightCrest) > luminance(palette.darkCrest), "Dark mode has quieter highlights")
                    check(luminance(palette.lightCrest) < 0.26, "Bright accents have a bounded highlight luminance")
                    check(neutral(palette.lightRest) && neutral(palette.darkRest), "Accent never tints the page")
                    if red == green && green == blue {
                        for shade in [palette.lightDeep, palette.lightCrest, palette.darkDeep, palette.darkCrest,
                                      palette.lightReflection, palette.darkReflection] {
                            check(neutral(shade), "Gray, white and black never acquire a color cast")
                        }
                    }
                }
            }
        }
        let red = OathSilkColors.custom(0xFF0000)
        let green = OathSilkColors.custom(0x00FF00)
        check(red.lightDeep.x > red.lightDeep.y && green.lightDeep.y > green.lightDeep.x)
        for colorway in OathColorway.allCases {
            check(colorway.colors.lightRest == original.lightRest && colorway.colors.darkRest == original.darkRest,
                  "Every named palette has the same neutral canvas")
        }
        print("Passed \(checks) host palette checks across 4,096 RGB colors; shader layout, gamut, tonal separation and neutral canvases.")
    }
}
