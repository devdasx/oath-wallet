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
    /// Canonical names in the supplied design manifest, independent of UI language.
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

    var titleKey: OathStringKey {
        switch self {
        case .signalBlue: .appIconSignalBlue
        case .obsidian: .appIconObsidian
        case .porcelain: .appIconPorcelain
        case .verdant: .appIconVerdant
        case .ultraviolet: .appIconUltraviolet
        case .electricLime: .appIconElectricLime
        case .ember: .appIconEmber
        case .titanium: .appIconTitanium
        case .glacier: .appIconGlacier
        case .champagne: .appIconChampagne
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
