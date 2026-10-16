/// A saved choice is independent of the device's current appearance. Only
/// `system` follows device changes; an absent preference preserves that default.
public enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark

    public static let settingKey = "appearance"

    public init(settings: [String: String]) {
        self = settings[Self.settingKey].flatMap(Self.init(rawValue:)) ?? .system
    }
}
