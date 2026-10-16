#if canImport(UIKit)
import UIKit
#endif

enum OathAppIcon: String, CaseIterable, Identifiable {
    case signalBlue = "signal-blue"
    case obsidian, porcelain, verdant, ultraviolet
    case electricLime = "electric-lime"
    case ember, titanium, glacier, champagne

    var id: String { rawValue }
    var alternateName: String? {
        switch self {
        case .signalBlue: nil
        case .obsidian: "AppIconObsidian"
        case .porcelain: "AppIconPorcelain"
        case .verdant: "AppIconVerdant"
        case .ultraviolet: "AppIconUltraviolet"
        case .electricLime: "AppIconElectricLime"
        case .ember: "AppIconEmber"
        case .titanium: "AppIconTitanium"
        case .glacier: "AppIconGlacier"
        case .champagne: "AppIconChampagne"
        }
    }
    var assetName: String { alternateName ?? "AppIcon" }
    var preview: String { "IconPreview-" + rawValue }
    /// Names of the supplied icon designs, kept verbatim in every language.
    var title: String {
        switch self {
        case .signalBlue: "Signal Blue"
        case .obsidian: "Obsidian"
        case .porcelain: "Porcelain"
        case .verdant: "Verdant"
        case .ultraviolet: "Ultraviolet"
        case .electricLime: "Electric Lime"
        case .ember: "Ember"
        case .titanium: "Titanium"
        case .glacier: "Glacier"
        case .champagne: "Champagne"
        }
    }

    static func choice(forAlternateName name: String?) -> Self? {
        allCases.first { $0.alternateName == name }
    }

    #if canImport(UIKit)
    @MainActor static var current: Self? {
        // A removed icon has no selected row until iOS accepts the reset.
        choice(forAlternateName: UIApplication.shared.alternateIconName)
    }
    #endif
}
