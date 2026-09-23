import SwiftUI

private struct WalletPrivacyShieldEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var walletPrivacyShieldEnabled: Bool {
        get { self[WalletPrivacyShieldEnabledKey.self] }
        set { self[WalletPrivacyShieldEnabledKey.self] = newValue }
    }
}

/// A system privacy redaction is a presentation request, not the user's
/// privacy preference. Native controls must opt in using the same setting as
/// walletPrivacySensitive; ordinary invalidation must never erase their text.
@propertyWrapper
struct WalletNativeTextPrivacy: DynamicProperty {
    @Environment(\.walletPrivacyShieldEnabled) private var isPrivacyShieldEnabled
    @Environment(\.redactionReasons) private var reasons

    var wrappedValue: Bool {
        reasons.contains(.placeholder)
            || (isPrivacyShieldEnabled && reasons.contains(.privacy))
    }
}
