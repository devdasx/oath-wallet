import Foundation
import Security

struct OathInstallationKeychainCleanup: OathInstallationCredentialClearing {
    let namespace: String

    var services: [String] {
        [namespace + ".wallet-vault", namespace + ".wallet-biometry-v1",
         namespace + ".passcode", namespace + ".biometrics", namespace + ".custody.v1"]
    }

    func clear() throws {
        for service in services {
            // Exact app-owned service allowlist. Never clear a whole Keychain
            // class/access group or touch iCloud/shared/other-app credentials.
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrSynchronizable as String: false
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw OathInstallationSecurityError.keychain(status)
            }
        }
    }

    /// Only called by a confirmed reset of the production bundle. The previous
    /// Oath binary used these exact services in this same app's access group.
    static func clearLegacyWalletCredentials() throws {
        for service in ["com.codex.prototype.evmwallet.secrets", "com.aperture.wallet.custodial-auth"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrSynchronizable as String: false
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw OathInstallationSecurityError.keychain(status)
            }
        }
    }
}

extension OathInstallationSecurity {
    static let appNamespace = Bundle.main.bundleIdentifier ?? "org.oathwallet.atmosphere.studio"
    static let shared = live(namespace: appNamespace)

    static func live(namespace: String) -> OathInstallationSecurity {
        let directory = URL.applicationSupportDirectory
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("Installation", isDirectory: true)
        return OathInstallationSecurity(keys: OathInstallationKeyFile(directory: directory),
                                        credentials: OathInstallationKeychainCleanup(namespace: namespace))
    }
}
