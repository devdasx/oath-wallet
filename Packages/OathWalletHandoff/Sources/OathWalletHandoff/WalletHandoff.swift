import Foundation

/// This object contains secrets. Only encode it into the device-only Keychain.
/// Never include it in a URL, navigation state, preferences, analytics or logs.
public struct WalletHandoff: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case recoveryPhrase, privateKey, bitcoinImportedWallet }
    public struct Account: Codable, Hashable, Sendable {
        public let networkID: String
        public let address: String
        public let derivationPath: String
        public let accountIndex: Int
        public init(networkID: String, address: String, derivationPath: String, accountIndex: Int = 0) {
            self.networkID = networkID; self.address = address; self.derivationPath = derivationPath; self.accountIndex = accountIndex
        }
    }
    public let kind: Kind
    public let value: String
    public let rawKey: Data?
    public let passphrase: String?
    public let recoveryScheme: String?
    public let importNetworkID: String?
    public let accounts: [Account]
    public init(kind: Kind, value: String, rawKey: Data? = nil, passphrase: String? = nil,
                importNetworkID: String? = nil, accounts: [Account], recoveryScheme: String? = nil) {
        self.kind = kind; self.value = value; self.rawKey = rawKey; self.passphrase = passphrase
        self.importNetworkID = importNetworkID; self.accounts = accounts
        self.recoveryScheme = recoveryScheme
    }
    public func validate() throws {
        guard value.utf8.count <= 32_768, passphrase?.utf8.count ?? 0 <= 4_096,
              rawKey == nil || rawKey?.count == 32,
              (1...128).contains(accounts.count),
              Set(accounts.map { $0.networkID + ":" + String($0.accountIndex) }).count == accounts.count,
              accounts.allSatisfy({ (0..<2_147_483_648).contains($0.accountIndex) && !$0.networkID.isEmpty && $0.networkID.utf8.count <= 40 &&
                  !$0.address.isEmpty && $0.address.utf8.count <= 256 && $0.derivationPath.utf8.count <= 128 }),
              importNetworkID?.utf8.count ?? 0 <= 40,
              kind == .privateKey || rawKey == nil,
              rawKey == nil || value.isEmpty,
              kind == .recoveryPhrase || passphrase == nil,
              rawKey != nil || !value.isEmpty else { throw HandoffError.invalid }
        if let recoveryScheme {
            guard kind == .recoveryPhrase,
                  ["bip39", "electrumOld", "electrumStandard", "electrumSegwit", "electrumTwoFactor", "electrumTwoFactorSegwit", "aezeed"].contains(recoveryScheme)
            else { throw HandoffError.unsupportedFormat }
            if recoveryScheme != "bip39" {
                guard accounts.count == 1, accounts[0].networkID == "bitcoin", accounts[0].accountIndex == 0,
                      importNetworkID == nil || importNetworkID == "bitcoin" else { throw HandoffError.invalid }
            }
        }
    }
}

public enum HandoffError: Error, Equatable, Sendable { case invalid, expired, unavailable, unsupportedFormat, keychain(Int32) }

public struct HandoffReference: Hashable, Identifiable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
    public var url: URL {
        var parts = URLComponents()
        parts.scheme = "oathwallet-import-v1"; parts.host = "wallet"
        parts.queryItems = [.init(name: "v", value: "1"), .init(name: "id", value: id.uuidString.lowercased())]
        return parts.url!
    }
    public init?(url: URL) {
        guard url.absoluteString.utf8.count < 256,
              let p = URLComponents(url: url, resolvingAgainstBaseURL: false),
              p.scheme == "oathwallet-import-v1", p.host == "wallet", p.path.isEmpty,
              p.user == nil, p.password == nil, p.port == nil, p.fragment == nil,
              let q = p.queryItems, q.count == 2,
              q.filter({ $0.name == "v" && $0.value == "1" }).count == 1,
              q.filter({ $0.name == "id" }).count == 1,
              let raw = q.first(where: { $0.name == "id" })?.value,
              let id = UUID(uuidString: raw) else { return nil }
        self.id = id
    }
}

public protocol HandoffStorage: Sendable {
    func put(_ data: Data, id: UUID) throws
    /// Read and delete must have one winner; a duplicate consumer receives nil.
    func take(id: UUID) throws -> Data?
    func remove(id: UUID) throws
}

public actor HandoffMailbox {
    public static let lifetime: TimeInterval = 300
    private let storage: any HandoffStorage
    public init(storage: any HandoffStorage) { self.storage = storage }
    private struct Envelope: Codable {
        let version: Int
        let id: UUID
        let created: Date
        let expires: Date
        let payload: WalletHandoff
    }
    public func publish(_ payload: WalletHandoff, now: Date = .now) throws -> HandoffReference {
        try payload.validate()
        let ref = HandoffReference()
        // Older Oath builds must reject Bitcoin mnemonic formats instead of
        // interpreting an overlapping phrase as BIP39.
        let version = payload.recoveryScheme.map { $0 == "bip39" ? 1 : 2 } ?? 1
        let envelope = Envelope(version: version, id: ref.id, created: now,
                                expires: now.addingTimeInterval(Self.lifetime), payload: payload)
        try storage.put(JSONEncoder().encode(envelope), id: ref.id)
        return ref
    }
    public func consume(_ ref: HandoffReference, now: Date = .now) throws -> WalletHandoff {
        guard var data = try storage.take(id: ref.id) else { throw HandoffError.unavailable }
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        guard data.count <= 65_536, let e = try? JSONDecoder().decode(Envelope.self, from: data),
              [1, 2].contains(e.version), e.id == ref.id,
              e.version == (e.payload.recoveryScheme.map { $0 == "bip39" ? 1 : 2 } ?? 1) else { throw HandoffError.invalid }
        guard e.created <= now.addingTimeInterval(5), e.expires > now,
              e.expires.timeIntervalSince(e.created) == Self.lifetime else { throw HandoffError.expired }
        try e.payload.validate()
        return e.payload
    }
    public func discard(_ ref: HandoffReference) throws { try storage.remove(id: ref.id) }
}
