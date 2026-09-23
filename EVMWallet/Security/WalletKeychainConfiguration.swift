import Foundation
import Security

enum WalletKeychainConfiguration {
    static let teamIdentifier = "C5T44SZNQX"
    static let applicationBundleIdentifier = "com.aperture.wallet"
    static let accessGroup =
        "\(teamIdentifier).\(applicationBundleIdentifier)"

    static func scopedQuery(
        _ query: [String: Any]
    ) -> [String: Any] {
#if targetEnvironment(simulator)
        // Simulator apps can be installed from an ad-hoc build that has no
        // simulated Keychain entitlement. Its default Keychain namespace is
        // still isolated to the app, so do not request the device-only group.
        return query
#else
        var scopedQuery = query
        scopedQuery[kSecAttrAccessGroup as String] = accessGroup
        return scopedQuery
#endif
    }
}
