import Foundation

/// The PIN-encrypted vault and retry counters also require the installation
/// key. A valid old PIN cannot restore data left by a deleted installation.
struct OathInstallationVaultStorage: OathVaultStorage {
    let raw: any OathVaultStorage
    let installation: OathInstallationSecurity

    init(raw: any OathVaultStorage = OathVaultKeychain(),
         installation: OathInstallationSecurity = .shared) {
        self.raw = raw
        self.installation = installation
    }

    func read(_ account: String) throws -> Data? {
        try installation.prepare()
        guard let data = try raw.read(account) else { return nil }
        return try installation.open(data, context: "vault:\(account)")
    }

    func insert(_ data: Data, account: String) throws {
        try raw.insert(installation.seal(data, context: "vault:\(account)"), account: account)
    }

    func update(_ data: Data, account: String) throws {
        try raw.update(installation.seal(data, context: "vault:\(account)"), account: account)
    }
    func replace(_ data: Data, account: String) throws {
        // Replacement must not decrypt an obsolete pre-release record. The new
        // value is already verified and still receives installation protection.
        try raw.replace(installation.seal(data, context: "vault:\(account)"), account: account)
    }
    func erase() throws {
        try raw.erase()
        try installation.reset()
    }
}
